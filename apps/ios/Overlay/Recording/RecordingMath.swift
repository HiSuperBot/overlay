import Foundation

nonisolated struct RecordingDimensions: Equatable, Sendable {
    let width: Int
    let height: Int

    init?(width: Double, height: Double) {
        guard width.isFinite, height.isFinite, width >= 2, height >= 2 else { return nil }
        let scale = min(1, 1080 / width, 1920 / height)
        self.width = max(2, Int(width * scale) / 2 * 2)
        self.height = max(2, Int(height * scale) / 2 * 2)
    }
}

nonisolated struct RecordingTimeline: Sendable {
    private(set) var lastTimestamp: TimeInterval?

    // ARView may draw the same camera frame repeatedly. Admit at most 30 distinct frames per second.
    mutating func admit(_ timestamp: TimeInterval) -> Bool {
        guard timestamp.isFinite, timestamp >= 0 else { return false }
        if let lastTimestamp, timestamp - lastTimestamp < 1.0 / 30 - 0.001 { return false }
        lastTimestamp = timestamp
        return true
    }
}

nonisolated enum RecordingState: Equatable, Sendable {
    case idle, preparing, recording, finishing, saving

    var locksEffects: Bool { self != .idle }
    var canToggle: Bool { self == .idle || self == .recording }
}
