@preconcurrency import AVFoundation
import Foundation

nonisolated private struct AIAudioSample: @unchecked Sendable { let sample: CMSampleBuffer }

// This recorder consumes original sensor buffers; it has no compositor, Metal, UIKit, or Photos dependency.
nonisolated final class AICaptureRecorder: @unchecked Sendable {
    let folder: URL
    private let queue = DispatchQueue(label: "com.overlay.ai-writer", qos: .userInitiated)
    private let admission = NSLock()
    private let frameSlots = DispatchSemaphore(value: 3)
    private let audioSlots = DispatchSemaphore(value: 16)
    private var accepting = true
    private var finishing = false
    private var timeline = RecordingTimeline()
    private var droppedFrames = 0
    private var admittedDepth = false
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let journal: AICaptureJournal
    private var manifest: AICaptureManifest
    private let onStarted: @Sendable (Double) -> Void
    private let onFailure: @Sendable (String) -> Void
    // Writer-queue state.
    private var firstTimestamp: Double?
    private var lastAudioTime: CMTime?
    private var earlyAudio: [AIAudioSample] = []
    private var failure: String?

    init(folder: URL, manifest: AICaptureManifest, source: CVPixelBuffer,
         onStarted: @escaping @Sendable (Double) -> Void,
         onFailure: @escaping @Sendable (String) -> Void) throws {
        self.folder = folder
        self.manifest = manifest
        self.onStarted = onStarted
        self.onFailure = onFailure
        journal = try AICaptureJournal(folder: folder)
        writer = try AVAssetWriter(outputURL: folder.appendingPathComponent("video.mp4"), fileType: .mp4)
        writer.movieFragmentInterval = CMTime(value: 1, timescale: 1)
        var description: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: source,
                                                          formatDescriptionOut: &description) == noErr else {
            throw AICaptureError(message: "The original camera format could not be configured.")
        }
        var colors: [String: String] = [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_601_4,
        ]
        for (cv, av) in [(kCVImageBufferColorPrimariesKey, AVVideoColorPrimariesKey),
                         (kCVImageBufferTransferFunctionKey, AVVideoTransferFunctionKey),
                         (kCVImageBufferYCbCrMatrixKey, AVVideoYCbCrMatrixKey)] {
            if let value = CVBufferCopyAttachment(source, cv, nil) as? String { colors[av] = value }
        }
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: manifest.videoWidth, AVVideoHeightKey: manifest.videoHeight,
            AVVideoColorPropertiesKey: colors,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(8_000_000, Int(Double(manifest.videoWidth * manifest.videoHeight) * 30 * 0.18)),
                AVVideoExpectedSourceFrameRateKey: 30, AVVideoMaxKeyFrameIntervalKey: 30,
                AVVideoAllowFrameReorderingKey: false, AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ]
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings, sourceFormatHint: description)
        let transform = manifest.videoPresentationTransform
        guard transform.count == 6 else { throw AICaptureError(message: "The camera presentation transform is invalid.") }
        videoInput.transform = CGAffineTransform(a: transform[0], b: transform[1], c: transform[2],
                                                 d: transform[3], tx: transform[4], ty: transform[5])
        audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 128_000,
        ])
        videoInput.expectsMediaDataInRealTime = true
        audioInput.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: nil)
        guard writer.canAdd(videoInput), writer.canAdd(audioInput) else { throw AICaptureError(message: "Original video encoding is unavailable.") }
        writer.add(videoInput)
        writer.add(audioInput)
        guard writer.startWriting() else { throw writer.error ?? AICaptureError(message: "The AI video writer could not start.") }
    }

    func append(_ frame: AICaptureFrame) {
        admission.lock()
        defer { admission.unlock() }
        guard accepting else { return }
        guard admittedDepth || frame.depth != nil else { droppedFrames += 1; return }
        var candidate = timeline
        guard candidate.admit(frame.timestamp) else { return }
        guard frameSlots.wait(timeout: .now()) == .success else { droppedFrames += 1; return }
        timeline = candidate
        if frame.depth != nil { admittedDepth = true }
        queue.async { [self, frame] in
            defer { frameSlots.signal() }
            do { try writeFrame(frame) }
            catch { fail(error.localizedDescription) }
        }
    }

    func appendAudio(_ sample: CMSampleBuffer) {
        admission.lock()
        defer { admission.unlock() }
        guard accepting, audioSlots.wait(timeout: .now()) == .success else { return }
        let audio = AIAudioSample(sample: sample)
        queue.async { [self, audio] in
            defer { audioSlots.signal() }
            guard failure == nil else { return }
            if firstTimestamp == nil {
                earlyAudio.append(audio)
                if earlyAudio.count > 32 { earlyAudio.removeFirst() }
            } else { writeAudio(audio) }
        }
    }

    func checkStartup() {
        queue.async { [self] in
            if journal.summary.frameCount == 0 { fail("The camera did not provide an AI recording frame.") }
            else if lastAudioTime == nil { fail("The microphone did not provide audio for the AI capture.") }
        }
    }

    func stopAccepting() { admission.lock(); accepting = false; admission.unlock() }

    func finish(reason: String? = nil) async throws -> AICaptureManifest {
        stopAccepting()
        return try await withCheckedThrowingContinuation { continuation in
            admission.lock()
            let duplicate = finishing
            finishing = true
            admission.unlock()
            guard !duplicate else {
                continuation.resume(throwing: AICaptureError(message: "The AI capture is already finishing."))
                return
            }
            // All admissions enqueue under the same lock, so this barrier follows every accepted pair/audio sample.
            queue.async { [self] in
                let summary = journal.summary
                do { try journal.close() } catch { fail(error.localizedDescription) }
                manifest.startTimestamp = firstTimestamp
                manifest.videoFrameCount = summary.frameCount
                manifest.depthFrameCount = summary.depthCount
                manifest.missingDepthFrameCount = summary.frameCount - summary.depthCount
                admission.lock()
                manifest.droppedFrameCount = droppedFrames
                admission.unlock()
                manifest.hasAudio = lastAudioTime != nil
                manifest.stopReason = failure ?? reason
                manifest.duration = summary.lastTimestamp.map { $0 - (firstTimestamp ?? $0) + 1.0 / 30 } ?? 0
                guard firstTimestamp != nil, writer.status == .writing else {
                    writer.cancelWriting()
                    finishManifest(videoFinished: false, continuation: continuation)
                    return
                }
                if let end = summary.lastTimestamp {
                    writer.endSession(atSourceTime: CMTime(seconds: end + 1.0 / 30, preferredTimescale: 1_000_000_000))
                }
                videoInput.markAsFinished()
                audioInput.markAsFinished()
                earlyAudio.removeAll()
                writer.finishWriting { [self] in
                    queue.async { [self] in finishManifest(videoFinished: writer.status == .completed, continuation: continuation) }
                }
            }
        }
    }

    private func finishManifest(videoFinished: Bool, continuation: CheckedContinuation<AICaptureManifest, Error>) {
        if videoFinished, manifest.videoFrameCount > 0, manifest.depthFrameCount > 0, manifest.hasAudio, failure == nil {
            manifest.status = manifest.stopReason == nil ? .complete : .interrupted
        } else { manifest.status = .incomplete }
        if !videoFinished { manifest.stopReason = failure ?? writer.error?.localizedDescription ?? "The original video could not be finalized." }
        do { try manifest.write(to: folder); continuation.resume(returning: manifest) }
        catch { continuation.resume(throwing: error) }
    }

    private func writeFrame(_ frame: AICaptureFrame) throws {
        guard failure == nil else { countDropped(); return }
        guard firstTimestamp != nil || frame.depth != nil else { countDropped(); return }
        guard CVPixelBufferGetWidth(frame.color) == manifest.videoWidth,
              CVPixelBufferGetHeight(frame.color) == manifest.videoHeight,
              CVPixelBufferGetPixelFormatType(frame.color) == manifest.videoPixelFormat else {
            throw AICaptureError(message: "The camera format changed during AI capture.")
        }
        guard writer.status == .writing, videoInput.isReadyForMoreMediaData else {
            if writer.status == .failed { throw writer.error ?? AICaptureError(message: "Original video encoding failed.") }
            countDropped()
            return
        }
        // Packing/validation precedes video admission. A rejected RGB frame never writes an orphan depth block.
        let depth = try frame.depth?.packedData()
        if firstTimestamp == nil {
            firstTimestamp = frame.timestamp
            writer.startSession(atSourceTime: CMTime(seconds: frame.timestamp, preferredTimescale: 1_000_000_000))
        }
        guard adaptor.append(frame.color, withPresentationTime: CMTime(seconds: frame.timestamp, preferredTimescale: 1_000_000_000)) else {
            throw writer.error ?? AICaptureError(message: "The original camera frame could not be encoded.")
        }
        try journal.append(frame, startTimestamp: firstTimestamp!, packedDepth: depth)
        if journal.summary.frameCount == 1 {
            onStarted(frame.timestamp)
            for audio in earlyAudio { writeAudio(audio) }
            earlyAudio.removeAll()
        }
    }

    private func writeAudio(_ audio: AIAudioSample) {
        let time = CMSampleBufferGetPresentationTimeStamp(audio.sample)
        guard let firstTimestamp, time.isNumeric, time.seconds >= firstTimestamp,
              lastAudioTime == nil || time > lastAudioTime! else { return }
        guard let last = journal.summary.lastTimestamp, abs(time.seconds - last) < 2 else {
            fail("The AI camera and microphone timestamps could not be synchronized.")
            return
        }
        guard writer.status == .writing, audioInput.isReadyForMoreMediaData else { return }
        if audioInput.append(audio.sample) { lastAudioTime = time }
        else { fail(writer.error?.localizedDescription ?? "AI microphone audio could not be encoded.") }
    }

    private func countDropped() { admission.lock(); droppedFrames += 1; admission.unlock() }
    private func fail(_ message: String) {
        guard failure == nil else { return }
        failure = message
        onFailure(message)
    }
}
