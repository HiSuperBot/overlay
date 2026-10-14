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

// Boundary loops include eye and mouth holes. The longest loop encloses the entire face.
nonisolated enum FaceOutline {
    static func outerLoop(indices: [UInt16], vertices: [SIMD3<Float>]) -> [Int] {
        struct Edge: Hashable {
            let a: Int
            let b: Int
            init(_ a: Int, _ b: Int) { self.a = min(a, b); self.b = max(a, b) }
        }
        var counts: [Edge: Int] = [:]
        for i in stride(from: 0, to: indices.count - 2, by: 3) {
            let triangle = [Int(indices[i]), Int(indices[i + 1]), Int(indices[i + 2])]
            guard triangle.allSatisfy({ vertices.indices.contains($0) }) else { return [] }
            for j in 0..<3 { counts[Edge(triangle[j], triangle[(j + 1) % 3]), default: 0] += 1 }
        }
        var neighbours: [Int: [Int]] = [:]
        for (edge, count) in counts where count == 1 {
            neighbours[edge.a, default: []].append(edge.b)
            neighbours[edge.b, default: []].append(edge.a)
        }
        var visited: Set<Int> = []
        var best: [Int] = []
        var longest: Float = 0
        for start in neighbours.keys.sorted() where !visited.contains(start) {
            var loop: [Int] = []
            var previous = -1
            var current = start
            while !visited.contains(current) {
                guard let next = neighbours[current], next.count == 2 else { return [] }
                visited.insert(current)
                loop.append(current)
                let candidate = next.first { $0 != previous }!
                previous = current
                current = candidate
            }
            guard current == start, loop.count >= 3 else { continue }
            let perimeter = loop.indices.reduce(Float(0)) {
                $0 + simd_distance(vertices[loop[$1]], vertices[loop[($1 + 1) % loop.count]])
            }
            if perimeter > longest { longest = perimeter; best = loop }
        }
        return best
    }
}
