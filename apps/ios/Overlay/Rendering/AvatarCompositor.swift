@preconcurrency import ARKit
import CoreVideo
@preconcurrency import RealityKit
import Metal
import simd

nonisolated struct CompositeFrame: @unchecked Sendable {
    let frame: ARFrame
    let imageTransform: simd_float3x3
    let outline: [SIMD2<Float>]
    let publishedAt: TimeInterval

    @MainActor
    static func camera(frame: ARFrame, view: ARView, outline: [SIMD2<Float>] = []) -> CompositeFrame? {
        let size = frame.camera.imageResolution
        let intrinsics = frame.camera.intrinsics
        // Project image-plane rays through RealityKit itself to share its crop and front-camera reflection.
        func project(_ pixel: SIMD2<Float>) -> SIMD2<Float>? {
            let ray = intrinsics.inverse * SIMD3(pixel.x, pixel.y, 1)
            let world = frame.camera.transform * SIMD4(ray.x, -ray.y, -1, 1)
            guard let p = view.project(SIMD3(world.x, world.y, world.z)) else { return nil }
            return SIMD2(Float(p.x / view.bounds.width), Float(p.y / view.bounds.height))
        }
        guard let origin = project(.zero),
              let x = project(SIMD2(Float(size.width), 0)),
              let y = project(SIMD2(0, Float(size.height))) else { return nil }
        let imageToScreen = simd_float3x3(
            SIMD3(x.x - origin.x, x.y - origin.y, 0),
            SIMD3(y.x - origin.x, y.y - origin.y, 0), SIMD3(origin.x, origin.y, 1)
        )
        guard abs(simd_determinant(imageToScreen)) > 0.0001 else { return nil }
        return CompositeFrame(frame: frame, imageTransform: imageToScreen.inverse,
                              outline: outline, publishedAt: ProcessInfo.processInfo.systemUptime)
    }
}

