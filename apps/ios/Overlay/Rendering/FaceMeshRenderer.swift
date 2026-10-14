@preconcurrency import ARKit
import CoreVideo
@preconcurrency import MetalKit
import simd

private enum RenderError: LocalizedError {
    case unavailable
    case shaderLibraryMissing
    case bufferAllocationFailed

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "Metal rendering is unavailable on this device."
        case .shaderLibraryMissing:
            "The face preview shaders could not be loaded."
        case .bufferAllocationFailed:
            "The face mesh buffers could not be allocated."
        }
    }
}

// These immutable references keep the AR camera textures alive until GPU completion.
private struct FrameResources: @unchecked Sendable {
    let frame: ARFrame
    let luma: CVMetalTexture
    let chroma: CVMetalTexture
}

@MainActor
final class FaceMeshRenderer: NSObject, MTKViewDelegate {
    private let controller: FaceTrackingController
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let textureCache: CVMetalTextureCache
    private let cameraPipeline: MTLRenderPipelineState
    private let depthPipeline: MTLRenderPipelineState
    private let wireframePipeline: MTLRenderPipelineState
    private let cameraDepth: MTLDepthStencilState
    private let faceDepth: MTLDepthStencilState
    private let wireframeDepth: MTLDepthStencilState
    private let inFlight = DispatchSemaphore(value: 3)

    private var vertexBuffers: [MTLBuffer] = []
    private var indexBuffer: MTLBuffer?
    private var indexCount = 0
    private var vertexCount = 0
    private var bufferSlot = 0

    init(view: MTKView, controller: FaceTrackingController) throws {
        guard let device = view.device,
              let queue = device.makeCommandQueue() else {
            throw RenderError.unavailable
        }
        guard let library = device.makeDefaultLibrary(),
              let cameraVertex = library.makeFunction(name: "cameraVertex"),
              let cameraFragment = library.makeFunction(name: "cameraFragment"),
              let faceVertex = library.makeFunction(name: "faceVertex"),
              let faceFragment = library.makeFunction(name: "faceFragment") else {
            throw RenderError.shaderLibraryMissing
        }

        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
                == kCVReturnSuccess, let cache else {
            throw RenderError.unavailable
        }

        self.controller = controller
        self.device = device
        commandQueue = queue
        textureCache = cache
        cameraPipeline = try Self.pipeline(
            device: device, vertex: cameraVertex, fragment: cameraFragment
        )
        depthPipeline = try Self.pipeline(
            device: device, vertex: faceVertex, fragment: nil, depthOnly: true
        )
        wireframePipeline = try Self.pipeline(
            device: device, vertex: faceVertex, fragment: faceFragment
        )

        guard let cameraDepth = Self.depthState(device: device, compare: .always, write: false),
              let faceDepth = Self.depthState(device: device, compare: .less, write: true),
              let wireframeDepth = Self.depthState(device: device, compare: .lessEqual, write: false) else {
            throw RenderError.unavailable
        }
        self.cameraDepth = cameraDepth
        self.faceDepth = faceDepth
        self.wireframeDepth = wireframeDepth
        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard controller.isSessionRunning,
              view.bounds.width > 0, view.bounds.height > 0,
              let frame = controller.session.currentFrame,
              inFlight.wait(timeout: .now()) == .success else { return }

        var committed = false
        defer {
            if !committed { inFlight.signal() }
        }

        guard let luma = cameraTexture(frame.capturedImage, plane: 0, format: .r8Unorm),
              let chroma = cameraTexture(frame.capturedImage, plane: 1, format: .rg8Unorm),
              let lumaTexture = CVMetalTextureGetTexture(luma),
              let chromaTexture = CVMetalTextureGetTexture(chroma),
              let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let command = commandQueue.makeCommandBuffer(),
              let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }

        let face = frame.anchors.compactMap { $0 as? ARFaceAnchor }.first { $0.isTracked }
        controller.updateTracking(hasFace: face != nil)

