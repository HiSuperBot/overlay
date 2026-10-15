import Foundation
import Metal
import simd

private struct TestFailure: Error { let message: String }
private func expect(_ value: Bool, _ message: String) throws {
    if !value { throw TestFailure(message: message) }
}

private struct MaskRenderer {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState
    let texture: MTLTexture
    let size = 256

    init(libraryURL: URL) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw TestFailure(message: "Metal is required for the offscreen face-mask test.")
        }
        self.device = device
        self.queue = queue
        let library = try device.makeLibrary(URL: libraryURL)
        let pipeline = MTLRenderPipelineDescriptor()
        pipeline.vertexFunction = library.makeFunction(name: "avatarMaskVertex")
        pipeline.fragmentFunction = library.makeFunction(name: "avatarMaskFragment")
        pipeline.colorAttachments[0].pixelFormat = .r8Unorm
        self.pipeline = try device.makeRenderPipelineState(descriptor: pipeline)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: size, height: size, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.renderTarget, .shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw TestFailure(message: "The mask target could not be allocated.")
        }
        self.texture = texture
    }

    func draw(_ triangles: [SIMD2<Float>]) throws -> [UInt8] {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        guard let command = queue.makeCommandBuffer(), let render = command.makeRenderCommandEncoder(descriptor: pass) else {
            throw TestFailure(message: "The mask render pass could not start.")
        }
        render.setRenderPipelineState(pipeline)
        render.setCullMode(.none)
        var buffer: MTLBuffer?
        if !triangles.isEmpty {
            buffer = triangles.withUnsafeBytes { data in
                device.makeBuffer(bytes: data.baseAddress!, length: data.count)
            }
            guard let buffer else { throw TestFailure(message: "The mask vertices could not be allocated.") }
            render.setVertexBuffer(buffer, offset: 0, index: 0)
            render.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: triangles.count)
        }
        render.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        withExtendedLifetime(buffer) {}
        try expect(command.status == .completed, "The mask GPU pass must complete.")
        var bytes = [UInt8](repeating: 0, count: size * size)
        bytes.withUnsafeMutableBytes { data in
            texture.getBytes(data.baseAddress!, bytesPerRow: size, from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0)
        }
        return bytes
    }

    func sample(_ bytes: [UInt8], at point: SIMD2<Float>) -> UInt8 {
        bytes[min(max(Int(point.y * Float(size)), 0), size - 1) * size
            + min(max(Int(point.x * Float(size)), 0), size - 1)]
    }
}

@main
struct AvatarMaskTests {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { throw TestFailure(message: "Pass the compiled avatar Metal library.") }
        let renderer = try MaskRenderer(libraryURL: URL(fileURLWithPath: CommandLine.arguments[1]))
        let topology = FaceMaskTopology(indices: FaceMaskFixtures.indices, vertices: FaceMaskFixtures.vertices)!
        for angle: Float in [-50, 0, 50] {
            for pitch in [false, true] {
                let points = FaceMaskFixtures.projection(yaw: pitch ? 0 : angle, pitch: pitch ? angle : 0)
                let probe = FaceMaskFixtures.noseProbe(points)
                let mask = try renderer.draw(topology.triangles(projected: points))
                try expect(renderer.sample(mask, at: probe) == 255, "The projected nose must survive the actual mask shader.")
                try expect(renderer.sample(mask, at: SIMD2(0.02, 0.02)) == 0, "The background must stay outside the mask.")
                if angle != 0 {
                    let legacy = try renderer.draw(FaceMaskFixtures.legacyOutline(points))
                    try expect(renderer.sample(legacy, at: probe) == 0, "The fixture must reproduce the previous nose clipping.")
                }
            }
        }
        print("PASS: offscreen Metal mask preserves the nose at frontal and +/-50 degree yaw/pitch; old outline reproduces clipping")

        let vertices: [SIMD3<Float>] = [SIMD3(-2, -2, 0), SIMD3(2, -2, 0), SIMD3(2, 2, 0), SIMD3(-2, 2, 0),
                                      SIMD3(-1, -1, 0), SIMD3(1, -1, 0), SIMD3(1, 1, 0), SIMD3(-1, 1, 0)]
        let indices: [UInt16] = [0, 1, 5, 0, 5, 4, 1, 2, 6, 1, 6, 5, 2, 3, 7, 2, 7, 6, 3, 0, 4, 3, 4, 7]
        let points = vertices.map { SIMD2($0.x, $0.y) / 5 + SIMD2(repeating: 0.5) }
        let open = try renderer.draw(indices.map { points[Int($0)] })
        try expect(renderer.sample(open, at: SIMD2(0.5, 0.5)) == 0, "The fixture must start with a real hole.")
        let closed = try renderer.draw(FaceMaskTopology(indices: indices, vertices: vertices)!.triangles(projected: points))
        try expect(renderer.sample(closed, at: SIMD2(0.5, 0.5)) == 255, "Eye and mouth holes must be opaque.")
        let empty = try renderer.draw([])
        try expect(empty.allSatisfy { $0 == 0 }, "Tracking loss must clear the reused mask target.")
        print("PASS: actual mask shader fills holes and clears the reused mask when no face is supplied")
    }
}