// The render callback runs independently of the main actor. Only immutable snapshots cross this lock.
nonisolated final class AvatarCompositor: @unchecked Sendable {
    private let snapshotLock = NSLock()
    private var snapshot: CompositeFrame?
    private let renderLock = NSLock()
    private var preparedDevice: MTLDevice?
    private var cache: CVMetalTextureCache?
    private var copyPipeline: MTLComputePipelineState?
    private var compositePipeline: MTLComputePipelineState?
    private var blurPipeline: MTLComputePipelineState?
    private var maskPipeline: MTLRenderPipelineState?
    private var mask: MTLTexture?
    private var blurred: MTLTexture?
    private let onFailure: @Sendable (String) -> Void
    private var reportedFailure = false

    init(onFailure: @escaping @Sendable (String) -> Void) { self.onFailure = onFailure }

    func publish(_ frame: CompositeFrame?) {
        snapshotLock.lock()
        snapshot = frame
        snapshotLock.unlock()
    }

    func retry() {
        snapshotLock.lock()
        reportedFailure = false
        snapshotLock.unlock()
        renderLock.lock()
        let device = preparedDevice
        renderLock.unlock()
        if let device { prepare(device: device) }
    }

    func prepare(device: MTLDevice) {
        renderLock.lock()
        defer { renderLock.unlock() }
        preparedDevice = device
        do {
            guard let library = device.makeDefaultLibrary(),
                  let composite = library.makeFunction(name: "avatarComposite"),
                  let blur = library.makeFunction(name: "avatarMaskBlur"),
                  let vertex = library.makeFunction(name: "avatarMaskVertex"),
                  let fragment = library.makeFunction(name: "avatarMaskFragment") else {
                throw CocoaError(.fileNoSuchFile)
            }
            if let copy = library.makeFunction(name: "avatarCopy") {
                copyPipeline = try device.makeComputePipelineState(function: copy)
            }
            compositePipeline = try device.makeComputePipelineState(function: composite)
            blurPipeline = try device.makeComputePipelineState(function: blur)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertex
            descriptor.fragmentFunction = fragment
            descriptor.colorAttachments[0].pixelFormat = .r8Unorm
            maskPipeline = try device.makeRenderPipelineState(descriptor: descriptor)
            guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess else {
                throw CocoaError(.coderInvalidValue)
            }
        } catch { fail("Avatar compositing could not start. Select Original or Mesh to continue.") }
    }

    func process(_ context: ARView.PostProcessContext) {
        renderLock.lock()
        defer { renderLock.unlock() }
        snapshotLock.lock()
        let current = snapshot
        snapshotLock.unlock()
        guard let current, let compositePipeline, let blurPipeline, let maskPipeline, let cache else {
            copy(context)
            return
        }
        guard let luma = cameraTexture(current.frame.capturedImage, plane: 0, format: .r8Unorm, cache: cache),
              let chroma = cameraTexture(current.frame.capturedImage, plane: 1, format: .rg8Unorm, cache: cache),
              let y = CVMetalTextureGetTexture(luma), let uv = CVMetalTextureGetTexture(chroma) else {
            copy(context)
            fail("The camera textures could not be read for avatar compositing.")
            return
        }
        let width = max(context.targetColorTexture.width / 2, 1)
        let height = max(context.targetColorTexture.height / 2, 1)
        if mask?.width != width || mask?.height != height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: width, height: height, mipmapped: false)
            descriptor.storageMode = .private
            descriptor.usage = [.renderTarget, .shaderRead]
            mask = context.device.makeTexture(descriptor: descriptor)
            descriptor.pixelFormat = .r16Float
            descriptor.usage = [.shaderRead, .shaderWrite]
            blurred = context.device.makeTexture(descriptor: descriptor)
        }
        guard let mask, let blurred else { copy(context); fail("The face mask could not be allocated."); return }
        let fresh = ProcessInfo.processInfo.systemUptime - current.publishedAt < 0.15
        let points = fresh ? current.outline : []
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = mask
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        guard let render = context.commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { copy(context); return }
        render.setRenderPipelineState(maskPipeline)
        render.setCullMode(.none)
        var contourBuffer: MTLBuffer?
        if points.count >= 3 {
            let center = points.reduce(SIMD2<Float>.zero, +) / Float(points.count)
            var triangles: [SIMD2<Float>] = []
            for index in points.indices {
                triangles += [center, points[index], points[(index + 1) % points.count]]
            }
            triangles.withUnsafeBytes { data in
                if let base = data.baseAddress, let buffer = context.device.makeBuffer(bytes: base, length: data.count) {
                    contourBuffer = buffer
                    render.setVertexBuffer(buffer, offset: 0, index: 0)
                    render.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: triangles.count)
                }
            }
        }
        render.endEncoding()
        guard let blur = context.commandBuffer.makeComputeCommandEncoder() else { copy(context); return }
        blur.setComputePipelineState(blurPipeline)
        blur.setTexture(mask, index: 0)
        blur.setTexture(blurred, index: 1)
        dispatch(blur, pipeline: blurPipeline, width: width, height: height)
        blur.endEncoding()
        guard let composite = context.commandBuffer.makeComputeCommandEncoder() else { copy(context); return }
        composite.setComputePipelineState(compositePipeline)
        composite.setTexture(context.sourceColorTexture, index: 0)
        let target = rawTarget(context.targetColorTexture)
        composite.setTexture(target, index: 1)
        composite.setTexture(y, index: 2)
        composite.setTexture(uv, index: 3)
        composite.setTexture(blurred, index: 4)
        var transform = current.imageTransform
        var encoding = colorEncoding(context)
        composite.setBytes(&transform, length: MemoryLayout<simd_float3x3>.stride, index: 0)
        composite.setBytes(&encoding, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 1)
        dispatch(composite, pipeline: compositePipeline, width: context.targetColorTexture.width, height: context.targetColorTexture.height)
        composite.endEncoding()
        // CVMetalTextureCache wrappers and the captured frame must outlive all encoded GPU reads.
        let resources = CompositeGPUResources(frame: current, luma: luma, chroma: chroma,
                                             mask: mask, blurred: blurred, contour: contourBuffer, target: target)
        context.commandBuffer.addCompletedHandler { [resources, weak self] command in
            withExtendedLifetime(resources) {}
            if command.status == .error { self?.fail("The GPU could not composite the avatar. Select Original to continue.") }
        }
    }

    private func dispatch(_ encoder: MTLComputeCommandEncoder, pipeline: MTLComputePipelineState, width: Int, height: Int) {
        let w = pipeline.threadExecutionWidth
        encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: w, height: min(8, pipeline.maxTotalThreadsPerThreadgroup / w), depth: 1))
    }

    private func cameraTexture(_ image: CVPixelBuffer, plane: Int, format: MTLPixelFormat, cache: CVMetalTextureCache) -> CVMetalTexture? {
        guard CVPixelBufferGetPlaneCount(image) > plane else { return nil }
        var texture: CVMetalTexture?
        let result = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, image, nil, format,
            CVPixelBufferGetWidthOfPlane(image, plane), CVPixelBufferGetHeightOfPlane(image, plane), plane, &texture)
        return result == kCVReturnSuccess ? texture : nil
    }

    private func copy(_ context: ARView.PostProcessContext) {
        // RealityKit requires every callback, including its early exits, to write the target.
        if let copyPipeline, let encoder = context.commandBuffer.makeComputeCommandEncoder() {
            encoder.setComputePipelineState(copyPipeline)
            encoder.setTexture(context.sourceColorTexture, index: 0)
            let target = rawTarget(context.targetColorTexture)
            encoder.setTexture(target, index: 1)
            var encoding = colorEncoding(context)
            encoder.setBytes(&encoding, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 0)
            dispatch(encoder, pipeline: copyPipeline, width: context.targetColorTexture.width, height: context.targetColorTexture.height)
            encoder.endEncoding()
            let resources = CopyGPUResources(target: target)
            context.commandBuffer.addCompletedHandler { [resources] _ in withExtendedLifetime(resources) {} }
        } else {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = context.targetColorTexture
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
            context.commandBuffer.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
        }
    }

    private func rawTarget(_ texture: MTLTexture) -> MTLTexture {
        // Use an unorm view for sRGB storage so the compute kernel explicitly owns output encoding.
        switch texture.pixelFormat {
        case .bgra8Unorm_srgb: return texture.makeTextureView(pixelFormat: .bgra8Unorm) ?? texture
        case .rgba8Unorm_srgb: return texture.makeTextureView(pixelFormat: .rgba8Unorm) ?? texture
        default: return texture
        }
    }

    private func colorEncoding(_ context: ARView.PostProcessContext) -> SIMD2<UInt32> {
        let floating: [MTLPixelFormat] = [.rgba16Float, .rgba32Float]
        let sampledLinear = floating + [.bgra8Unorm_srgb, .rgba8Unorm_srgb]
        return SIMD2(sampledLinear.contains(context.sourceColorTexture.pixelFormat) ? 1 : 0,
                     floating.contains(context.targetColorTexture.pixelFormat) ? 1 : 0)
    }

    private func fail(_ message: String) {
        snapshotLock.lock()
        let first = !reportedFailure
        reportedFailure = true
        snapshotLock.unlock()
        if first { onFailure(message) }
    }
}

nonisolated private struct CompositeGPUResources: @unchecked Sendable {
    let frame: CompositeFrame
    let luma: CVMetalTexture
    let chroma: CVMetalTexture
    let mask: MTLTexture
    let blurred: MTLTexture
    let contour: MTLBuffer?
    let target: MTLTexture
}

nonisolated private struct CopyGPUResources: @unchecked Sendable {
    let target: MTLTexture
}
