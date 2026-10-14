import MetalKit
import SwiftUI

struct FaceCameraPreview: UIViewRepresentable {
    let controller: FaceTrackingController

    final class Coordinator {
        var renderer: FaceMeshRenderer?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .depth32Float
        view.clearColor = MTLClearColorMake(0, 0, 0, 1)
        view.clearDepth = 1
        view.framebufferOnly = true
        view.isPaused = true
        view.isOpaque = true
        view.backgroundColor = .black
        view.isAccessibilityElement = true
        view.accessibilityLabel = "Live front camera preview"

        do {
            let renderer = try FaceMeshRenderer(view: view, controller: controller)
            context.coordinator.renderer = renderer
            view.delegate = renderer
        } catch {
            let message = error.localizedDescription
            Task { @MainActor in
                controller.rendererFailed(message)
            }
        }
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        view.preferredFramesPerSecond = controller.targetFrameRate
        view.isPaused = !controller.isSessionRunning || context.coordinator.renderer == nil
    }

    static func dismantleUIView(_ view: MTKView, coordinator: Coordinator) {
        view.isPaused = true
        view.delegate = nil
        coordinator.renderer = nil
    }
}
