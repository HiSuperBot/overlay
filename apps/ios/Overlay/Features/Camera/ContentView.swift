import SwiftUI
import UIKit

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var controller: FaceTrackingController
    @State private var recording: RecordingController
    @State private var isFacePickerPresented = false
    @State private var facePickerDetent: PresentationDetent = .medium
    @State private var sharedVideo: SharedVideo?
    @State private var isAILibraryPresented = false

    init() {
        let tracking = FaceTrackingController()
        _controller = State(initialValue: tracking)
        _recording = State(initialValue: RecordingController(tracking: tracking))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ZStack {
                Color.black
                #if !targetEnvironment(simulator)
                FaceCameraPreview(controller: controller, recording: recording)
                #endif
                previewMessage
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .overlay(alignment: .top) { recordingOverlay }
            footer
        }
        .background(.black)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $isFacePickerPresented) {
            FaceSelectionSheet(controller: controller)
                .disabled(recording.state.locksEffects)
                .presentationDetents([.medium, .large], selection: $facePickerDetent)
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(28)
                .preferredColorScheme(.dark)
        }
        .sheet(item: $sharedVideo) { video in
            VideoShareSheet(url: video.url)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $isAILibraryPresented) {
            AICaptureLibraryView(store: recording.aiStore)
        }
        .task {
            await recording.prepareRecovery()
            guard !Task.isCancelled else { return }
            await controller.start()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await controller.start() }
            } else {
                recording.applicationDidLeaveForeground(background: phase == .background)
                controller.pause()
            }
        }
        .onChange(of: recording.state.locksEffects) { _, locked in
            if locked { isFacePickerPresented = false; isAILibraryPresented = false }
        }
        .onDisappear {
            recording.stop(reason: "Recording stopped because the camera screen closed.")
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
            Button { isAILibraryPresented = true } label: {
                Image(systemName: "square.stack.3d.up").font(.title3).frame(width: 44, height: 44)
            }
            .tint(.mint).disabled(recording.state.locksEffects || !recording.recoveryReady)
            .accessibilityLabel("AI Captures")
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
            Picker("Camera mode", selection: Binding(get: { recording.cameraMode }, set: { recording.selectCameraMode($0) })) {
                ForEach(CameraMode.allCases) { mode in Text(mode.title).tag(mode) }
            }
            .pickerStyle(.segmented)
            .disabled(recording.state.locksEffects)
            HStack(spacing: 12) {
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
                .disabled(recording.state.locksEffects)
                .accessibilityLabel("Choose face effect")
                .accessibilityValue(selectedEffectName)
                .accessibilityHint("Opens Original, Mesh, and avatar choices.")
                .frame(maxWidth: .infinity, alignment: .leading)
                recordButton
                Text(selectedEffectName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .frame(height: 80)
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
                            .disabled(controller.state != .tracking || controller.avatarLoading || recording.state.locksEffects)
                    }
                    .font(.caption)
                    .frame(height: 32)
                }
            }
            if let error = controller.avatarError {
                VStack(alignment: .leading, spacing: 8) {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                    if controller.previewMode == .avatar && controller.selectedAvatar != nil {
                        Button("Retry avatar") { controller.retryAvatar() }
                            .font(.caption).disabled(recording.state.locksEffects)
                    }
                }
            }
            Text(recording.cameraMode.caption)
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var recordButton: some View {
        Button {
            if recording.state == .recording { recording.stop() }
            else { Task { await recording.start() } }
        } label: {
            ZStack {
                Circle().strokeBorder(.white, lineWidth: 4)
                RoundedRectangle(cornerRadius: recording.state == .recording ? 7 : 30)
                    .fill(.red)
                    .frame(width: recording.state == .recording ? 32 : 60,
                           height: recording.state == .recording ? 32 : 60)
                if !recording.state.canToggle { ProgressView().tint(.white) }
            }
            .frame(width: 76, height: 76)
            .opacity(recording.state == .idle && !recording.canStart ? 0.4 : 1)
            .animation(.easeInOut(duration: 0.15), value: recording.state)
        }
        .buttonStyle(.plain)
        .disabled(!recording.state.canToggle || (recording.state == .idle && !recording.canStart))
        .accessibilityLabel(recording.state == .recording ? "Stop recording" : "Start recording")
        .accessibilityHint(recording.cameraMode == .ai
            ? "Records original camera video, microphone audio, and depth inside the app."
            : "Records the camera and face effect with microphone audio, then saves to Photos.")
        .frame(width: 76, height: 80)
    }

    @ViewBuilder
    private var recordingOverlay: some View {
        VStack(spacing: 10) {
            if recording.state != .idle {
                HStack(spacing: 8) {
                    if recording.state == .recording {
                        Circle().fill(.red).frame(width: 8, height: 8)
                        Text("\(recording.cameraMode == .ai ? "AI REC" : "REC") \(recording.durationLabel)").monospacedDigit()
                    } else {
                        ProgressView().tint(.white)
                        Text(recording.state == .preparing ? "Preparing recording…" : "Saving video…")
                    }
                }
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(.black.opacity(0.75), in: Capsule())
                .accessibilityElement(children: .combine)
            }
            if let notice = recording.notice, recording.state == .idle {
                VStack(spacing: 10) {
                    HStack(alignment: .top, spacing: 12) {
                        Text(notice).font(.caption)
                        Spacer(minLength: 0)
                        Button { recording.dismissNotice() } label: { Image(systemName: "xmark") }
                            .accessibilityLabel("Dismiss recording message")
                            .frame(minWidth: 30, minHeight: 30)
                    }
                    HStack(spacing: 18) {
                        if recording.needsSettings {
                            Button("Open Settings") {
                                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                                UIApplication.shared.open(url)
                            }
                        }
                        if !recording.pendingVideos.isEmpty, recording.cameraMode.requiresPhotoPermission {
                            Button("Retry save") { Task { await recording.retrySave() } }
                            if let url = recording.shareURL, recording.cameraMode.requiresPhotoPermission {
                                Button("Share") { sharedVideo = SharedVideo(url: url) }
                            }
                        }
                    }
                    .font(.caption.weight(.semibold)).tint(.mint)
                }
                .padding(14)
                .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 14))
            }
        }
        .padding(14)
    }

    private var selectedEffectName: String {
        switch controller.previewMode {
        case .original, .mesh: controller.previewMode.title
        case .avatar: controller.selectedAvatar?.name ?? "Avatar"
        }
    }
}

private struct SharedVideo: Identifiable {
    let id = UUID()
    let url: URL
}

private struct VideoShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
