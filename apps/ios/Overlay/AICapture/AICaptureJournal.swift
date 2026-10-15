import Foundation
import CoreVideo

nonisolated struct AIJournalSummary: Sendable {
    var frameCount = 0
    var depthCount = 0
    var firstTimestamp: Double?
    var lastTimestamp: Double?
    var indexBytes: UInt64 = 0
    var depthBytes: UInt64 = 0
    var firstDepth: AIDepthRecord?
    var hadInvalidTail = false
}

// The recording writer owns this journal on its serial queue. One JSON line commits one sensor pair.
nonisolated final class AICaptureJournal {
    private let depthFile: FileHandle
    private let indexFile: FileHandle
    private let encoder = JSONEncoder()
    private(set) var summary = AIJournalSummary()

    init(folder: URL) throws {
        let depthURL = folder.appendingPathComponent("depth.bin")
        let indexURL = folder.appendingPathComponent("frames.jsonl")
        guard FileManager.default.createFile(atPath: depthURL.path, contents: nil),
              FileManager.default.createFile(atPath: indexURL.path, contents: nil) else {
            throw AICaptureError(message: "The AI capture index could not be created.")
        }
        depthFile = try FileHandle(forWritingTo: depthURL)
        indexFile = try FileHandle(forWritingTo: indexURL)
        encoder.outputFormatting = .sortedKeys
    }

    func append(_ frame: AICaptureFrame, startTimestamp: Double, packedDepth: (Data, AIDepthFormat)?) throws {
        var record: AIDepthRecord?
        if let depth = frame.depth, let (bytes, format) = packedDepth {
            record = AIDepthRecord(timestamp: depth.timestamp, relativeTimestamp: depth.timestamp - startTimestamp,
                byteOffset: summary.depthBytes, byteLength: bytes.count,
                width: CVPixelBufferGetWidth(depth.buffer), height: CVPixelBufferGetHeight(depth.buffer),
                pixelFormat: CVPixelBufferGetPixelFormatType(depth.buffer), format: format, unit: format.unit,
                filtered: depth.filtered, quality: depth.quality, accuracy: depth.accuracy,
                calibration: depth.calibration, calibrationMissing: depth.calibration == nil)
        }
        let entry = AIFrameRecord(index: summary.frameCount, timestamp: frame.timestamp,
                                  videoTime: frame.timestamp - startTimestamp, rgbIntrinsics: frame.rgbIntrinsics,
                                  depth: record, depthMissing: record == nil)
        var line = try encoder.encode(entry)
        line.append(0x0A)
        do {
            if let (bytes, _) = packedDepth { try depthFile.write(contentsOf: bytes) }
            try indexFile.write(contentsOf: line)
        } catch {
            // Keep only committed blocks if a write stops between the binary block and its index line.
            try? depthFile.truncate(atOffset: summary.depthBytes)
            try? indexFile.truncate(atOffset: summary.indexBytes)
            throw error
        }
        summary.frameCount += 1
        summary.indexBytes += UInt64(line.count)
        summary.firstTimestamp = summary.firstTimestamp ?? frame.timestamp
        summary.lastTimestamp = frame.timestamp
        if let record {
            summary.depthBytes += UInt64(record.byteLength)
            summary.depthCount += 1
            summary.firstDepth = summary.firstDepth ?? record
        }
    }

    func close() throws {
        try depthFile.synchronize()
        try indexFile.synchronize()
        try depthFile.close()
        try indexFile.close()
    }

    static func scan(folder: URL, repair: Bool) throws -> AIJournalSummary {
        let indexURL = folder.appendingPathComponent("frames.jsonl")
        let depthURL = folder.appendingPathComponent("depth.bin")
        guard FileManager.default.fileExists(atPath: indexURL.path) else { return AIJournalSummary() }
        let depthSize = (try? depthURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(UInt64.init) ?? 0
        let input = try FileHandle(forReadingFrom: indexURL)
        defer { try? input.close() }
        var summary = AIJournalSummary()
        var pending = Data()
        var invalid = false
        while !invalid, let chunk = try input.read(upToCount: 64 * 1024), !chunk.isEmpty {
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = Data(pending[..<newline])
                guard let frame = try? JSONDecoder().decode(AIFrameRecord.self, from: line), valid(frame, summary: summary, depthSize: depthSize) else {
                    invalid = true
                    break
                }
                summary.frameCount += 1
                summary.firstTimestamp = summary.firstTimestamp ?? frame.timestamp
                summary.lastTimestamp = frame.timestamp
                summary.indexBytes += UInt64(line.count + 1)
                if let depth = frame.depth {
                    summary.depthCount += 1
                    summary.depthBytes += UInt64(depth.byteLength)
                    summary.firstDepth = summary.firstDepth ?? depth
                }
                pending.removeSubrange(...newline)
            }
            if pending.count > 2 * 1024 * 1024 { invalid = true }
        }
        summary.hadInvalidTail = invalid || !pending.isEmpty || summary.depthBytes != depthSize
        if repair {
            let index = try FileHandle(forWritingTo: indexURL)
            defer { try? index.close() }
            try index.truncate(atOffset: summary.indexBytes)
            if FileManager.default.fileExists(atPath: depthURL.path) {
                let depth = try FileHandle(forWritingTo: depthURL)
                defer { try? depth.close() }
                try depth.truncate(atOffset: summary.depthBytes)
            }
        }
        return summary
    }

    private static func valid(_ frame: AIFrameRecord, summary: AIJournalSummary, depthSize: UInt64) -> Bool {
        guard frame.index == summary.frameCount, frame.timestamp.isFinite, frame.videoTime.isFinite,
              frame.videoTime >= 0, frame.rgbIntrinsics.count == 9, frame.rgbIntrinsics.allSatisfy(\.isFinite),
              frame.depthMissing == (frame.depth == nil), summary.lastTimestamp == nil || frame.timestamp > summary.lastTimestamp! else { return false }
        let start = summary.firstTimestamp ?? frame.timestamp
        guard abs(frame.videoTime - (frame.timestamp - start)) < 0.00001 else { return false }
        guard let depth = frame.depth else { return true }
        let (pixels, overflow1) = depth.width.multipliedReportingOverflow(by: depth.height)
        let (bytes, overflow2) = pixels.multipliedReportingOverflow(by: depth.format.bytesPerPixel)
        guard !overflow1, !overflow2, depth.width > 0, depth.height > 0, bytes == depth.byteLength,
              depth.byteLength > 0, depth.byteOffset == summary.depthBytes, depth.byteOffset <= depthSize,
              UInt64(depth.byteLength) <= depthSize - depth.byteOffset,
              AIDepthFormat(pixelFormat: depth.pixelFormat) == depth.format, depth.unit == depth.format.unit,
              depth.timestamp.isFinite, depth.relativeTimestamp.isFinite,
              abs(depth.relativeTimestamp - (depth.timestamp - start)) < 0.00001 else { return false }
        return true
    }
}
