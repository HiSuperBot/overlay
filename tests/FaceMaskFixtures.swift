import simd

enum FaceMaskFixtures {
    // A raised nose sits inside the neutral face boundary but becomes its silhouette on rotation.
    static let vertices: [SIMD3<Float>] = [
        SIMD3(-0.055, -0.07, 0), SIMD3(0.055, -0.07, 0),
        SIMD3(0.055, 0.07, 0), SIMD3(-0.055, 0.07, 0), SIMD3(0, 0, 0.09),
    ]
    static let indices: [UInt16] = [0, 1, 4, 1, 2, 4, 2, 3, 4, 3, 0, 4]
    static let intrinsics = simd_float3x3(SIMD3(800, 0, 0), SIMD3(0, 800, 0), SIMD3(500, 400, 1))
    static let imageSize = SIMD2<Float>(1000, 800)

    static func projection(yaw: Float = 0, pitch: Float = 0) -> [SIMD2<Float>] {
        var transform = simd_float4x4(simd_quatf(angle: yaw * .pi / 180, axis: SIMD3(0, 1, 0)))
            * simd_float4x4(simd_quatf(angle: pitch * .pi / 180, axis: SIMD3(1, 0, 0)))
        transform.columns.3 = SIMD4(0, 0, -0.55, 1)
        return FaceMaskProjection.project(vertices: vertices, cameraFromFace: transform, intrinsics: intrinsics,
                                          imageSize: imageSize, imageToScreen: matrix_identity_float3x3)
    }

    static func noseProbe(_ points: [SIMD2<Float>]) -> SIMD2<Float> {
        points[4] * 0.9 + points.prefix(4).reduce(.zero, +) / 4 * 0.1
    }

    static func legacyOutline(_ points: [SIMD2<Float>]) -> [SIMD2<Float>] {
        let center = points.prefix(4).reduce(SIMD2<Float>.zero, +) / 4
        return (0..<4).flatMap { [center, points[$0], points[($0 + 1) % 4]] }
    }

    static func contains(_ point: SIMD2<Float>, triangles: [SIMD2<Float>]) -> Bool {
        func cross(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float { a.x * b.y - a.y * b.x }
        for i in stride(from: 0, to: triangles.count, by: 3) {
            let a = triangles[i], b = triangles[i + 1], c = triangles[i + 2]
            guard abs(cross(b - a, c - a)) > 0.0000001 else { continue }
            let edges = [cross(b - a, point - a), cross(c - b, point - b), cross(a - c, point - c)]
            if edges.allSatisfy({ $0 >= -0.000001 }) || edges.allSatisfy({ $0 <= 0.000001 }) { return true }
        }
        return false
    }
}
