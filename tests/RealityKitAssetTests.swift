import Foundation
import RealityKit

@main
struct RealityKitAssetTests {
    @MainActor
    static func main() async throws {
        for path in CommandLine.arguments.dropFirst() {
            let entity = try await Entity(contentsOf: URL(fileURLWithPath: path))
            var names: Set<String> = []
            var meshes = 0
            var materialTypes: Set<String> = []
            func inspect(_ child: Entity) {
                if let model = child.components[ModelComponent.self] {
                    meshes += 1
                    for material in model.materials { materialTypes.insert(String(describing: type(of: material))) }
                    if child.components[BlendShapeWeightsComponent.self] == nil {
                        let component = BlendShapeWeightsComponent(weightsMapping: BlendShapeWeightsMapping(meshResource: model.mesh))
                        if !component.weightSet.isEmpty { child.components.set(component) }
                    }
                }
                if let component = child.components[BlendShapeWeightsComponent.self] {
                    for data in component.weightSet { names.formUnion(data.weightNames) }
                }
                for next in child.children { inspect(next) }
            }
            inspect(entity)
            guard materialTypes == ["PhysicallyBasedMaterial"], names.count == 52, names.contains("eyeBlinkLeft"), names.contains("jawOpen"),
                  entity.findEntity(named: "LeftEye") != nil,
                  entity.findEntity(named: "RightEye") != nil else {
                throw NSError(domain: "OverlayAssets", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing imported morphs or eyes: \(names.sorted())"])
            }
            print("PASS: RealityKit imported \(URL(fileURLWithPath: path).lastPathComponent): \(meshes) meshes, \(names.count) expressions, eye pivots, \(materialTypes.sorted())")
        }
    }
}
