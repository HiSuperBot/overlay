import Foundation

nonisolated enum PreviewMode: String, CaseIterable, Identifiable {
    case original, mesh, avatar
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

nonisolated struct AvatarDescriptor: Codable, Identifiable, Sendable {
    let id: String
    let name: String
    let file: String
    let thumbnail: String
    let expressions: [String: ExpressionBinding]
    let fitting: AvatarFittingMetadata
    let leftEyeEntity: String
    let rightEyeEntity: String

    struct ExpressionBinding: Codable, Sendable {
        let source: String
        let gain: Float
    }
}

nonisolated struct AvatarFittingMetadata: Codable, Sendable {
    let leftEye: [Float]
    let rightEye: [Float]
    let faceWidth: Float
    let faceHeight: Float
}

nonisolated enum AvatarCatalog {
    static func resource(_ name: String) -> URL? {
        let filename = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        return Bundle.main.url(forResource: filename, withExtension: ext, subdirectory: "Avatars")
            ?? Bundle.main.url(forResource: filename, withExtension: ext)
    }

    static func load() throws -> [AvatarDescriptor] {
        guard let url = resource("catalog.json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let avatars = try JSONDecoder().decode([AvatarDescriptor].self, from: Data(contentsOf: url))
        guard !avatars.isEmpty, Set(avatars.map(\.id)).count == avatars.count,
              avatars.allSatisfy({ avatar in
                  resource(avatar.file) != nil && resource(avatar.thumbnail) != nil
                      && avatar.fitting.leftEye.count == 3 && avatar.fitting.rightEye.count == 3
                      && avatar.fitting.leftEye.allSatisfy(\.isFinite) && avatar.fitting.rightEye.allSatisfy(\.isFinite)
                      && avatar.fitting.faceWidth.isFinite && avatar.fitting.faceHeight.isFinite
                      && avatar.fitting.faceWidth > 0 && avatar.fitting.faceHeight > 0
              }) else { throw CocoaError(.fileReadCorruptFile) }
        return avatars
    }
}
