@preconcurrency import AVFoundation
import CoreVideo
import Foundation

enum SyntheticCapture {
    static let intrinsics: [Float] = [100, 0, 80, 0, 100, 60, 0, 0, 1]

    static func color() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, 160, 120, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &buffer) == kCVReturnSuccess,
              let buffer else { throw AICaptureError(message: "Synthetic camera allocation failed.") }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let y = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
        let uv = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!.assumingMemoryBound(to: UInt8.self)
        for row in 0..<120 {
            for x in 0..<160 { y[row * CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) + x] = row >= 60 ? 128 : (x < 80 ? 76 : 29) }
        }
        for row in 0..<60 {
            for x in 0..<80 {
                let offset = row * CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) + x * 2
                uv[offset] = row >= 30 ? 128 : (x < 40 ? 85 : 255)
                uv[offset + 1] = row >= 30 ? 128 : (x < 40 ? 255 : 107)
            }
        }
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_601_4, .shouldPropagate)
        return buffer
    }

    static func depth(pixelFormat: OSType) throws -> (CVPixelBuffer, Data) {
        let format = AIDepthFormat(pixelFormat: pixelFormat)!
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, 3, 2, pixelFormat,
            [kCVPixelBufferBytesPerRowAlignmentKey as String: 64] as CFDictionary, &buffer) == kCVReturnSuccess,
              let buffer else { throw AICaptureError(message: "Synthetic depth allocation failed.") }
        let bits16: [UInt16] = [0x3400, 0x3800, 0x3C00, 0xFE13, 0x7C00, 0]
        let bits32: [UInt32] = [0x3E800000, 0x3F000000, 0x3F800000, 0xFFC01234, 0x7F800000, 0]
        let packed = format.bytesPerPixel == 2 ? bits16.withUnsafeBytes { Data($0) } : bits32.withUnsafeBytes { Data($0) }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = CVPixelBufferGetBaseAddress(buffer)!
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        memset(base, 0xA5, stride * 2)
        packed.withUnsafeBytes { bytes in
            for row in 0..<2 { memcpy(base.advanced(by: row * stride), bytes.baseAddress!.advanced(by: row * 3 * format.bytesPerPixel), 3 * format.bytesPerPixel) }
        }
        return (buffer, packed)
    }

    static func audio(time: Double) throws -> CMSampleBuffer {
        var description = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 4,
            mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &description, layoutSize: 0,
            layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format) == noErr else {
            throw AICaptureError(message: "Synthetic PCM format creation failed.")
        }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: 6400,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: 6400,
            flags: 0, blockBufferOut: &block) == kCMBlockBufferNoErr, let block else { throw AICaptureError(message: "Synthetic PCM allocation failed.") }
        let tone: [Float] = (0..<1600).map { 0.05 * sin(Float($0) * 2 * .pi * 440 / 48_000) }
        let copied = tone.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: 6400) }
        guard copied == noErr else { throw AICaptureError(message: "Synthetic PCM copying failed.") }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000),
            presentationTimeStamp: CMTime(seconds: time, preferredTimescale: 1_000_000_000), decodeTimeStamp: .invalid)
        var size = 4
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: block, dataReady: true,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: format, sampleCount: 1600,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
            sampleSizeArray: &size, sampleBufferOut: &sample) == noErr, let sample else { throw AICaptureError(message: "Synthetic PCM sample creation failed.") }
        return sample
    }
}
