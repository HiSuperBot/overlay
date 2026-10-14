@preconcurrency import AVFoundation
import Foundation

nonisolated enum RecordingRecovery {
    static func pendingVideos(in folder: URL) async -> [URL] {
        let manifest = folder.appendingPathComponent("pending.json")
        let names = (try? JSONDecoder().decode([String].self, from: Data(contentsOf: manifest))) ?? []
        var pending = names.filter { $0 == ($0 as NSString).lastPathComponent && $0.hasSuffix(".mp4") }
            .map { folder.appendingPathComponent($0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        for file in files where file.pathExtension == "mp4" && !pending.contains(file) {
            guard !Task.isCancelled else { break }
            if !file.lastPathComponent.hasPrefix("writing-") { pending.append(file); continue }
            // Termination can occur after writer completion but before the rename or manifest update.
            // Inspect abandoned staging files before deleting anything that may be a completed clip.
            let asset = AVURLAsset(url: file)
            let playable = try? await asset.load(.isPlayable)
            guard !Task.isCancelled else { break }
            if playable == true, let duration = try? await asset.load(.duration), duration.isNumeric, duration.seconds > 0 {
                pending.append(file)
            } else if playable == false || (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) == 0 {
                try? FileManager.default.removeItem(at: file)
            }
        }
        return pending
    }
}
