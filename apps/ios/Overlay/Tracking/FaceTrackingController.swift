@preconcurrency import ARKit
import AVFoundation
import Observation

enum CameraState: Equatable {
    case starting
    case searching
    case tracking
    case paused
    case interrupted
    case unsupported(String)
    case denied
    case failed(String)

    var title: String {
        switch self {
        case .starting: "Starting camera"
        case .searching: "Looking for your face"
        case .tracking: "Face tracked"
        case .paused: "Camera paused"
        case .interrupted: "Camera interrupted"
        case .unsupported: "TrueDepth iPhone required"
        case .denied: "Camera access required"
        case .failed: "Camera unavailable"
        }
    }

    var detail: String? {
        switch self {
        case .unsupported(let message), .failed(let message): message
        case .denied: "Allow camera access in Settings to start your face preview."
        case .interrupted: "The preview will resume when the camera becomes available."
        default: nil
        }
    }

    var blocksPreview: Bool {
        switch self {
        case .unsupported, .denied, .failed, .interrupted: true
        default: false
        }
    }
}

@MainActor
@Observable
final class FaceTrackingController: NSObject, @preconcurrency ARSessionDelegate {
    private(set) var state: CameraState = .starting
    private(set) var isSessionRunning = false
    private(set) var targetFrameRate = 60
    private(set) var canRetry = false
    var previewMode: PreviewMode = .avatar {
        didSet { if oldValue != previewMode { updateCameraFormat() } }
    }
    private(set) var avatars: [AvatarDescriptor] = []
    private(set) var selectedAvatarID = "human-a"
    private(set) var avatarLoading = false
    private var avatarLoadError: String?
    private var avatarRenderingError: String?
    var avatarError: String? { avatarRenderingError ?? avatarLoadError }
    private(set) var fitReady = false
    private(set) var refitGeneration = 0
    private(set) var avatarRetryGeneration = 0

    @ObservationIgnored private(set) var latestFrame: ARFrame?
    @ObservationIgnored var frameConsumer: ((ARFrame?) -> Void)?
    @ObservationIgnored var captureFrameConsumer: ((ARFrame) -> Void)?
    @ObservationIgnored var audioConsumer: ((CMSampleBuffer) -> Void)?
    @ObservationIgnored var recordingInterrupted: ((String) -> Void)?
    @ObservationIgnored private var recordingCapture = false

    var selectedAvatar: AvatarDescriptor? { avatars.first { $0.id == selectedAvatarID } }

    func selectAvatar(_ id: String) {
        guard avatars.contains(where: { $0.id == id }) else { return }
        if avatarError != nil {
            avatarRetryGeneration += 1
            avatarRenderingError = nil
        }
        selectedAvatarID = id
        UserDefaults.standard.set(id, forKey: "selectedAvatarID")
        avatarLoadError = nil
    }

    func retryAvatar() {
        guard selectedAvatar != nil else { return }
        avatarRetryGeneration += 1
        avatarLoadError = nil
        avatarRenderingError = nil
    }

    func avatarRenderingFailed(_ message: String) {
        recordingInterrupted?(message)
        avatarRenderingError = message
        previewMode = .original
    }

    func refit() { refitGeneration += 1; fitReady = false }
    func setFitReady(_ ready: Bool) { if fitReady != ready { fitReady = ready } }
    func avatarLoadStarted() { avatarLoading = true; avatarLoadError = nil }
    func avatarLoadFinished(id: String, error: String? = nil) {
        guard id == selectedAvatarID else { return }
        avatarLoading = false
        avatarLoadError = error
    }

    @ObservationIgnored let session = ARSession()
    @ObservationIgnored private var wantsToRun = false
    @ObservationIgnored private var isStarting = false
    @ObservationIgnored private var isInterrupted = false
    @ObservationIgnored private var renderingFailure: String?

    override init() {
        super.init()
        do {
            avatars = try AvatarCatalog.load()
            let saved = UserDefaults.standard.string(forKey: "selectedAvatarID") ?? "human-a"
            selectedAvatarID = avatars.contains { $0.id == saved } ? saved : avatars[0].id
        } catch {
            avatarLoadError = "The avatar catalog could not be read. Original and Mesh are still available."
        }
        session.delegate = self
        session.delegateQueue = .main
    }

