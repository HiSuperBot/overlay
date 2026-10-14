@preconcurrency import ARKit
import MetalKit
import RealityKit
import SwiftUI

struct FaceCameraPreview: UIViewRepresentable {
    let controller: FaceTrackingController

    func makeUIView(context: Context) -> CameraPreviewHost { CameraPreviewHost(controller: controller) }
    func updateUIView(_ view: CameraPreviewHost, context: Context) { view.configure() }
    static func dismantleUIView(_ view: CameraPreviewHost, coordinator: ()) { view.stop() }
}

@MainActor
final class CameraPreviewHost: UIView {
    private let controller: FaceTrackingController
    private let realityView: ARView
    private let metalView: MTKView
    private var meshRenderer: FaceMeshRenderer?
    private var avatarDriver: AvatarFrameDriver?
    private let compositor: AvatarCompositor

    init(controller: FaceTrackingController) {
        self.controller = controller
        realityView = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        metalView = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        compositor = AvatarCompositor { [weak controller] message in
            Task { @MainActor in
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
        metalView.framebufferOnly = true
        metalView.isPaused = true
        metalView.isOpaque = true
        metalView.backgroundColor = .black
        // The diagnostic renderer uses unmirrored ARKit matrices, so reflect its complete result once.
        metalView.transform = CGAffineTransform(scaleX: -1, y: 1)
        addSubview(metalView)
        isAccessibilityElement = true
        accessibilityLabel = "Live front camera preview"
        do {
            let renderer = try FaceMeshRenderer(view: metalView, controller: controller)
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
        realityView.frame = bounds
        metalView.bounds = CGRect(origin: .zero, size: bounds.size)
        metalView.center = CGPoint(x: bounds.midX, y: bounds.midY)
    }

    func configure() {
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
