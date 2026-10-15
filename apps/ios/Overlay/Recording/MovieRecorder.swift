@preconcurrency import AVFoundation
import CoreVideo
import Metal
import Foundation

nonisolated struct MovieRecordingResult: Sendable {
    let url: URL
    let hasAudio: Bool
}

nonisolated struct MovieRecordingError: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

nonisolated private struct RecordedVideo: @unchecked Sendable {
    let buffer: CVPixelBuffer
    let texture: CVMetalTexture
    let timestamp: CMTime
}

nonisolated private struct RecordedAudio: @unchecked Sendable {
    let sample: CMSampleBuffer
}

// Admission is locked; every writer operation after initialization runs on the serial writer queue.
nonisolated final class MovieRecorder: @unchecked Sendable {
    let url: URL
    let dimensions: RecordingDimensions
    private let queue = DispatchQueue(label: "com.overlay.movie-writer", qos: .userInitiated)
    private let admission = NSLock()
    private var accepting = true
    private var finishRequested = false
    private var timeline = RecordingTimeline()
    private var nextSequence = 0
    private let videoSlots = DispatchSemaphore(value: 3)
    private let audioSlots = DispatchSemaphore(value: 16)
    private let pendingGPU = DispatchGroup()
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let pool: CVPixelBufferPool
    private let textureCache: CVMetalTextureCache
    private let pipeline: MTLComputePipelineState
    private let onStarted: @Sendable (TimeInterval) -> Void
    private let onFailure: @Sendable (String) -> Void
    // The following properties belong exclusively to the writer queue.
    private var firstTime: CMTime?
    private var lastVideoTime: CMTime?
    private var lastAudioTime: CMTime?
    private var earlyAudio: [RecordedAudio] = []
    private var completedVideo: [Int: RecordedVideo] = [:]
    private var skippedVideo: Set<Int> = []
    private var writeSequence = 0
    private var failureMessage: String?

    init(device: MTLDevice, dimensions: RecordingDimensions, url: URL, library: MTLLibrary? = nil,
         onStarted: @escaping @Sendable (TimeInterval) -> Void,
         onFailure: @escaping @Sendable (String) -> Void) throws {
        self.url = url
        self.dimensions = dimensions
        self.onStarted = onStarted
        self.onFailure = onFailure
        guard let library = library ?? device.makeDefaultLibrary(),
              let kernel = library.makeFunction(name: "recordingCopy") else {
            throw MovieRecordingError(message: "The recording shader could not be loaded.")
        }
        pipeline = try device.makeComputePipelineState(function: kernel)
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache else { throw MovieRecordingError(message: "Recording textures could not be created.") }
        textureCache = cache
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: dimensions.width,
            AVVideoHeightKey: dimensions.height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_IEC_sRGB,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 6_000_000,
                AVVideoExpectedSourceFrameRateKey: 30,
                AVVideoMaxKeyFrameIntervalKey: 30,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264MainAutoLevel,
                AVVideoAllowFrameReorderingKey: false,
            ],
        ])
        audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 128_000,
        ])
        videoInput.expectsMediaDataInRealTime = true
        audioInput.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: dimensions.width,
            kCVPixelBufferHeightKey as String: dimensions.height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ])
        guard writer.canAdd(videoInput), writer.canAdd(audioInput) else {
            throw MovieRecordingError(message: "This device could not configure video and audio encoding.")
        }
        writer.add(videoInput)
        writer.add(audioInput)
        guard writer.startWriting(), let pool = adaptor.pixelBufferPool else {
            throw writer.error ?? MovieRecordingError(message: "The video writer could not start.")
        }
        self.pool = pool
    }

    func encode(texture source: MTLTexture, command: MTLCommandBuffer, timestamp: TimeInterval) {
        admission.lock()
        defer { admission.unlock() }
        guard accepting, timestamp.isFinite,
              videoSlots.wait(timeout: .now()) == .success else { return }
        var scheduled = false
        defer { if !scheduled { videoSlots.signal() } }
        var candidate = timeline
        guard candidate.admit(timestamp) else { return }
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool,
            [kCVPixelBufferPoolAllocationThresholdKey as String: 6] as CFDictionary, &buffer)
        if status == kCVReturnWouldExceedAllocationThreshold { return }
        guard status == kCVReturnSuccess, let buffer else {
            report("A recording frame could not be allocated.")
            return
        }
        var wrapper: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, textureCache, buffer, nil,
                .bgra8Unorm, dimensions.width, dimensions.height, 0, &wrapper) == kCVReturnSuccess,
              let wrapper, let target = CVMetalTextureGetTexture(wrapper),
              let encoder = command.makeComputeCommandEncoder() else {
            report("The recording frame could not be rendered.")
            return
        }
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(target, index: 1)
        let linear: [MTLPixelFormat] = [.rgba16Float, .rgba32Float, .bgra8Unorm_srgb, .rgba8Unorm_srgb]
        var convertToSRGB: UInt32 = linear.contains(source.pixelFormat) ? 1 : 0
        encoder.setBytes(&convertToSRGB, length: MemoryLayout<UInt32>.stride, index: 0)
        let w = pipeline.threadExecutionWidth
        encoder.dispatchThreads(MTLSize(width: dimensions.width, height: dimensions.height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: w, height: min(8, pipeline.maxTotalThreadsPerThreadgroup / w), depth: 1))
        encoder.endEncoding()
        timeline = candidate
        let sequence = nextSequence
        nextSequence += 1
        let video = RecordedVideo(buffer: buffer, texture: wrapper,
                                  timestamp: CMTime(seconds: timestamp, preferredTimescale: 1_000_000_000))
        pendingGPU.enter()
        command.addCompletedHandler { [self, video] completed in
            let succeeded = completed.status == .completed
            queue.async { [self, video] in
                if succeeded { completedVideo[sequence] = video }
                else { skippedVideo.insert(sequence); fail("The GPU could not produce a recording frame.") }
                drainVideo()
            }
        }
        scheduled = true
    }

    func appendAudio(_ sample: CMSampleBuffer) {
        admission.lock()
        defer { admission.unlock() }
        guard accepting, audioSlots.wait(timeout: .now()) == .success else { return }
        let audio = RecordedAudio(sample: sample)
        queue.async { [self, audio] in
            defer { audioSlots.signal() }
            guard failureMessage == nil else { return }
            if firstTime == nil {
                earlyAudio.append(audio)
                if earlyAudio.count > 32 { earlyAudio.removeFirst() }
            } else { writeAudio(audio) }
        }
    }

    func checkStartup() {
        queue.async { [self] in
            if firstTime == nil { fail("The camera did not provide a recording frame. Please try again.") }
            else if lastAudioTime == nil { fail("The microphone did not provide audio. Please try recording again.") }
        }
    }

    func stopAccepting() {
        admission.lock()
        accepting = false
        admission.unlock()
    }

    func finish() async throws -> MovieRecordingResult {
        stopAccepting()
        return try await withCheckedThrowingContinuation { continuation in
            admission.lock()
            let alreadyFinishing = finishRequested
            finishRequested = true
            admission.unlock()
            guard !alreadyFinishing else {
                continuation.resume(throwing: MovieRecordingError(message: "The recording is already finishing."))
                return
            }
            // Group entries leave only after their GPU completion has been processed by the writer queue.
            pendingGPU.notify(queue: queue) { [self] in
                guard let lastVideoTime, writer.status == .writing else {
                    let message = failureMessage ?? writer.error?.localizedDescription ?? "No video frames were recorded. Please try again."
                    writer.cancelWriting()
                    continuation.resume(throwing: MovieRecordingError(message: message))
                    return
                }
                earlyAudio.removeAll()
                writer.endSession(atSourceTime: CMTimeAdd(lastVideoTime, CMTime(value: 1, timescale: 30)))
                videoInput.markAsFinished()
                audioInput.markAsFinished()
                let hasAudio = lastAudioTime != nil
                writer.finishWriting { [self] in
                    if writer.status == .completed {
                        continuation.resume(returning: MovieRecordingResult(url: url, hasAudio: hasAudio))
                    } else {
                        continuation.resume(throwing: writer.error ?? MovieRecordingError(message: "The video could not be finalized."))
                    }
                }
            }
        }
    }

    private func drainVideo() {
        while let video = completedVideo.removeValue(forKey: writeSequence) {
            writeVideo(video)
            writeSequence += 1
            videoSlots.signal()
            pendingGPU.leave()
        }
        if skippedVideo.remove(writeSequence) != nil {
            writeSequence += 1
            videoSlots.signal()
            pendingGPU.leave()
            drainVideo()
        }
    }

    private func writeVideo(_ video: RecordedVideo) {
        guard writer.status == .writing, videoInput.isReadyForMoreMediaData else {
            if writer.status == .failed { fail(writer.error?.localizedDescription ?? "Video encoding failed.") }
            return
        }
        if firstTime == nil {
            firstTime = video.timestamp
            writer.startSession(atSourceTime: video.timestamp)
        }
        guard adaptor.append(video.buffer, withPresentationTime: video.timestamp) else {
            fail(writer.error?.localizedDescription ?? "A video frame could not be encoded.")
            return
        }
        let isFirst = lastVideoTime == nil
        lastVideoTime = video.timestamp
        if isFirst {
            onStarted(video.timestamp.seconds)
            for audio in earlyAudio { writeAudio(audio) }
            earlyAudio.removeAll()
        }
    }

    private func writeAudio(_ audio: RecordedAudio) {
        let pts = CMSampleBufferGetPresentationTimeStamp(audio.sample)
        guard let firstTime, pts.isNumeric, pts >= firstTime,
              lastAudioTime == nil || pts > lastAudioTime! else { return }
        // ARKit supplies camera and microphone capture timestamps in the host-clock domain.
        guard let lastVideoTime, abs(pts.seconds - lastVideoTime.seconds) < 2 else {
            fail("The microphone and camera timestamps could not be synchronized.")
            return
        }
        guard writer.status == .writing, audioInput.isReadyForMoreMediaData else {
            if writer.status == .failed { fail(writer.error?.localizedDescription ?? "Audio encoding failed.") }
            return
        }
        guard audioInput.append(audio.sample) else {
            fail(writer.error?.localizedDescription ?? "Microphone audio could not be encoded.")
            return
        }
        lastAudioTime = pts
    }

    private func report(_ message: String) { queue.async { [self] in fail(message) } }
    private func fail(_ message: String) {
        guard failureMessage == nil else { return }
        failureMessage = message
        onFailure(message)
    }
}
