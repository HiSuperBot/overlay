import SwiftUI
import UIKit

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var controller = FaceTrackingController()

    var body: some View {
        VStack(spacing: 0) {
            header
            ZStack {
                Color.black
                #if !targetEnvironment(simulator)
                FaceCameraPreview(controller: controller)
                    .scaleEffect(x: -1, y: 1)
                #endif
                previewMessage
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            footer
        }
        .background(.black)
        .preferredColorScheme(.dark)
        .task {
            await controller.start()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await controller.start() }
            } else {
                controller.pause()
            }
        }
        .onDisappear {
            controller.pause()
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("OVERLAY")
                    .font(.headline)
                    .tracking(3)
                Text("FACE CAMERA")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .tracking(1.5)
            }
            Spacer()
            HStack(spacing: 7) {
                Circle()
                    .fill(controller.state == .tracking ? Color.mint : .gray)
                    .frame(width: 7, height: 7)
                Text(controller.state.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 20)
    }

    @ViewBuilder
    private var previewMessage: some View {
        if controller.state.blocksPreview {
            VStack(spacing: 16) {
                Image(systemName: controller.state == .denied ? "camera.fill" : "faceid")
                    .font(.system(size: 42, weight: .light))
                    .foregroundStyle(.mint)
                Text(controller.state.title)
                    .font(.title3.weight(.semibold))
                if let detail = controller.state.detail {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                if controller.state == .denied {
                    Button("Open Settings") {
                        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                        UIApplication.shared.open(url)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.mint)
                } else if controller.canRetry {
                    Button("Retry") {
                        Task { await controller.start() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.mint)
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black.opacity(0.9))
        } else if controller.state == .searching {
            VStack {
                Spacer()
                Label("Position your face in the camera", systemImage: "faceid")
                    .font(.subheadline)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(.black.opacity(0.65), in: Capsule())
                    .padding(.bottom, 24)
            }
        } else if controller.state == .starting {
            ProgressView()
                .tint(.white)
        }
    }

    private var footer: some View {
        VStack(spacing: 18) {
            Toggle(isOn: $controller.isMeshVisible) {
                Label("Face mesh", systemImage: "faceid")
                    .font(.headline)
            }
            .tint(.mint)
            Text("Live preview · Processed on your iPhone")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 22)
    }
}
