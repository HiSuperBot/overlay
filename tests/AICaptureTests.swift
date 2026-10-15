@preconcurrency import AVFoundation
import CoreVideo
import ZIPFoundation
import Foundation

private func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw AICaptureError(message: message) }
}
private final class FailureLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func append(_ message: String) { lock.lock(); values.append(message); lock.unlock() }
    var first: String? { lock.lock(); defer { lock.unlock() }; return values.first }
}

@main
struct AICaptureTests {
    static func main() async throws {
        let base = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let store = AICaptureStore(root: base.appendingPathComponent("captures"), exportsRoot: base.appendingPathComponent("exports"))
        try await store.prepare()
        let color = try SyntheticCapture.color()
        let types: [OSType] = [kCVPixelFormatType_DepthFloat16, kCVPixelFormatType_DepthFloat32,
                              kCVPixelFormatType_DisparityFloat16, kCVPixelFormatType_DisparityFloat32]
        var buffers: [CVPixelBuffer] = []
        var packed: [Data] = []
        for type in types {
            let (buffer, data) = try SyntheticCapture.depth(pixelFormat: type)
            buffers.append(buffer); packed.append(data)
            let sample = AIDepthSample(buffer: buffer, timestamp: 1, filtered: false, quality: 1, accuracy: 1, calibration: nil)
            let (actual, _) = try sample.packedData()
            try expect(CVPixelBufferGetBytesPerRow(buffer) > 3 * AIDepthFormat(pixelFormat: type)!.bytesPerPixel, "The fixture must contain row padding.")
            try expect(actual == data, "Depth copying must preserve all bits, NaN payloads, infinities, and exclude row padding.")
        }
        print("PASS: all four native depth/disparity float formats preserve bytes and strip row padding")
        let manifest = makeManifest(color: color)
        let folder = try await store.reserve(manifest)
        let failures = FailureLog()
        let recorder = try AICaptureRecorder(folder: folder, manifest: manifest, source: color,
                                            onStarted: { _ in }, onFailure: { failures.append($0) })
        var expectedBytes = Data()
        for index in 0..<30 {
            let time = 900 + Double(index) / 30
            var depth: AIDepthSample?
            if index % 2 == 0 {
                let typeIndex = (index / 2) % 4
                depth = AIDepthSample(buffer: buffers[typeIndex], timestamp: time - 0.02,
                                     filtered: false, quality: 1, accuracy: 1, calibration: nil)
                expectedBytes.append(packed[typeIndex])
            }
            recorder.appendAudio(try SyntheticCapture.audio(time: time + 0.001))
            let frame = AICaptureFrame(color: color, timestamp: time, rgbIntrinsics: SyntheticCapture.intrinsics, depth: depth)
            recorder.append(frame)
            recorder.append(frame)
            try await Task.sleep(for: .milliseconds(35))
        }
        let finished = try await recorder.finish()
        let item = try await store.finalize(finished)
        try expect(failures.first == nil, failures.first ?? "AI recording must succeed.")
        try expect(item.manifest.status == .complete && item.manifest.hasAudio, "Video, depth, and sound must finalize as a complete capture.")
        try expect(item.manifest.videoFrameCount == 30 && item.manifest.depthFrameCount == 15 && item.manifest.missingDepthFrameCount == 15, "Missing depth must be explicit without omitting RGB frames.")
        try expect(try Data(contentsOf: folder.appendingPathComponent("depth.bin")) == expectedBytes, "Recorded depth must be byte-exact.")
        let records = try readFrames(folder)
        try expect(records.count == 30 && records[1].depthMissing && records[0].depth!.calibrationMissing, "Missing measurements/calibration must be explicit.")
        try expect(abs(records[0].depth!.relativeTimestamp + 0.02) < 0.00001, "The first depth sample may precede the first RGB timestamp.")
        try expect(records.allSatisfy { $0.rgbIntrinsics == SyntheticCapture.intrinsics }, "RGB intrinsics must remain in native pixel coordinates.")
        try await inspectVideo(item, expectedFrames: 30)
        if let (data, record) = try await store.firstDepth(in: item) {
            try expect(AIDepthVisualization.image(data: data, record: record) != nil, "A valid first sample must generate a visualization.")
        } else { throw AICaptureError(message: "A depth preview must be available.") }
        print("PASS: native YUV H.264/AAC video, full resolution, unmirrored pixels, independent depth timestamps and missing samples")

        let zip = try await store.export(item)
        let archive = try Archive(url: zip, accessMode: .read)
        for name in ["video.mp4", "depth.bin", "frames.jsonl", "manifest.json"] {
            guard let entry = archive["\(item.id.uuidString)/\(name)"] else { throw AICaptureError(message: "The ZIP is missing \(name).") }
            var restored = Data()
            _ = try archive.extract(entry) { restored.append($0) }
            try expect(restored == Data(contentsOf: folder.appendingPathComponent(name)), "Export must preserve \(name).")
        }
        try expect(FileManager.default.fileExists(atPath: folder.path), "Export must retain the original bundle.")
        await store.removeExport(zip)
        print("PASS: ZIP export includes every capture file byte-for-byte and keeps original data")

        let damagedID = UUID()
        let damagedFolder = folder.deletingLastPathComponent().appendingPathComponent(damagedID.uuidString)
        try FileManager.default.copyItem(at: folder, to: damagedFolder)
        let damagedManifest = makeManifest(color: color, id: damagedID)
        try damagedManifest.write(to: damagedFolder)
        for (name, tail) in [("frames.jsonl", Data("{\"index\":".utf8)), ("depth.bin", Data([1, 2, 3]))] {
            let file = try FileHandle(forWritingTo: damagedFolder.appendingPathComponent(name))
            try file.seekToEnd(); try file.write(contentsOf: tail); try file.close()
        }
        let relaunched = AICaptureStore(root: folder.deletingLastPathComponent(), exportsRoot: base.appendingPathComponent("relaunch-exports"))
        let recovered = try await relaunched.list()
        let repaired = recovered.first { $0.id == damagedID }!
        try expect(repaired.manifest.status == .incomplete && repaired.manifest.videoFrameCount == 30 && repaired.manifest.depthFrameCount == 15, "Interrupted index tails must be repaired without claiming completion.")
        try expect(try Data(contentsOf: damagedFolder.appendingPathComponent("depth.bin")) == expectedBytes, "Recovery must retain committed depth and remove its unindexed tail.")
        let noDepth = UUID()
        let noDepthFolder = folder.deletingLastPathComponent().appendingPathComponent(noDepth.uuidString)
        try FileManager.default.copyItem(at: folder, to: noDepthFolder)
        try makeManifest(color: color, id: noDepth).write(to: noDepthFolder)
        try Data().write(to: noDepthFolder.appendingPathComponent("depth.bin"))
        let missing = try await relaunched.list().first { $0.id == noDepth }!
        try expect(missing.manifest.status == .incomplete, "A capture without depth must not recover as complete.")
        let shortVideoID = UUID()
        let shortFolder = folder.deletingLastPathComponent().appendingPathComponent(shortVideoID.uuidString)
        try FileManager.default.copyItem(at: folder, to: shortFolder)
        try makeManifest(color: color, id: shortVideoID).write(to: shortFolder)
        let extraFrame = AIFrameRecord(index: 30, timestamp: 901, videoTime: 1,
                                       rgbIntrinsics: SyntheticCapture.intrinsics, depth: nil, depthMissing: true)
        let extraFile = try FileHandle(forWritingTo: shortFolder.appendingPathComponent("frames.jsonl"))
        var extraBytes = try JSONEncoder().encode(extraFrame)
        extraBytes.append(0x0A)
        try extraFile.seekToEnd(); try extraFile.write(contentsOf: extraBytes); try extraFile.close()
        let shortVideo = try await relaunched.list().first { $0.id == shortVideoID }!
        try expect(shortVideo.manifest.status == .incomplete && shortVideo.manifest.videoFrameCount == 31,
                   "Recovery must flag video shorter than its index while preserving available sensor records.")
        try await relaunched.delete(repaired)
        try expect(!FileManager.default.fileExists(atPath: damagedFolder.path), "Deletion must remove the entire selected bundle.")
        print("PASS: relaunch repairs tails, detects missing depth/short video, preserves sensor records, and deletes bundles")

        let burstManifest = makeManifest(color: color)
        let burstFolder = try await store.reserve(burstManifest)
        let burst = try AICaptureRecorder(folder: burstFolder, manifest: burstManifest, source: color, onStarted: { _ in }, onFailure: { _ in })
        for index in 0..<1000 {
            let time = 1000 + Double(index) / 30
            burst.append(AICaptureFrame(color: color, timestamp: time, rgbIntrinsics: SyntheticCapture.intrinsics,
                depth: AIDepthSample(buffer: buffers[0], timestamp: time - 0.01, filtered: false, quality: 1, accuracy: 1, calibration: nil)))
        }
        burst.stopAccepting()
        burst.append(AICaptureFrame(color: color, timestamp: 9999, rgbIntrinsics: SyntheticCapture.intrinsics, depth: nil))
        let burstResult = try await burst.finish(reason: "Test interruption")
        let burstSummary = try AICaptureJournal.scan(folder: burstFolder, repair: false)
        try expect(burstResult.droppedFrameCount > 0 && burstResult.videoFrameCount == burstResult.depthFrameCount && !burstSummary.hadInvalidTail, "Backpressure must drop complete pairs and drain accepted work consistently.")
        try expect(burstResult.duration < 100, "Late frames after stop must not enter the capture.")
        print("PASS: bounded burst admission, paired drops, stop barrier, and late-frame rejection")

        let lowSpace = AICaptureStore(root: base.appendingPathComponent("low-space"), capacityProvider: { _ in 511 * 1024 * 1024 })
        do { _ = try await lowSpace.reserve(makeManifest(color: color)); throw AICaptureError(message: "Low storage must reject preparation.") }
        catch let error as AICaptureError { try expect(error.message.contains("512 MB"), "Low storage must explain the reserve requirement.") }
        print("PASS: storage reserve rejects an AI capture before creating its data files")
    }

