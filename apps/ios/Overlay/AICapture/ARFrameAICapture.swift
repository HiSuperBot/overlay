@preconcurrency import ARKit
import AVFoundation
import simd

@MainActor
enum ARFrameAICapture {
    static func snapshot(_ frame: ARFrame) -> AICaptureFrame {
        var depth: AIDepthSample?
        if let source = frame.capturedDepthData, frame.capturedDepthDataTimestamp.isFinite,
           frame.capturedDepthDataTimestamp > 0 {
            depth = AIDepthSample(buffer: source.depthDataMap, timestamp: frame.capturedDepthDataTimestamp,
                                  filtered: source.isDepthDataFiltered, quality: source.depthDataQuality.rawValue,
                                  accuracy: source.depthDataAccuracy.rawValue, calibration: calibration(source.cameraCalibrationData))
        }
        return AICaptureFrame(color: frame.capturedImage, timestamp: frame.timestamp,
                              rgbIntrinsics: rows(frame.camera.intrinsics), depth: depth)
    }

    static func presentationTransform(_ frame: ARFrame) -> CGAffineTransform {
        let image = frame.camera.imageResolution
        let output = CGSize(width: image.height, height: image.width)
        var normalized: CGAffineTransform
        if #available(iOS 27.0, *) { normalized = frame.displayTransform(viewRotationAngle: 90, viewportSize: output) }
        else { normalized = frame.displayTransform(for: .portrait, viewportSize: output) }
        // Use ARKit's orientation without the front-camera display reflection or any viewport crop.
        if normalized.a * normalized.d - normalized.b * normalized.c < 0 {
            normalized = normalized.concatenating(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 1, ty: 0))
        }
        return CGAffineTransform(a: normalized.a * output.width / image.width,
                                 b: normalized.b * output.height / image.width,
                                 c: normalized.c * output.width / image.height,
                                 d: normalized.d * output.height / image.height,
                                 tx: normalized.tx * output.width, ty: normalized.ty * output.height)
    }

    private static func rows(_ matrix: simd_float3x3) -> [Float] {
        (0..<3).flatMap { row in (0..<3).map { column in matrix[column][row] } }
    }
    private static func table(_ data: Data?) -> [Float]? {
        guard let data else { return nil }
        return data.withUnsafeBytes { bytes in
            stride(from: 0, to: bytes.count - bytes.count % 4, by: 4).map { bytes.loadUnaligned(fromByteOffset: $0, as: Float.self) }
        }
    }
    private static func calibration(_ source: AVCameraCalibrationData?) -> AIDepthCalibration? {
        guard let source else { return nil }
        return AIDepthCalibration(intrinsics: rows(source.intrinsicMatrix),
            referenceWidth: source.intrinsicMatrixReferenceDimensions.width,
            referenceHeight: source.intrinsicMatrixReferenceDimensions.height,
            extrinsics: (0..<3).flatMap { row in (0..<4).map { column in source.extrinsicMatrix[column][row] } },
            translationUnit: "millimeters", pixelSizeMillimeters: source.pixelSize,
            distortionCenter: [source.lensDistortionCenter.x, source.lensDistortionCenter.y],
            lensDistortion: table(source.lensDistortionLookupTable), inverseLensDistortion: table(source.inverseLensDistortionLookupTable))
    }
}
