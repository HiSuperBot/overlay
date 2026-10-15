import Foundation
import simd

nonisolated struct FaceMeasurements: Sendable {
    let leftEye: SIMD3<Float>
    let rightEye: SIMD3<Float>
    let width: Float
    let height: Float

    var isValid: Bool {
        let distance = simd_distance(leftEye, rightEye)
        return distance.isFinite && (0.035...0.09).contains(distance)
            && width.isFinite && (0.08...0.24).contains(width)
            && height.isFinite && (0.09...0.3).contains(height)
            && (0..<3).allSatisfy { leftEye[$0].isFinite && rightEye[$0].isFinite }
    }
}

nonisolated struct AvatarFit: Sendable {
    let scale: SIMD3<Float>
    let translation: SIMD3<Float>

    static func solve(face: FaceMeasurements, model: AvatarFittingMetadata) -> AvatarFit? {
        guard face.isValid, model.leftEye.count == 3, model.rightEye.count == 3 else { return nil }
        let left = SIMD3<Float>(model.leftEye[0], model.leftEye[1], model.leftEye[2])
        let right = SIMD3<Float>(model.rightEye[0], model.rightEye[1], model.rightEye[2])
        let distance = simd_distance(left, right)
        guard distance > 0.01, distance.isFinite,
              model.faceWidth.isFinite, model.faceHeight.isFinite,
              model.faceWidth > 0, model.faceHeight > 0 else { return nil }
        let eyeScale = simd_distance(face.leftEye, face.rightEye) / distance
        let widthScale = face.width / model.faceWidth
        let x = eyeScale * 0.75 + widthScale * 0.25
        let y = min(max(face.height / model.faceHeight, eyeScale * 0.8), eyeScale * 1.2)
        let scale = SIMD3<Float>(x, y, (x + y) * 0.5)
        guard (0..<3).allSatisfy({ scale[$0].isFinite && (0.5...1.8).contains(scale[$0]) }) else {
            return nil
        }
        let translation = (face.leftEye + face.rightEye) * 0.5 - scale * (left + right) * 0.5
        return AvatarFit(scale: scale, translation: translation)
    }
}

nonisolated struct NeutralFaceCalibrator {
    private var startedAt: TimeInterval?
    private var lastSample: TimeInterval?
    private var samples: [FaceMeasurements] = []
    private(set) var measurements: FaceMeasurements?

    mutating func reset() {
        interrupt()
        measurements = nil
    }

    mutating func interrupt() {
        startedAt = nil
        lastSample = nil
        samples.removeAll(keepingCapacity: true)
    }

    mutating func sample(_ face: FaceMeasurements, neutral: Bool, time: TimeInterval) {
        guard measurements == nil else { return }
        guard neutral, face.isValid else {
            interrupt()
            return
        }
        if let lastSample, time - lastSample > 0.15 || time < lastSample { interrupt() }
        lastSample = time
        if startedAt == nil { startedAt = time }
        samples.append(face)
        guard time - (startedAt ?? time) >= 1, samples.count >= 20 else { return }
        let count = Float(samples.count)
        measurements = FaceMeasurements(
            leftEye: samples.reduce(.zero) { $0 + $1.leftEye } / count,
            rightEye: samples.reduce(.zero) { $0 + $1.rightEye } / count,
            width: samples.reduce(0) { $0 + $1.width } / count,
            height: samples.reduce(0) { $0 + $1.height } / count
        )
        samples.removeAll(keepingCapacity: true)
    }
}

nonisolated struct ExpressionMapper {
    private var values: [String: Float] = [:]
    private var lastTime: TimeInterval?

    mutating func reset() { values.removeAll(keepingCapacity: true); lastTime = nil }

    mutating func update(
        sources: [String: Float], bindings: [String: AvatarDescriptor.ExpressionBinding],
        time: TimeInterval
    ) -> [String: Float] {
        let dt = min(max(time - (lastTime ?? (time - 1.0 / 30)), 0), 0.1)
        lastTime = time
        for (target, binding) in bindings {
            let raw = sources[binding.source] ?? 0
            let desired = raw.isFinite ? min(max(raw * binding.gain, 0), 1) : 0
            let fast = binding.source.hasPrefix("eyeBlink") || binding.source == "jawOpen"
            let alpha = Float(1 - exp(-dt / (fast ? 0.012 : 0.045)))
            let previous = values[target] ?? 0
            values[target] = previous + (desired - previous) * alpha
        }
        return values
    }
}

