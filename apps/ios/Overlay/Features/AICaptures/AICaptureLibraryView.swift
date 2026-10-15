import SwiftUI
import AVKit
import UIKit

struct AICaptureLibraryView: View {
    let store: AICaptureStore
    @Environment(\.dismiss) private var dismiss
    @State private var items: [AICaptureItem] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Group {
                if loading { ProgressView("Loading captures…") }
                else if items.isEmpty {
                    ContentUnavailableView("No AI captures", systemImage: "square.stack.3d.up",
                        description: Text(error ?? "Record in AI mode to keep original video and depth on this iPhone."))
                } else {
                    List(items) { item in
                        NavigationLink {
                            AICaptureDetailView(item: item, store: store, onDelete: { Task { await refresh() } })
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(item.manifest.createdAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.headline)
                                Text("\(item.manifest.status.title) · \(Int(item.manifest.duration))s · \(ByteCountFormatter.string(fromByteCount: item.byteCount, countStyle: .file))")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text("\(item.manifest.depthFrameCount) depth samples")
                                    .font(.caption).foregroundStyle(.mint)
                            }
                            .padding(.vertical, 5)
                        }
                    }
                    .refreshable { await refresh() }
                    .overlay(alignment: .bottom) {
                        if let error { Text(error).font(.caption).padding().background(.black.opacity(0.8)) }
                    }
                }
            }
            .navigationTitle("AI Captures")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await refresh() }
        }
        .preferredColorScheme(.dark)
    }

    private func refresh() async {
        do { items = try await store.list(); error = nil }
        catch { self.error = error.localizedDescription }
        loading = false
    }
}

private struct AISharedArchive: Identifiable {
    let id = UUID()
    let url: URL
}

private struct AICaptureDetailView: View {
    let item: AICaptureItem
    let store: AICaptureStore
    let onDelete: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var depthImage: UIImage?
    @State private var depthRecord: AIDepthRecord?
    @State private var error: String?
    @State private var exporting = false
    @State private var deleting = false
    @State private var confirmDelete = false
    @State private var archive: AISharedArchive?
    @State private var exportURL: URL?
    @State private var exportTask: Task<Void, Never>?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Original video").font(.headline)
                if let player {
                    VideoPlayer(player: player).frame(height: 300).clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    Text("The video is unavailable. Other captured data can still be exported.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                GroupBox("Capture") {
                    VStack(spacing: 8) {
                        LabeledContent("Status", value: item.manifest.status.title)
                        LabeledContent("Duration", value: "\(item.manifest.duration.formatted(.number.precision(.fractionLength(1))))s")
                        LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: item.byteCount, countStyle: .file))
                        LabeledContent("Video", value: "\(item.manifest.videoWidth) × \(item.manifest.videoHeight)")
                        LabeledContent("Audio", value: item.manifest.hasAudio ? "Recorded" : "Unavailable")
                    }.font(.subheadline)
                }
                GroupBox("Depth") {
                    VStack(spacing: 8) {
                        LabeledContent("Samples", value: String(item.manifest.depthFrameCount))
                        LabeledContent("Video frames without depth", value: String(item.manifest.missingDepthFrameCount))
                        LabeledContent("Dropped sensor pairs", value: String(item.manifest.droppedFrameCount))
                        if let depthRecord {
                            LabeledContent("Resolution", value: "\(depthRecord.width) × \(depthRecord.height)")
                            LabeledContent("Format", value: depthRecord.format.rawValue)
                            LabeledContent("System filtered", value: depthRecord.filtered ? "Yes" : "No")
                            LabeledContent("Calibration", value: depthRecord.calibration == nil ? "Unavailable" : "Included")
                        }
                    }.font(.caption)
                }
                if let depthImage {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("First depth sample").font(.headline)
                        Image(uiImage: depthImage).resizable().scaledToFit().frame(maxHeight: 260)
                            .frame(maxWidth: .infinity).background(.black)
                        Text("Red is nearer; blue is farther. Missing values are transparent.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else if item.manifest.depthFrameCount > 0 {
                    Text("No valid distances are available for the depth preview.").font(.caption).foregroundStyle(.secondary)
                }
                if let reason = item.manifest.stopReason { Text(reason).font(.caption).foregroundStyle(.orange) }
                if let error { Text(error).font(.caption).foregroundStyle(.orange) }
                HStack {
                    Button { beginExport() } label: {
                        if exporting { ProgressView("Creating ZIP…") }
                        else { Label("Export ZIP", systemImage: "square.and.arrow.up") }
                    }
                    .buttonStyle(.borderedProminent).tint(.mint)
                    Spacer()
                    Button("Delete", role: .destructive) { confirmDelete = true }.buttonStyle(.bordered)
                }
                .disabled(exporting || deleting)
            }
            .padding(20)
        }
        .navigationTitle("AI Capture")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadPreview() }
        .onDisappear { player?.pause(); exportTask?.cancel() }
        .confirmationDialog("Delete this AI capture?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete capture", role: .destructive) {
                deleting = true
                Task {
                    do { try await store.delete(item); onDelete(); dismiss() }
                    catch { self.error = error.localizedDescription; deleting = false }
                }
            }
        } message: { Text("The original video and depth data will be removed from this iPhone.") }
        .sheet(item: $archive, onDismiss: { removeArchive() }) { share in
            AIArchiveShareSheet(url: share.url) { archive = nil }
        }
    }

    private func loadPreview() async {
        if item.videoPlayable { player = AVPlayer(url: item.videoURL) }
        do {
            if let (data, record) = try await store.firstDepth(in: item) {
                depthRecord = record
                let image = await Task.detached(priority: .utility) { AIDepthVisualization.image(data: data, record: record) }.value
                if let image {
                    let orientation: UIImage.Orientation = item.manifest.videoPresentationTransform[1] >= 0 ? .right : .left
                    depthImage = UIImage(cgImage: image, scale: 1, orientation: orientation)
                }
            }
        } catch { self.error = error.localizedDescription }
    }

    private func beginExport() {
        exporting = true
        error = nil
        exportTask = Task {
            do {
                let url = try await store.export(item)
                guard !Task.isCancelled else { await store.removeExport(url); exporting = false; return }
                exportURL = url
                archive = AISharedArchive(url: url)
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            exporting = false
        }
    }

    private func removeArchive() {
        if let url = exportURL { Task { await store.removeExport(url) } }
        exportURL = nil
    }
}

private struct AIArchiveShareSheet: UIViewControllerRepresentable {
    let url: URL
    let onFinish: @MainActor () -> Void
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in Task { @MainActor in onFinish() } }
        return controller
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
