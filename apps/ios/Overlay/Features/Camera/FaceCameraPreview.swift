@preconcurrency import ARKit
import MetalKit
import RealityKit
import SwiftUI

struct FaceCameraPreview: UIViewRepresentable {
    let controller: FaceTrackingController
    let recording: RecordingController

    func makeUIView(context: Context) -> CameraPreviewHost { CameraPreviewHost(controller: controller, recording: recording) }
    func updateUIView(_ view: CameraPreviewHost, context: Context) { view.configure() }
    static func dismantleUIView(_ view: CameraPreviewHost, coordinator: ()) { view.stop() }
}

@MainActor
final class CameraPreviewHost: UIView {
    private let controller: FaceTrackingController
    private let recording: RecordingController
    private let realityView: ARView
    private let metalView: MTKView
    private var meshRenderer: FaceMeshRenderer?
    private var avatarDriver: AvatarFrameDriver?
    private let compositor: AvatarCompositor

    init(controller: FaceTrackingController, recording: RecordingController) {
        self.controller = controller
        self.recording = recording
        realityView = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        metalView = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        compositor = AvatarCompositor(recordingSink: recording.frameSink) { [weak controller] message in
            Task { @MainActor [weak controller] in
                controller?.avatarRenderingFailed(message)
            }
        }
        super.init(frame: .zero)
        backgroundColor = .black
        clipsToBounds = true
        // Both previews consume the controller's one session; neither creates or runs a capture session.
        realityView.session = controller.session
        controller.session.delegate = controller
        controller.session.delegateQueue = .main
        realityView.renderOptions.insert(.disableFaceMesh)
        realityView.renderOptions.insert(.disablePersonOcclusion)
        realityView.renderOptions.insert(.disableMotionBlur)
        realityView.renderOptions.insert(.disableDepthOfField)
        realityView.renderOptions.insert(.disableHDR)
        realityView.environment.sceneUnderstanding.options = []
        realityView.renderCallbacks.prepareWithDevice = { [compositor] device in compositor.prepare(device: device) }
        realityView.renderCallbacks.postProcess = { [compositor] context in compositor.process(context) }
        addSubview(realityView)
        metalView.colorPixelFormat = .bgra8Unorm
        metalView.depthStencilPixelFormat = .depth32Float
        metalView.clearColor = MTLClearColorMake(0, 0, 0, 1)
        metalView.clearDepth = 1
        metalView.framebufferOnly = false
        metalView.isPaused = true
        metalView.isOpaque = true
        metalView.backgroundColor = .black
        addSubview(metalView)
        isAccessibilityElement = true
        accessibilityLabel = "Live front camera preview"
        do {
            let renderer = try FaceMeshRenderer(view: metalView, controller: controller, recordingSink: recording.frameSink)
            meshRenderer = renderer
            metalView.delegate = renderer
        } catch {
            Task { @MainActor in controller.rendererFailed(error.localizedDescription) }
        }
        avatarDriver = AvatarFrameDriver(view: realityView, controller: controller, compositor: compositor)
    }

    required init?(coder: NSCoder) { fatalError("Use init(controller:)") }

    override func layoutSubviews() {
        super.layoutSubviews()
        var size = bounds.size
        if let aspect = recording.lockedAspectRatio, size.width > 0, size.height > 0 {
            if size.width / size.height > aspect { size.width = size.height * aspect }
            else { size.height = size.width / aspect }
        }
        realityView.bounds = CGRect(origin: .zero, size: size)
        realityView.center = CGPoint(x: bounds.midX, y: bounds.midY)
        metalView.bounds = CGRect(origin: .zero, size: size)
        metalView.center = CGPoint(x: bounds.midX, y: bounds.midY)
        let scale = metalView.contentScaleFactor
        recording.updateViewport(CGSize(width: size.width * scale, height: size.height * scale), device: metalView.device)
    }

    func configure() {
        setNeedsLayout()
        avatarDriver?.configure()
        let avatar = controller.isSessionRunning && controller.previewMode == .avatar && controller.avatarError == nil
        realityView.isHidden = !avatar
        metalView.isHidden = avatar || !controller.isSessionRunning
        metalView.preferredFramesPerSecond = controller.targetFrameRate
        metalView.isPaused = avatar || !controller.isSessionRunning || meshRenderer == nil
    }

    func stop() {
        avatarDriver?.stop()
        realityView.renderCallbacks = .init()
        metalView.isPaused = true
        metalView.delegate = nil
        meshRenderer = nil
    }
}
