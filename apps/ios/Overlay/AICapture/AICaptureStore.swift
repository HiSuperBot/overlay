@preconcurrency import AVFoundation
@preconcurrency import ZIPFoundation
import Foundation

actor AICaptureStore {
    let root: URL
    private let exportsRoot: URL
    private let capacityProvider: @Sendable (URL) throws -> Int64
    private var activeIDs: Set<UUID> = []
    private var exportingIDs: Set<UUID> = []
    private var prepared = false
    static let startReserve: Int64 = 512 * 1024 * 1024
    static let stopReserve: Int64 = 256 * 1024 * 1024

    init(root: URL? = nil, exportsRoot: URL? = nil,
         capacityProvider: @escaping @Sendable (URL) throws -> Int64 = { try AICaptureStore.availableCapacity($0) }) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AICaptures", isDirectory: true)
        self.exportsRoot = exportsRoot ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AIExports", isDirectory: true)
        self.capacityProvider = capacityProvider
    }

    func prepare() throws {
        guard !prepared else { return }
        try ensureRoot()
        try? FileManager.default.removeItem(at: exportsRoot)
        prepared = true
    }

    func freeBytes() throws -> Int64 { try ensureRoot(); return try capacityProvider(root) }

    func reserve(_ manifest: AICaptureManifest) throws -> URL {
        guard try freeBytes() >= Self.startReserve else { throw AICaptureError(message: "AI capture needs at least 512 MB of available storage.") }
        let folder = root.appendingPathComponent(manifest.id.uuidString, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: folder.path) else { throw AICaptureError(message: "The AI capture already exists.") }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try manifest.write(to: folder)
        activeIDs.insert(manifest.id)
        return folder
    }

    func finalize(_ manifest: AICaptureManifest) async throws -> AICaptureItem {
        let folder = root.appendingPathComponent(manifest.id.uuidString, isDirectory: true)
        defer { activeIDs.remove(manifest.id) }
        return try await inspect(folder: folder, forceValidation: true)
    }

    func abandon(id: UUID, reason: String) async {
        activeIDs.remove(id)
        let folder = root.appendingPathComponent(id.uuidString, isDirectory: true)
        guard var manifest = try? readManifest(folder) else { return }
        manifest.stopReason = reason
        manifest.status = .recording
        try? manifest.write(to: folder)
        _ = try? await inspect(folder: folder, forceValidation: true)
    }

    func list() async throws -> [AICaptureItem] {
        try ensureRoot()
        let folders = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])
        var items: [AICaptureItem] = []
        for folder in folders where UUID(uuidString: folder.lastPathComponent) != nil {
            guard !activeIDs.contains(UUID(uuidString: folder.lastPathComponent)!) else { continue }
            if let item = try? await inspect(folder: folder, forceValidation: false) { items.append(item) }
        }
        return items.sorted { $0.manifest.createdAt > $1.manifest.createdAt }
    }

    func firstDepth(in item: AICaptureItem) throws -> (Data, AIDepthRecord)? {
        try verify(item)
        guard item.manifest.depthFrameCount > 0 else { return nil }
        let summary = try AICaptureJournal.scan(folder: item.folder, repair: false)
        guard let depth = summary.firstDepth else { return nil }
        let file = try FileHandle(forReadingFrom: item.folder.appendingPathComponent("depth.bin"))
        defer { try? file.close() }
        try file.seek(toOffset: depth.byteOffset)
        guard let data = try file.read(upToCount: depth.byteLength), data.count == depth.byteLength else {
            throw AICaptureError(message: "The depth sample is incomplete.")
        }
        return (data, depth)
    }

    func delete(_ item: AICaptureItem) throws {
        try verify(item)
        guard !activeIDs.contains(item.id), !exportingIDs.contains(item.id) else {
            throw AICaptureError(message: "Wait for this capture to finish exporting before deleting it.")
        }
        try FileManager.default.removeItem(at: item.folder)
    }

    func export(_ item: AICaptureItem) async throws -> URL {
        try verify(item)
        guard !activeIDs.contains(item.id), !exportingIDs.contains(item.id) else { throw AICaptureError(message: "This capture is busy.") }
        guard try freeBytes() >= item.byteCount + Self.stopReserve else { throw AICaptureError(message: "Free more storage to create the export archive.") }
        exportingIDs.insert(item.id)
        defer { exportingIDs.remove(item.id) }
        let container = exportsRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let destination = container.appendingPathComponent("AI-\(item.id.uuidString).zip")
        let progress = Progress(totalUnitCount: 4)
        do {
            let work = Task.detached(priority: .userInitiated) {
                let archive = try Archive(url: destination, accessMode: .create)
                for name in ["video.mp4", "depth.bin", "frames.jsonl", "manifest.json"] {
                    try Task.checkCancellation()
                    let source = item.folder.appendingPathComponent(name)
                    if FileManager.default.fileExists(atPath: source.path) {
                        try archive.addEntry(with: "\(item.id.uuidString)/\(name)", fileURL: source,
                                             compressionMethod: name == "video.mp4" ? .none : .deflate,
                                             progress: progress)
                    }
                }
            }
            try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { progress.cancel(); work.cancel() })
            return destination
        } catch {
            try? FileManager.default.removeItem(at: container)
            throw error
        }
    }

    func removeExport(_ url: URL) {
        let container = url.deletingLastPathComponent()
        guard container.deletingLastPathComponent().standardizedFileURL == exportsRoot.standardizedFileURL else { return }
        try? FileManager.default.removeItem(at: container)
    }

    private func inspect(folder: URL, forceValidation: Bool) async throws -> AICaptureItem {
        var manifest = try readManifest(folder)
        guard manifest.schemaVersion == 1, folder.lastPathComponent == manifest.id.uuidString,
              manifest.videoWidth > 0, manifest.videoHeight > 0,
              manifest.videoPresentationTransform.count == 6, manifest.videoPresentationTransform.allSatisfy(\.isFinite) else {
            throw AICaptureError(message: "Unsupported AI capture format.")
        }
        let video = AVURLAsset(url: folder.appendingPathComponent("video.mp4"))
        let playable = (try? await video.load(.isPlayable)) == true
        let duration = (try? await video.load(.duration).seconds) ?? 0
        let tracks = (try? await video.loadTracks(withMediaType: .video)) ?? []
        let videoEnd: Double
        if let track = tracks.first, let range = try? await track.load(.timeRange) { videoEnd = CMTimeRangeGetEnd(range).seconds }
        else { videoEnd = 0 }
        guard !activeIDs.contains(manifest.id) || forceValidation else {
            throw AICaptureError(message: "The AI capture is still recording.")
        }
        if forceValidation || manifest.status == .recording {
            let summary = try AICaptureJournal.scan(folder: folder, repair: true)
            let previouslyRecording = manifest.status == .recording
            manifest.videoFrameCount = summary.frameCount
            manifest.depthFrameCount = summary.depthCount
            manifest.missingDepthFrameCount = summary.frameCount - summary.depthCount
            manifest.startTimestamp = summary.firstTimestamp
            manifest.duration = duration.isFinite ? max(0, duration) : 0
            let indexedEnd = (summary.lastTimestamp ?? 0) - (summary.firstTimestamp ?? 0) + 1.0 / 30
            let videoCoversIndex = videoEnd.isFinite && videoEnd + 0.005 >= indexedEnd
            if playable, videoCoversIndex, summary.frameCount > 0, summary.depthCount > 0, !summary.hadInvalidTail {
                if previouslyRecording {
                    manifest.status = .interrupted
                    manifest.stopReason = manifest.stopReason ?? "Recovered after an interrupted recording."
                    let audio = (try? await video.loadTracks(withMediaType: .audio)) ?? []
                    manifest.hasAudio = !audio.isEmpty
                    if !manifest.hasAudio { manifest.status = .incomplete }
                }
            } else {
                manifest.status = .incomplete
                manifest.stopReason = manifest.stopReason ?? "Some capture files are missing or incomplete."
            }
            try manifest.write(to: folder)
        } else if !playable, manifest.status == .complete {
            manifest.status = .incomplete
            manifest.stopReason = "The recorded video is unavailable."
            try manifest.write(to: folder)
        }
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])
        let bytes = files.reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        return AICaptureItem(manifest: manifest, folder: folder, byteCount: bytes, videoPlayable: playable)
    }

    private func readManifest(_ folder: URL) throws -> AICaptureManifest {
        try AICaptureManifest.decoder().decode(AICaptureManifest.self, from: Data(contentsOf: folder.appendingPathComponent("manifest.json")))
    }
    private func verify(_ item: AICaptureItem) throws {
        guard item.folder.standardizedFileURL == root.appendingPathComponent(item.id.uuidString, isDirectory: true).standardizedFileURL else {
            throw AICaptureError(message: "The AI capture is outside application storage.")
        }
    }
    private func ensureRoot() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var folder = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
    }
    nonisolated static func availableCapacity(_ url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let bytes = values.volumeAvailableCapacityForImportantUsage { return bytes }
        if let bytes = values.volumeAvailableCapacity { return Int64(bytes) }
        throw AICaptureError(message: "Available storage could not be checked.")
    }
}