        // The camera and face both come from this frame and use the same viewport.
        var imageTransform = Self.textureTransform(frame: frame, viewport: view.bounds.size)
        encoder.setRenderPipelineState(cameraPipeline)
        encoder.setDepthStencilState(cameraDepth)
        encoder.setCullMode(.none)
        encoder.setVertexBytes(
            &imageTransform, length: MemoryLayout<simd_float3x3>.stride, index: 0
        )
        encoder.setFragmentTexture(lumaTexture, index: 0)
        encoder.setFragmentTexture(chromaTexture, index: 1)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)

        if controller.isMeshVisible, let face {
            do {
                try updateBuffers(geometry: face.geometry)
                if let indexBuffer {
                    var transform = Self.faceTransform(
                        frame: frame, face: face, viewport: view.bounds.size
                    )
                    encoder.setVertexBuffer(vertexBuffers[bufferSlot], offset: 0, index: 0)
                    encoder.setVertexBytes(
                        &transform, length: MemoryLayout<simd_float4x4>.stride, index: 1
                    )

                    // A depth-only face hides wireframe edges on the far side of the head.
                    encoder.setRenderPipelineState(depthPipeline)
                    encoder.setDepthStencilState(faceDepth)
                    encoder.setTriangleFillMode(.fill)
                    encoder.drawIndexedPrimitives(
                        type: .triangle, indexCount: indexCount, indexType: .uint16,
                        indexBuffer: indexBuffer, indexBufferOffset: 0
                    )

                    encoder.setRenderPipelineState(wireframePipeline)
                    encoder.setDepthStencilState(wireframeDepth)
                    encoder.setTriangleFillMode(.lines)
                    encoder.setDepthBias(-1, slopeScale: -1, clamp: 0)
                    encoder.drawIndexedPrimitives(
                        type: .triangle, indexCount: indexCount, indexType: .uint16,
                        indexBuffer: indexBuffer, indexBufferOffset: 0
                    )
                    bufferSlot = (bufferSlot + 1) % vertexBuffers.count
                }
            } catch {
                controller.rendererFailed(error.localizedDescription)
            }
        }

        encoder.endEncoding()
        let resources = FrameResources(frame: frame, luma: luma, chroma: chroma)
        let semaphore = inFlight
        let trackingController = controller
        command.addCompletedHandler { [resources, semaphore, weak trackingController] completed in
            withExtendedLifetime(resources) {
                semaphore.signal()
            }
            if completed.status == .error {
                let message = completed.error?.localizedDescription
                    ?? "The GPU could not render the camera preview."
                Task { @MainActor [weak trackingController] in
                    trackingController?.rendererFailed(message)
                }
            }
        }
        command.present(drawable)
        command.commit()
        committed = true
    }

    private func updateBuffers(geometry: ARFaceGeometry) throws {
        let vertices = geometry.vertices
        let length = vertices.count * MemoryLayout<SIMD3<Float>>.stride
        guard length > 0 else { throw RenderError.bufferAllocationFailed }

        if vertexCount != vertices.count {
            let buffers = (0..<3).compactMap { _ in
                device.makeBuffer(length: length, options: .storageModeShared)
            }
            let indices = geometry.triangleIndices.map { UInt16(bitPattern: $0) }
            let newIndexBuffer = indices.withUnsafeBufferPointer { pointer -> MTLBuffer? in
                guard let base = pointer.baseAddress, !pointer.isEmpty else { return nil }
                return device.makeBuffer(
                    bytes: base, length: pointer.count * MemoryLayout<UInt16>.stride,
                    options: .storageModeShared
                )
            }
            guard buffers.count == 3, let newIndexBuffer else {
                throw RenderError.bufferAllocationFailed
            }
            vertexBuffers = buffers
            indexBuffer = newIndexBuffer
            indexCount = indices.count
            vertexCount = vertices.count
            bufferSlot = 0
        }

        vertices.withUnsafeBufferPointer { pointer in
            guard let base = pointer.baseAddress else { return }
            vertexBuffers[bufferSlot].contents().copyMemory(
                from: UnsafeRawPointer(base), byteCount: length
            )
        }
    }

    private func cameraTexture(
        _ image: CVPixelBuffer, plane: Int, format: MTLPixelFormat
    ) -> CVMetalTexture? {
        guard CVPixelBufferGetPlaneCount(image) > plane else { return nil }
        var texture: CVMetalTexture?
        let result = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, image, nil, format,
            CVPixelBufferGetWidthOfPlane(image, plane),
            CVPixelBufferGetHeightOfPlane(image, plane),
            plane, &texture
        )
        return result == kCVReturnSuccess ? texture : nil
    }

    private static func pipeline(
        device: MTLDevice, vertex: MTLFunction, fragment: MTLFunction?,
        depthOnly: Bool = false
    ) throws -> MTLRenderPipelineState {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        descriptor.depthAttachmentPixelFormat = .depth32Float
        if depthOnly { descriptor.colorAttachments[0].writeMask = [] }
        return try device.makeRenderPipelineState(descriptor: descriptor)
    }

    private static func depthState(
        device: MTLDevice, compare: MTLCompareFunction, write: Bool
    ) -> MTLDepthStencilState? {
        let descriptor = MTLDepthStencilDescriptor()
        descriptor.depthCompareFunction = compare
        descriptor.isDepthWriteEnabled = write
        return device.makeDepthStencilState(descriptor: descriptor)
    }

    private static func textureTransform(
        frame: ARFrame, viewport: CGSize
    ) -> simd_float3x3 {
        let display: CGAffineTransform
        if #available(iOS 27.0, *) {
            display = frame.displayTransform(viewRotationAngle: 90, viewportSize: viewport)
        } else {
            display = frame.displayTransform(for: .portrait, viewportSize: viewport)
        }
        let inverse = display.inverted()
        return simd_float3x3(
            SIMD3(Float(inverse.a), Float(inverse.b), 0),
            SIMD3(Float(inverse.c), Float(inverse.d), 0),
            SIMD3(Float(inverse.tx), Float(inverse.ty), 1)
        )
    }

    private static func faceTransform(
        frame: ARFrame, face: ARFaceAnchor, viewport: CGSize
    ) -> simd_float4x4 {
        let projection: simd_float4x4
        let view: simd_float4x4
        if #available(iOS 27.0, *) {
            projection = frame.camera.projectionMatrix(
                viewRotationAngle: 90, viewportSize: viewport, zNear: 0.01, zFar: 10
            )
            view = frame.camera.viewMatrix(viewRotationAngle: 90)
        } else {
            projection = frame.camera.projectionMatrix(
                for: .portrait, viewportSize: viewport, zNear: 0.01, zFar: 10
            )
            view = frame.camera.viewMatrix(for: .portrait)
        }
        return projection * view * face.transform
    }
}
