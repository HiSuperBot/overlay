@preconcurrency import AVFoundation
@preconcurrency import Photos
@preconcurrency import Metal
import Observation
import UIKit

@MainActor
@Observable
final class RecordingController {
    private(set) var state: RecordingState = .idle
    private(set) var elapsedSeconds = 0
    private(set) var notice: String?
    private(set) var needsSettings = false
    private(set) var pendingVideos: [URL] = []
    private(set) var lockedAspectRatio: CGFloat?
    private(set) var recoveryReady = false

    @ObservationIgnored let frameSink = RecordingFrameSink()
    @ObservationIgnored private let tracking: FaceTrackingController
    @ObservationIgnored private var device: MTLDevice?
    @ObservationIgnored private var viewport: CGSize = .zero
    @ObservationIgnored private var movie: MovieRecorder?
    @ObservationIgnored private var requestID = UUID()
    @ObservationIgnored private var clockTask: Task<Void, Never>?
    @ObservationIgnored private var startupTask: Task<Void, Never>?
    @ObservationIgnored private var startedAt: TimeInterval?
    @ObservationIgnored private var interruptionObserver: RecordingInterruptionObserver?
    @ObservationIgnored private var didRestoreFiles = false
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored private var previousAudio: (AVAudioSession.Category, AVAudioSession.Mode, AVAudioSession.CategoryOptions)?

    var canStart: Bool {
        state == .idle && recoveryReady && cameraReady
    }
    private var cameraReady: Bool {
        tracking.isSessionRunning && !tracking.state.blocksPreview
            && (tracking.previewMode != .avatar || (!tracking.avatarLoading && tracking.fitReady && tracking.avatarError == nil))
    }
    var durationLabel: String { String(format: "%02d:%02d", elapsedSeconds / 60, elapsedSeconds % 60) }
    var shareURL: URL? { pendingVideos.last }

    init(tracking: FaceTrackingController) {
        self.tracking = tracking
        tracking.audioConsumer = { [frameSink] sample in frameSink.appendAudio(sample) }
        tracking.recordingInterrupted = { [weak self] reason in self?.stop(reason: reason) }
        interruptionObserver = RecordingInterruptionObserver { [weak self] reason in
            Task { @MainActor [weak self] in self?.stop(reason: reason) }
        }
    }

    func prepareRecovery() async {
        guard !didRestoreFiles else { return }
        didRestoreFiles = true
        // SwiftUI may construct unused State initial values. Only the retained controller touches files.
        if let folder = try? recordingFolder() { pendingVideos = await RecordingRecovery.pendingVideos(in: folder) }
        guard !Task.isCancelled else { didRestoreFiles = false; return }
        recoveryReady = true
        if !pendingVideos.isEmpty { notice = "A video is kept on this iPhone. Retry saving or share it." }
    }

    func updateViewport(_ size: CGSize, device: MTLDevice?) {
        viewport = size
        self.device = device
    }

    func start() async {
        guard canStart else { return }
        state = .preparing
        notice = nil
        needsSettings = false
        elapsedSeconds = 0
        let id = UUID()
        requestID = id
        var preparedMovie: MovieRecorder?
        do {
            guard await microphonePermission() else {
                throw MovieRecordingError(message: "Microphone access is required to record sound. Allow it in Settings.")
            }
            guard requestID == id else { return }
            guard await photoPermission() else {
                throw MovieRecordingError(message: "Photo access is required to save videos. Allow adding photos in Settings.")
            }
            guard requestID == id, UIApplication.shared.applicationState == .active else {
                if requestID == id { state = .idle }
                return
            }
            // Permission dialogs may temporarily pause the existing camera session.
            if !tracking.isSessionRunning { await tracking.start() }
            // A resumed session must deliver a fresh frame before its fit status can be trusted.
            for _ in 0..<60 {
                guard requestID == id else { return }
                guard UIApplication.shared.applicationState == .active else {
                    throw MovieRecordingError(message: "Recording was canceled when the app left the foreground.")
                }
                if tracking.latestFrame != nil && (tracking.previewMode != .avatar || tracking.fitReady) { break }
                try await Task.sleep(for: .milliseconds(30))
            }
            guard requestID == id else { return }
            guard cameraReady, tracking.latestFrame != nil,
                  let device, let dimensions = RecordingDimensions(width: viewport.width, height: viewport.height) else {
                throw MovieRecordingError(message: "Wait for the camera and face fit to be ready, then try again.")
            }
            let folder = try recordingFolder()
            let url = folder.appendingPathComponent("writing-\(id.uuidString).mp4")
            lockedAspectRatio = viewport.width / viewport.height
            let onStarted: @Sendable (TimeInterval) -> Void = { [weak self] time in
                Task { @MainActor [weak self] in self?.didStart(id: id, timestamp: time) }
            }
            let onFailure: @Sendable (String) -> Void = { [weak self] message in
                Task { @MainActor [weak self] in
                    if self?.requestID == id { self?.stop(reason: message) }
                }
            }
            let recorder = try await Task.detached(priority: .userInitiated) {
                try MovieRecorder(device: device, dimensions: dimensions, url: url,
                                  onStarted: onStarted, onFailure: onFailure)
            }.value
            preparedMovie = recorder
            guard requestID == id, UIApplication.shared.applicationState == .active else {
                _ = try? await recorder.finish()
                try? FileManager.default.removeItem(at: url)
                if requestID == id { state = .idle; lockedAspectRatio = nil }
                return
            }
            guard cameraReady, tracking.latestFrame != nil else {
                throw MovieRecordingError(message: "The camera or face fit became unavailable. Please try again.")
            }
            let audio = AVAudioSession.sharedInstance()
            previousAudio = (audio.category, audio.mode, audio.categoryOptions)
            try audio.setCategory(.record, mode: .videoRecording)
            try audio.setActive(true)
            movie = recorder
            frameSink.activate(recorder)
            tracking.setRecordingCapture(true)
            startupTask = Task { [weak self, recorder] in
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                guard self?.requestID == id, self?.movie === recorder else { return }
                recorder.checkStartup()
            }
        } catch {
            if let preparedMovie {
                _ = try? await preparedMovie.finish()
                try? FileManager.default.removeItem(at: preparedMovie.url)
            }
            guard requestID == id else { return }
            restoreAudioSession()
            lockedAspectRatio = nil
            state = .idle
            notice = error.localizedDescription
            needsSettings = AVAudioApplication.shared.recordPermission == .denied
                || PHPhotoLibrary.authorizationStatus(for: .addOnly) == .denied
                || PHPhotoLibrary.authorizationStatus(for: .addOnly) == .restricted
        }
    }