// Boundary loops identify holes to cap, not the screen-space silhouette of a rotated 3D face.
nonisolated enum FaceOutline {
    static func outerLoop(indices: [UInt16], vertices: [SIMD3<Float>]) -> [Int] {
        boundaryLoops(indices: indices, vertices: vertices)?.max {
            perimeter($0, vertices: vertices) < perimeter($1, vertices: vertices)
        } ?? []
    }

    static func perimeter(_ loop: [Int], vertices: [SIMD3<Float>]) -> Float {
        loop.indices.reduce(Float(0)) {
            $0 + simd_distance(vertices[loop[$1]], vertices[loop[($1 + 1) % loop.count]])
        }
    }

    static func boundaryLoops(indices: [UInt16], vertices: [SIMD3<Float>]) -> [[Int]]? {
        guard !indices.isEmpty, indices.count.isMultiple(of: 3),
              vertices.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) else { return nil }
        struct Edge: Hashable {
            let a: Int
            let b: Int
            init(_ a: Int, _ b: Int) { self.a = min(a, b); self.b = max(a, b) }
        }
        var counts: [Edge: Int] = [:]
        for i in stride(from: 0, to: indices.count - 2, by: 3) {
            let triangle = [Int(indices[i]), Int(indices[i + 1]), Int(indices[i + 2])]
            guard Set(triangle).count == 3, triangle.allSatisfy({ vertices.indices.contains($0) }) else { return nil }
            for j in 0..<3 { counts[Edge(triangle[j], triangle[(j + 1) % 3]), default: 0] += 1 }
        }
        guard counts.values.allSatisfy({ $0 <= 2 }) else { return nil }
        var neighbours: [Int: [Int]] = [:]
        for (edge, count) in counts where count == 1 {
            neighbours[edge.a, default: []].append(edge.b)
            neighbours[edge.b, default: []].append(edge.a)
        }
        var visited: Set<Int> = []
        var loops: [[Int]] = []
        for start in neighbours.keys.sorted() where !visited.contains(start) {
            var loop: [Int] = []
            var previous = -1
            var current = start
            while !visited.contains(current) {
                guard let next = neighbours[current], next.count == 2 else { return nil }
                visited.insert(current)
                loop.append(current)
                let candidate = next.first { $0 != previous }!
                previous = current
                current = candidate
            }
            guard current == start, loop.count >= 3 else { return nil }
            loops.append(loop)
        }
        return loops
    }
}

nonisolated struct FaceMaskTopology: Sendable {
    let vertexCount: Int
    private let indices: [UInt16]
    private let holes: [[Int]]

    init?(indices: [UInt16], vertices: [SIMD3<Float>]) {
        guard let loops = FaceOutline.boundaryLoops(indices: indices, vertices: vertices) else { return nil }
        let outer = loops.indices.max {
            FaceOutline.perimeter(loops[$0], vertices: vertices) < FaceOutline.perimeter(loops[$1], vertices: vertices)
        }
        self.vertexCount = vertices.count
        self.indices = indices
        holes = loops.indices.filter { $0 != outer }.map { loops[$0] }
    }

    func triangles(projected: [SIMD2<Float>]) -> [SIMD2<Float>] {
        guard projected.count == vertexCount,
              projected.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return [] }
        var result: [SIMD2<Float>] = []
        result.reserveCapacity(indices.count + holes.reduce(0) { $0 + $1.count * 3 })
        // Interior vertices can become the visible silhouette at yaw/pitch, especially the nose.
        for index in indices { result.append(projected[Int(index)]) }
        for loop in holes {
            let center = loop.reduce(SIMD2<Float>.zero) { $0 + projected[$1] } / Float(loop.count)
            guard center.x.isFinite, center.y.isFinite else { return [] }
            for i in loop.indices {
                result.append(contentsOf: [center, projected[loop[i]], projected[loop[(i + 1) % loop.count]]])
            }
        }
        return result
    }
}

nonisolated enum FaceMaskProjection {
    static func project(vertices: [SIMD3<Float>], cameraFromFace: simd_float4x4,
                        intrinsics: simd_float3x3, imageSize: SIMD2<Float>,
                        imageToScreen: simd_float3x3) -> [SIMD2<Float>] {
        guard imageSize.x.isFinite, imageSize.y.isFinite, imageSize.x > 0, imageSize.y > 0 else { return [] }
        var projected: [SIMD2<Float>] = []
        projected.reserveCapacity(vertices.count)
        for vertex in vertices {
            let camera = cameraFromFace * SIMD4(vertex, 1)
            guard camera.z < -0.01 else { return [] }
            // ARKit camera space is +Y up and -Z forward; image pixels are +Y down.
            let pixel = intrinsics * SIMD3(camera.x, -camera.y, -camera.z)
            let image = SIMD3(pixel.x / pixel.z / imageSize.x, pixel.y / pixel.z / imageSize.y, 1)
            let screen = imageToScreen * image
            let point = SIMD2(screen.x / screen.z, screen.y / screen.z)
            guard point.x.isFinite, point.y.isFinite else { return [] }
            projected.append(point)
        }
        return projected
    }
}
