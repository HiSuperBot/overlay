import Foundation
import CoreVideo

nonisolated enum AICaptureStatus: String, Codable, Sendable {
    case recording, complete, interrupted, incomplete
    var title: String { rawValue.capitalized }
}

nonisolated enum AIDepthFormat: String, Codable, Sendable {
    case depthFloat16, depthFloat32, disparityFloat16, disparityFloat32

    init?(pixelFormat: OSType) {
        switch pixelFormat {
        case kCVPixelFormatType_DepthFloat16: self = .depthFloat16
        case kCVPixelFormatType_DepthFloat32: self = .depthFloat32
        case kCVPixelFormatType_DisparityFloat16: self = .disparityFloat16
        case kCVPixelFormatType_DisparityFloat32: self = .disparityFloat32
        default: return nil
        }
    }
    var bytesPerPixel: Int { self == .depthFloat16 || self == .disparityFloat16 ? 2 : 4 }
    var unit: String { self == .depthFloat16 || self == .depthFloat32 ? "meters" : "inverseMeters" }
}

nonisolated struct AIDepthCalibration: Codable, Sendable {
    let intrinsics: [Float]
    let referenceWidth: Double
    let referenceHeight: Double
    let extrinsics: [Float]
    let translationUnit: String
    let pixelSizeMillimeters: Float
    let distortionCenter: [Double]
    let lensDistortion: [Float]?
    let inverseLensDistortion: [Float]?
}

nonisolated struct AIDepthRecord: Codable, Sendable {
    let timestamp: Double
    let relativeTimestamp: Double
    let byteOffset: UInt64
    let byteLength: Int
    let width: Int
    let height: Int
    let pixelFormat: UInt32
    let format: AIDepthFormat
    let unit: String
    let filtered: Bool
    let quality: Int
    let accuracy: Int
    let calibration: AIDepthCalibration?
    let calibrationMissing: Bool
}

nonisolated struct AIFrameRecord: Codable, Sendable {
    let index: Int
    let timestamp: Double
    let videoTime: Double
    let rgbIntrinsics: [Float]
    let depth: AIDepthRecord?
    let depthMissing: Bool
}

nonisolated struct AICaptureManifest: Codable, Identifiable, Sendable {
    var schemaVersion = 1
    let id: UUID
    let createdAt: Date
    var status: AICaptureStatus = .recording
    let videoWidth: Int
    let videoHeight: Int
    let videoPixelFormat: UInt32
    let videoPresentationTransform: [Double]
    let previewEffect: String
    var targetFrameRate = 30
    var videoCodec = "h264"
    var audioCodec = "aac"
    var byteOrder = "littleEndian"
    var matrixOrder = "rowMajor"
    var timestampClock = "ARKitHostClock"
    var startTimestamp: Double?
    var duration: Double = 0
    var videoFrameCount = 0
    var depthFrameCount = 0
    var missingDepthFrameCount = 0
    var droppedFrameCount = 0
    var hasAudio = false
    var stopReason: String?

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return encoder
    }
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
    func write(to folder: URL) throws {
        try Self.encoder().encode(self).write(to: folder.appendingPathComponent("manifest.json"), options: .atomic)
    }
}

nonisolated struct AICaptureItem: Identifiable, Sendable {
    let manifest: AICaptureManifest
    let folder: URL
    let byteCount: Int64
    let videoPlayable: Bool
    var id: UUID { manifest.id }
    var videoURL: URL { folder.appendingPathComponent("video.mp4") }
}

nonisolated struct AICaptureError: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}