    func stop(reason: String? = nil) {
        guard state == .preparing || state == .recording else { return }
        startupTask?.cancel()
        clockTask?.cancel()
        guard let recorder = movie else {
            requestID = UUID()
            state = .idle
            lockedAspectRatio = nil
            notice = reason
            return
        }
        recorder.stopAccepting()
        frameSink.activate(nil)
        movie = nil
        state = .finishing
        beginBackgroundTask()
        tracking.setRecordingCapture(false)
        restoreAudioSession()
        Task { [self, recorder] in
            do {
                let result = try await recorder.finish()
                let destination = result.url.deletingLastPathComponent().appendingPathComponent("\(UUID().uuidString).mp4")
                let keptURL: URL
                do { try FileManager.default.moveItem(at: result.url, to: destination); keptURL = destination }
                catch { keptURL = result.url }
                pendingVideos.append(keptURL)
                persistPendingVideos()
                lockedAspectRatio = nil
                let detail = result.hasAudio ? reason : "No microphone audio was received; this video has no sound."
                await savePendingVideos(detail: detail)
            } catch {
                try? FileManager.default.removeItem(at: recorder.url)
                lockedAspectRatio = nil
                state = .idle
                notice = error.localizedDescription
            }
            endBackgroundTask()
        }
    }

    func applicationDidLeaveForeground(background: Bool) {
        // An inactive permission dialog is allowed to complete preparation; backgrounding cancels it.
        if movie != nil || background { stop(reason: "Recording stopped when the app left the foreground.") }
    }

    func retrySave() async {
        guard state == .idle, !pendingVideos.isEmpty else { return }
        state = .saving
        needsSettings = false
        guard await photoPermission() else {
            state = .idle
            notice = "Allow adding photos in Settings to save the video. The video is kept on this iPhone."
            needsSettings = true
            return
        }
        beginBackgroundTask()
        await savePendingVideos()
        endBackgroundTask()
    }

    func dismissNotice() { notice = nil; needsSettings = false }

    private func didStart(id: UUID, timestamp: TimeInterval) {
        guard requestID == id, state == .preparing, movie != nil else { return }
        state = .recording
        startedAt = timestamp
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.state == .recording, let startedAt = self.startedAt else { return }
                self.elapsedSeconds = max(0, Int(ProcessInfo.processInfo.systemUptime - startedAt))
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    private func microphonePermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .undetermined: return await AVAudioApplication.requestRecordPermission()
        default: return false
        }
    }

    private func photoPermission() async -> Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if status == .notDetermined { return await PHPhotoLibrary.requestAuthorization(for: .addOnly) == .authorized }
        return status == .authorized
    }

    private func savePendingVideos(detail: String? = nil) async {
        state = .saving
        do {
            for url in pendingVideos {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: url, options: nil)
                }
                pendingVideos.removeAll { $0 == url }
                persistPendingVideos()
                // A local copy is removed only after Photos confirms its transaction.
                try? FileManager.default.removeItem(at: url)
            }
            notice = ["Saved to Photos", detail].compactMap { $0 }.joined(separator: ". ")
            needsSettings = false
        } catch {
            notice = "Could not save to Photos. The video is kept on this iPhone. Retry saving or share it."
            needsSettings = PHPhotoLibrary.authorizationStatus(for: .addOnly) != .authorized
        }
        state = .idle
    }

    private func restoreAudioSession() {
        guard let previousAudio else { return }
        self.previousAudio = nil
        let audio = AVAudioSession.sharedInstance()
        try? audio.setActive(false, options: .notifyOthersOnDeactivation)
        try? audio.setCategory(previousAudio.0, mode: previousAudio.1, options: previousAudio.2)
    }

    private func recordingFolder() throws -> URL {
        let folder = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                appropriateFor: nil, create: true).appendingPathComponent("Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var excluded = folder
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
        return folder
    }

    private func persistPendingVideos() {
        guard let folder = try? recordingFolder(), let data = try? JSONEncoder().encode(pendingVideos.map(\.lastPathComponent)) else { return }
        try? data.write(to: folder.appendingPathComponent("pending.json"), options: .atomic)
    }

    private func beginBackgroundTask() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Finish recording") { [weak self] in
            Task { @MainActor in self?.endBackgroundTask() }
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}

nonisolated private final class RecordingInterruptionObserver: @unchecked Sendable {
    private let tokens: [NSObjectProtocol]

    init(onInterruption: @escaping @Sendable (String) -> Void) {
        let center = NotificationCenter.default
        tokens = [
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { note in
                if (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue {
                    onInterruption("Recording stopped because the microphone was interrupted.")
                }
            },
            center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { note in
                if (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue {
                    onInterruption("Recording stopped because the microphone disconnected.")
                }
            },
        ]
    }

    deinit { for token in tokens { NotificationCenter.default.removeObserver(token) } }
}