    func start() async {
        wantsToRun = true
        guard !isSessionRunning, !isStarting, !isInterrupted else { return }

        if let renderingFailure {
            state = .failed(renderingFailure)
            return
        }

        #if targetEnvironment(simulator)
        state = .unsupported(
            "The simulator can show the interface. Live face tracking needs a physical iPhone with a TrueDepth front camera."
        )
        return
        #else
        guard ARFaceTrackingConfiguration.isSupported else {
            state = .unsupported("This device does not support ARKit face tracking.")
            return
        }

        guard let format = preferredFormat() else {
            state = .unsupported("A supported TrueDepth camera format was not found.")
            return
        }

        isStarting = true
        canRetry = false
        state = .starting
        defer { isStarting = false }

        let authorized: Bool
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            authorized = true
        case .notDetermined:
            authorized = await AVCaptureDevice.requestAccess(for: .video)
        default:
            authorized = false
        }

        guard wantsToRun, renderingFailure == nil else { return }
        guard authorized else {
            state = .denied
            return
        }

        let configuration = ARFaceTrackingConfiguration()
        configuration.videoFormat = format
        configuration.maximumNumberOfTrackedFaces = 1
        configuration.isLightEstimationEnabled = true
        configuration.providesAudioData = recordingCapture
        targetFrameRate = min(format.framesPerSecond, frameRateCeiling)
        clearFrame()
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        isSessionRunning = true
        state = .searching
        #endif
    }

    func pause() {
        if recordingCapture { recordingInterrupted?("Recording stopped because the camera paused.") }
        wantsToRun = false
        session.pause()
        clearFrame()
        isSessionRunning = false
        isInterrupted = false
        if !state.blocksPreview {
            state = .paused
        }
    }

    func updateTracking(hasFace: Bool) {
        guard isSessionRunning else { return }
        let nextState: CameraState = hasFace ? .tracking : .searching
        if state != nextState {
            state = nextState
        }
    }

    func rendererFailed(_ message: String) {
        recordingInterrupted?(message)
        renderingFailure = message
        canRetry = false
        session.pause()
        clearFrame()
        isSessionRunning = false
        state = .failed(message)
    }

    private var frameRateCeiling: Int { recordingCapture || previewMode == .avatar ? 30 : 60 }

    func setRecordingCapture(_ enabled: Bool) {
        guard recordingCapture != enabled else { return }
        recordingCapture = enabled
        updateCameraFormat()
    }

    private func preferredFormat() -> ARConfiguration.VideoFormat? {
        let ceiling = frameRateCeiling
        let formats = ARFaceTrackingConfiguration.supportedVideoFormats.filter {
            $0.captureDeviceType == .builtInTrueDepthCamera && $0.captureDevicePosition == .front
        }
        return formats.filter { $0.framesPerSecond <= ceiling }.sorted {
            if $0.framesPerSecond != $1.framesPerSecond { return $0.framesPerSecond > $1.framesPerSecond }
            return $0.imageResolution.width * $0.imageResolution.height
                > $1.imageResolution.width * $1.imageResolution.height
        }.first ?? formats.min { $0.framesPerSecond < $1.framesPerSecond }
    }

    private func updateCameraFormat() {
        guard isSessionRunning, let format = preferredFormat(),
              let configuration = session.configuration as? ARFaceTrackingConfiguration else { return }
        configuration.videoFormat = format
        configuration.providesAudioData = recordingCapture
        targetFrameRate = min(format.framesPerSecond, frameRateCeiling)
        session.run(configuration)
    }

    private func clearFrame() {
        latestFrame = nil
        frameConsumer?(nil)
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // ARSession delivers this callback on the explicitly configured main delegate queue.
        guard isSessionRunning else { return }
        latestFrame = frame
        updateTracking(hasFace: frame.anchors.contains { ($0 as? ARFaceAnchor)?.isTracked == true })
        frameConsumer?(frame)
        captureFrameConsumer?(frame)
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isSessionRunning = false
            self.recordingInterrupted?(message)
            self.clearFrame()
            self.isInterrupted = false
            self.canRetry = self.renderingFailure == nil
            self.state = .failed(message)
        }
    }

    nonisolated func sessionWasInterrupted(_ session: ARSession) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isSessionRunning = false
            self.isInterrupted = true
            if self.recordingCapture { self.recordingInterrupted?("Recording stopped because the camera was interrupted.") }
            self.clearFrame()
            if self.wantsToRun {
                self.state = .interrupted
            }
        }
    }

    nonisolated func sessionInterruptionEnded(_ session: ARSession) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isInterrupted = false
            if self.wantsToRun {
                await self.start()
            }
        }
    }

    func session(_ session: ARSession, didOutputAudioSampleBuffer audioSampleBuffer: CMSampleBuffer) {
        guard recordingCapture, isSessionRunning else { return }
        audioConsumer?(audioSampleBuffer)
    }
}
