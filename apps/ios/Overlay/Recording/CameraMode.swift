import Foundation

nonisolated enum CameraMode: String, CaseIterable, Identifiable, Sendable {
    case video, ai
    var id: String { rawValue }
    var title: String { self == .ai ? "AI" : rawValue.capitalized }
    var requiresPhotoPermission: Bool { self == .video }
    var caption: String {
        switch self {
        case .video: "Video + audio · Saved to Photos"
        case .ai: "Original video + depth · Saved in app"
        }
    }
}
