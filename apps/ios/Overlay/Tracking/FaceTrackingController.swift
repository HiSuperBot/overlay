import ARKit
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
final class FaceTrackingController: NSObject, ARSessionDelegate {
    private(set) var state: CameraState = .starting
    private(set) var isSessionRunning = false
    private(set) var targetFrameRate = 60
    private(set) var canRetry = false
    var isMeshVisible = true

    @ObservationIgnored let session = ARSession()
    @ObservationIgnored private var wantsToRun = false
    @ObservationIgnored private var isStarting = false
    @ObservationIgnored private var isInterrupted = false
    @ObservationIgnored private var renderingFailure: String?

    override init() {
        super.init()
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

        let formats = ARFaceTrackingConfiguration.supportedVideoFormats.filter {
            $0.captureDeviceType == .builtInTrueDepthCamera
                && $0.captureDevicePosition == .front
        }
        let preferredFormats = formats.filter { $0.framesPerSecond <= 60 }.sorted {
            if $0.framesPerSecond != $1.framesPerSecond {
                return $0.framesPerSecond > $1.framesPerSecond
            }
            return $0.imageResolution.width * $0.imageResolution.height
                > $1.imageResolution.width * $1.imageResolution.height
        }
        guard let format = preferredFormats.first
            ?? formats.min(by: { $0.framesPerSecond < $1.framesPerSecond }) else {
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
        configuration.isLightEstimationEnabled = false
        targetFrameRate = min(format.framesPerSecond, 60)
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        isSessionRunning = true
        state = .searching
        #endif
    }

    func pause() {
        wantsToRun = false
        session.pause()
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
        renderingFailure = message
        canRetry = false
        session.pause()
        isSessionRunning = false
        state = .failed(message)
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isSessionRunning = false
            self.isInterrupted = false
            self.canRetry = self.renderingFailure == nil
            self.state = .failed(message)
        }
    }

    nonisolated func sessionWasInterrupted(_ session: ARSession) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isInterrupted = true
            self.isSessionRunning = false
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
}
