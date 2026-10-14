import Foundation
import Metal
import CoreMedia

// Renderers retain one sink for their entire lifetime; only the current recording changes.
nonisolated final class RecordingFrameSink: @unchecked Sendable {
    private let lock = NSLock()
    private var recorder: MovieRecorder?

    func activate(_ recorder: MovieRecorder?) {
        lock.lock()
        self.recorder = recorder
        lock.unlock()
    }

    func encode(texture: MTLTexture, command: MTLCommandBuffer, timestamp: TimeInterval, mirror: Bool) {
        lock.lock()
        let current = recorder
        lock.unlock()
        current?.encode(texture: texture, command: command, timestamp: timestamp, mirror: mirror)
    }

    func appendAudio(_ sample: CMSampleBuffer) {
        lock.lock()
        let current = recorder
        lock.unlock()
        current?.appendAudio(sample)
    }
}
