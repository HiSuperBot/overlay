@preconcurrency import AVFoundation
import CoreVideo
@preconcurrency import Metal
import Foundation

private struct TestFailure: Error { let message: String }
private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw TestFailure(message: message) }
}

private final class Failures: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []
    func append(_ message: String) { lock.lock(); messages.append(message); lock.unlock() }
    var first: String? { lock.lock(); defer { lock.unlock() }; return messages.first }
}

@main
struct MovieRecorderTests {
    static func main() async throws {
        guard CommandLine.arguments.count == 3, let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { throw TestFailure(message: "Metal and test paths are required.") }
        let library = try device.makeLibrary(URL: URL(fileURLWithPath: CommandLine.arguments[1]))
        let folder = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let dimensions = RecordingDimensions(width: 160, height: 200)!

        for (index, format) in [MTLPixelFormat.bgra8Unorm, .bgra8Unorm_srgb, .rgba16Float].enumerated() {
            let errors = Failures()
            let mirror = index != 0
            let recorder = try MovieRecorder(device: device, dimensions: dimensions,
                url: folder.appendingPathComponent("color-\(index).mp4"), library: library,
                onStarted: { _ in }, onFailure: { errors.append($0) })
            let texture = try makeTexture(device: device, format: format)
            let epoch = 12345.0
            for frame in 0..<30 {
                let time = epoch + Double(frame) / 30
                recorder.appendAudio(try makeAudio(time: time + 0.001))
                let command = queue.makeCommandBuffer()!
                recorder.encode(texture: texture, command: command, timestamp: time, mirror: mirror)
                recorder.encode(texture: texture, command: command, timestamp: time, mirror: mirror)
                recorder.encode(texture: texture, command: command, timestamp: time - 1, mirror: mirror)
                try await commitAndWait(command)
                try await Task.sleep(for: .milliseconds(34))
            }
            let result = try await recorder.finish()
            try expect(result.hasAudio && errors.first == nil, errors.first ?? "AAC audio must be recorded.")
            try await inspect(result.url, dimensions: dimensions, mirror: mirror, minimumFrames: 27, maximumDuration: 1.1)
            print("PASS: H.264 + AAC MP4, \(format), mirror=\(mirror), normalized timeline and decoded colors")
        }

        // Stop while work is still on the GPU. A later frame must not enter the stopped clip.
        let errors = Failures()
        let quick = try MovieRecorder(device: device, dimensions: dimensions,
            url: folder.appendingPathComponent("quick-stop.mp4"), library: library,
            onStarted: { _ in }, onFailure: { errors.append($0) })
        let texture = try makeTexture(device: device, format: .bgra8Unorm)
        let command = queue.makeCommandBuffer()!
        quick.appendAudio(try makeAudio(time: 50.001))
        for frame in 0..<3 { quick.encode(texture: texture, command: command, timestamp: 50 + Double(frame) / 30, mirror: false) }
        quick.stopAccepting()
        quick.encode(texture: texture, command: command, timestamp: 500, mirror: false)
        command.commit()
        let result = try await quick.finish()
        try expect(errors.first == nil, errors.first ?? "In-flight frames must finalize.")
        try await inspect(result.url, dimensions: dimensions, mirror: false, minimumFrames: 1, maximumDuration: 0.15)
        print("PASS: immediate stop drains in-flight GPU frames and ignores late submissions")

        let empty = try MovieRecorder(device: device, dimensions: dimensions,
            url: folder.appendingPathComponent("empty.mp4"), library: library,
            onStarted: { _ in }, onFailure: { _ in })
        do {
            _ = try await empty.finish()
            throw TestFailure(message: "An empty recording must fail.")
        } catch is MovieRecordingError {}
        print("PASS: stopping before the first valid frame rejects an empty recording")

        let recovery = folder.appendingPathComponent("recovery", isDirectory: true)
        try FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: true)
        let source = folder.appendingPathComponent("color-0.mp4")
        for name in ["writing-manifest.mp4", "writing-completed.mp4", "completed.mp4"] {
            try FileManager.default.copyItem(at: source, to: recovery.appendingPathComponent(name))
        }
        let emptyURL = recovery.appendingPathComponent("writing-empty.mp4")
        try Data().write(to: emptyURL)
        try JSONEncoder().encode(["writing-manifest.mp4", "../outside.mp4"]).write(to: recovery.appendingPathComponent("pending.json"))
        let pending = await RecordingRecovery.pendingVideos(in: recovery)
        try expect(Set(pending.map(\.lastPathComponent)) == Set(["writing-manifest.mp4", "writing-completed.mp4", "completed.mp4"]), "Completed and manifest clips must survive recovery, including interrupted renames.")
        try expect(pending.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }, "Recovery must not delete a completed clip.")
        try expect(!FileManager.default.fileExists(atPath: emptyURL.path), "An abandoned empty staging file must be cleaned up.")
        print("PASS: completed staging clips and pending manifest files survive relaunch recovery")
    }

    private static func makeTexture(device: MTLDevice, format: MTLPixelFormat) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: 160, height: 200, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw TestFailure(message: "Test texture allocation failed.") }
        if format == .rgba16Float {
            var values: [Float16] = []
            for y in 0..<200 {
                for x in 0..<160 {
                    if y >= 100 { values += [0.21586, 0.21586, 0.21586, 1] }
                    else if x < 80 { values += [1, 0, 0, 1] }
                    else { values += [0, 0, 1, 1] }
                }
            }
            values.withUnsafeBytes { texture.replace(region: MTLRegionMake2D(0, 0, 160, 200), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 160 * 8) }
        } else {
            var values: [UInt8] = []
            for y in 0..<200 {
                for x in 0..<160 {
                    if y >= 100 { values += [128, 128, 128, 255] }
                    else if x < 80 { values += [0, 0, 255, 255] }
                    else { values += [255, 0, 0, 255] }
                }
            }
            values.withUnsafeBytes { texture.replace(region: MTLRegionMake2D(0, 0, 160, 200), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 160 * 4) }
        }
        return texture
    }

    private static func makeAudio(time: Double) throws -> CMSampleBuffer {
        var description = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 4,
            mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &description, layoutSize: 0,
            layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format) == noErr else {
            throw TestFailure(message: "PCM format creation failed.")
        }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: 6400,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: 6400,
            flags: 0, blockBufferOut: &block) == kCMBlockBufferNoErr, let block else {
            throw TestFailure(message: "PCM buffer creation failed.")
        }
        let tone: [Float] = (0..<1600).map { 0.05 * sin(Float($0) * 2 * .pi * 440 / 48_000) }
        let copied = tone.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: 6400) }
        try expect(copied == noErr, "PCM samples must be copied.")
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000),
            presentationTimeStamp: CMTime(seconds: time, preferredTimescale: 1_000_000_000), decodeTimeStamp: .invalid)
        var size = 4
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: block, dataReady: true,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: format, sampleCount: 1600,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
            sampleSizeArray: &size, sampleBufferOut: &sample) == noErr, let sample else {
            throw TestFailure(message: "PCM sample creation failed.")
        }
        return sample
    }

    private static func commitAndWait(_ command: MTLCommandBuffer) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            command.addCompletedHandler { result in
                if result.status == .completed { continuation.resume() }
                else { continuation.resume(throwing: TestFailure(message: "The test GPU command failed.")) }
            }
            command.commit()
        }
    }

    private static func inspect(_ url: URL, dimensions: RecordingDimensions, mirror: Bool, minimumFrames: Int, maximumDuration: Double) async throws {
        let asset = AVURLAsset(url: url)
        let video = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        try expect(video.count == 1 && audio.count == 1, "The MP4 must contain one video track and one audio track.")
        let formats = try await video[0].load(.formatDescriptions)
        try expect(CMFormatDescriptionGetMediaSubType(formats[0]) == kCMVideoCodecType_H264, "The video must be H.264.")
        let audioFormats = try await audio[0].load(.formatDescriptions)
        try expect(CMFormatDescriptionGetMediaSubType(audioFormats[0]) == kAudioFormatMPEG4AAC, "The audio must be AAC.")
        let size = try await video[0].load(.naturalSize)
        try expect(size.width == Double(dimensions.width) && size.height == Double(dimensions.height), "Encoded dimensions must be fixed.")
        let duration = try await asset.load(.duration)
        try expect(duration.seconds > 0 && duration.seconds <= maximumDuration, "Capture time must be normalized and stop must bound duration.")
        let audioRange = try await audio[0].load(.timeRange)
        try expect(audioRange.start.seconds < 0.12 && audioRange.duration.seconds > 0, "Audio must begin alongside video.")
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: video[0], outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        try expect(reader.startReading(), "The encoded MP4 must decode.")
        var count = 0
        var last: CMTime?
        while let sample = output.copyNextSampleBuffer() {
            let time = CMSampleBufferGetPresentationTimeStamp(sample)
            if let last { try expect(time > last, "Decoded frame timestamps must strictly increase.") }
            else {
                try expect(abs(time.seconds) < 0.001, "The first video frame must start at zero.")
                guard let buffer = CMSampleBufferGetImageBuffer(sample) else { throw TestFailure(message: "Video pixels must decode.") }
                CVPixelBufferLockBaseAddress(buffer, .readOnly)
                defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
                let bytes = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
                let stride = CVPixelBufferGetBytesPerRow(buffer)
                let left = 50 * stride + 40 * 4
                let right = 50 * stride + 120 * 4
                try expect(mirror ? bytes[left] > bytes[left + 2] : bytes[left + 2] > bytes[left], "The left color must match the preview reflection.")
                try expect(mirror ? bytes[right + 2] > bytes[right] : bytes[right] > bytes[right + 2], "The right color must match the preview reflection.")
                try expect(abs(Int(bytes[150 * stride + 80 * 4]) - 128) < 12, "sRGB and linear sources must preserve mid-gray brightness.")
            }
            last = time
            count += 1
        }
        try expect(reader.status == .completed && count >= minimumFrames && count <= 30, "Frames must decode without duplicate or backward samples.")
    }
}
