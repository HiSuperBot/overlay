import SwiftUI
import UIKit

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var controller = FaceTrackingController()
    @State private var isFacePickerPresented = false
    @State private var facePickerDetent: PresentationDetent = .medium

    var body: some View {
        VStack(spacing: 0) {
            header
            ZStack {
                Color.black
                #if !targetEnvironment(simulator)
                FaceCameraPreview(controller: controller)
                #endif
                previewMessage
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            footer
        }
        .background(.black)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $isFacePickerPresented) {
            FaceSelectionSheet(controller: controller)
                .presentationDetents([.medium, .large], selection: $facePickerDetent)
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(28)
                .preferredColorScheme(.dark)
        }
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
        VStack(spacing: 14) {
            HStack {
                Button {
                    facePickerDetent = .medium
                    isFacePickerPresented = true
                } label: {
                    HStack(spacing: 8) {
                        Label("Face", systemImage: "faceid")
                        Image(systemName: "chevron.up")
                            .font(.caption.weight(.semibold))
                    }
                    .font(.subheadline.weight(.semibold))
                    .padding(.vertical, 4)
                }
                .buttonStyle(.bordered)
                .tint(.mint)
                .accessibilityLabel("Choose face effect")
                .accessibilityValue(selectedEffectName)
                .accessibilityHint("Opens Original, Mesh, and avatar choices.")
                Spacer()
                Text(selectedEffectName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            }
            if controller.previewMode == .avatar {
                if controller.avatarError == nil {
                    HStack {
                        if controller.avatarLoading {
                            ProgressView().controlSize(.small)
                            Text("Loading avatar…")
                        } else {
                            Text(controller.fitReady ? "Face fitted" : "Look straight ahead and relax for 1 second")
                        }
                        Spacer()
                        Button("Re-fit") { controller.refit() }
                            .disabled(controller.state != .tracking || controller.avatarLoading)
                    }
                    .font(.caption)
                }
            }
            if let error = controller.avatarError {
                VStack(alignment: .leading, spacing: 8) {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                    if controller.previewMode == .avatar && controller.selectedAvatar != nil {
                        Button("Retry avatar") { controller.retryAvatar() }.font(.caption)
                    }
                }
            }
            Text("Live preview · Processed on your iPhone")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var selectedEffectName: String {
        switch controller.previewMode {
        case .original, .mesh: controller.previewMode.title
        case .avatar: controller.selectedAvatar?.name ?? "Avatar"
        }
    }
}
