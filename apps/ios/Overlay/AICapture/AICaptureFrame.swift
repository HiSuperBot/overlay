import Foundation
import CoreVideo

// Retain the sensor buffers, not ARFrame or mutable face anchors, across the bounded writer queue.
nonisolated struct AICaptureFrame: @unchecked Sendable {
    let color: CVPixelBuffer
    let timestamp: Double
    let rgbIntrinsics: [Float]
    let depth: AIDepthSample?
}

nonisolated struct AIDepthSample: @unchecked Sendable {
    let buffer: CVPixelBuffer
    let timestamp: Double
    let filtered: Bool
    let quality: Int
    let accuracy: Int
    let calibration: AIDepthCalibration?

    func packedData() throws -> (Data, AIDepthFormat) {
        guard let format = AIDepthFormat(pixelFormat: CVPixelBufferGetPixelFormatType(buffer)),
              !CVPixelBufferIsPlanar(buffer), CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else {
            throw AICaptureError(message: "The depth pixel format could not be recorded.")
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let rowBytes = width * format.bytesPerPixel
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        guard width > 0, height > 0, stride >= rowBytes, let base = CVPixelBufferGetBaseAddress(buffer) else {
            throw AICaptureError(message: "The depth buffer could not be read.")
        }
        // All supported iPhone and macOS architectures are little-endian. Copy bits, including NaNs.
        var data = Data(capacity: rowBytes * height)
        for row in 0..<height { data.append(base.advanced(by: row * stride).assumingMemoryBound(to: UInt8.self), count: rowBytes) }
        return (data, format)
    }
}
