import Foundation
import CoreGraphics

nonisolated enum AIDepthVisualization {
    static func image(data: Data, record: AIDepthRecord) -> CGImage? {
        guard data.count == record.byteLength else { return nil }
        let count = record.width * record.height
        var distances: [Float] = []
        distances.reserveCapacity(count)
        data.withUnsafeBytes { bytes in
            for index in 0..<count {
                let value: Float
                if record.format.bytesPerPixel == 2 {
                    value = Float(Float16(bitPattern: UInt16(littleEndian: bytes.loadUnaligned(fromByteOffset: index * 2, as: UInt16.self))))
                } else { value = Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self))) }
                let meters = record.unit == "inverseMeters" ? 1 / value : value
                distances.append(meters.isFinite && meters > 0 ? meters : .nan)
            }
        }
        let valid = distances.filter(\.isFinite)
        guard let near = valid.min(), let far = valid.max() else { return nil }
        let span = max(far - near, 0.0001)
        var rgba = [UInt8](repeating: 0, count: count * 4)
        for index in 0..<count where distances[index].isFinite {
            let t = max(0, min(1, (distances[index] - near) / span))
            rgba[index * 4] = UInt8((1 - t) * 255)
            rgba[index * 4 + 1] = UInt8((1 - abs(2 * t - 1)) * 255)
            rgba[index * 4 + 2] = UInt8(t * 255)
            rgba[index * 4 + 3] = 255
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: record.width, height: record.height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: record.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