    private static func makeManifest(color: CVPixelBuffer, id: UUID = UUID()) -> AICaptureManifest {
        AICaptureManifest(id: id, createdAt: Date(), videoWidth: 160, videoHeight: 120,
                          videoPixelFormat: CVPixelBufferGetPixelFormatType(color),
                          videoPresentationTransform: [0, 1, -1, 0, 120, 0], previewEffect: "human-b")
    }
    private static func readFrames(_ folder: URL) throws -> [AIFrameRecord] {
        try String(contentsOf: folder.appendingPathComponent("frames.jsonl"), encoding: .utf8)
            .split(separator: "\n").map { try JSONDecoder().decode(AIFrameRecord.self, from: Data($0.utf8)) }
    }
    private static func inspectVideo(_ item: AICaptureItem, expectedFrames: Int) async throws {
        let asset = AVURLAsset(url: item.videoURL)
        let videos = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        try expect(videos.count == 1 && audio.count == 1, "The original MP4 must contain both tracks.")
        let size = try await videos[0].load(.naturalSize)
        let transform = try await videos[0].load(.preferredTransform)
        try expect(size.width == 160 && size.height == 120 && transform.b == 1 && transform.c == -1, "Original dimensions and portrait presentation metadata must be retained.")
        let audioTime = try await audio[0].load(.timeRange)
        try expect(audioTime.start.seconds >= 0 && audioTime.start.seconds < 0.1, "Audio must share the video clock.")
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: videos[0], outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        try expect(reader.startReading(), "The original video must decode.")
        var count = 0
        var last: CMTime?
        while let sample = output.copyNextSampleBuffer() {
            let time = CMSampleBufferGetPresentationTimeStamp(sample)
            if let last { try expect(time > last, "Video times must strictly increase.") }
            else {
                try expect(abs(time.seconds) < 0.001, "The first video frame must start at zero.")
                let buffer = CMSampleBufferGetImageBuffer(sample)!
                CVPixelBufferLockBaseAddress(buffer, .readOnly)
                defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
                let bytes = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
                let stride = CVPixelBufferGetBytesPerRow(buffer)
                let left = 30 * stride + 40 * 4, right = 30 * stride + 120 * 4
                try expect(Int(bytes[left + 2]) > Int(bytes[left]) + 100 && Int(bytes[right]) > Int(bytes[right + 2]) + 100, "The saved source must keep its unmirrored red/blue camera pixels.")
                try expect(abs(Int(bytes[90 * stride + 80 * 4]) - 128) < 15, "Full-range camera brightness must survive encoding.")
            }
            last = time
            count += 1
        }
        try expect(count == expectedFrames && reader.status == .completed, "Duplicate or unindexed video frames must not be saved.")
    }
}
