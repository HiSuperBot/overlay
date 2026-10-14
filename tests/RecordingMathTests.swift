import Foundation

private struct TestFailure: Error { let message: String }
private func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw TestFailure(message: message) }
}

@main
struct RecordingMathTests {
    static func main() throws {
        let portrait = RecordingDimensions(width: 1179, height: 1831)!
        try expect(portrait.width == 1080 && portrait.height % 2 == 0 && portrait.height <= 1920, "Portrait bounds must fit the encoder.")
        try expect(abs(Double(portrait.width) / Double(portrait.height) - 1179.0 / 1831) < 0.002, "Preview aspect must survive rounding.")
        let tall = RecordingDimensions(width: 1200, height: 3000)!
        try expect(tall.width == 768 && tall.height == 1920, "Tall previews must also respect the height limit.")
        let small = RecordingDimensions(width: 321, height: 481)!
        try expect(small.width == 320 && small.height == 480, "Small previews must not be upscaled.")
        try expect(RecordingDimensions(width: 0, height: 500) == nil && RecordingDimensions(width: .infinity, height: 500) == nil, "Invalid viewports must be rejected.")
        print("PASS: even output dimensions preserve preview aspect within 1080 × 1920")

        var timeline = RecordingTimeline()
        try expect(!timeline.admit(.nan) && !timeline.admit(.infinity) && !timeline.admit(-1), "Invalid times must not enter the writer.")
        try expect(timeline.admit(500), "The first capture timestamp must be admitted.")
        try expect(!timeline.admit(500) && !timeline.admit(499), "Repeated and backward frames must be rejected.")
        try expect(!timeline.admit(500 + 1.0 / 60), "60fps input must not become 60fps recording.")
        try expect(timeline.admit(500 + 1.0 / 30 - 0.0005), "Small capture-clock jitter must not halve frame rate.")
        try expect(timeline.admit(505), "A dropped-frame gap must retain elapsed time.")
        print("PASS: duplicate, backward, non-finite, and over-rate timestamps are rejected")

        var regular = RecordingTimeline()
        let accepted = (0..<120).filter { regular.admit(1000 + Double($0) / 60) }
        try expect(accepted.count == 60, "A two-second 60fps source must admit 60 frames.")
        var restarted = RecordingTimeline()
        try expect(restarted.admit(2), "A new clip must have an independent epoch.")
        print("PASS: 60fps sources are gated to 30fps and new clips restart independently")
    }
}
