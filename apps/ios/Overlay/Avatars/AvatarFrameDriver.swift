@preconcurrency import ARKit
@preconcurrency import RealityKit
import simd

@MainActor
final class AvatarFrameDriver {
    private let controller: FaceTrackingController
    private weak var view: ARView?
    private let compositor: AvatarCompositor
    private let anchor = AnchorEntity(world: .zero)
    private var model: Entity?
    private var descriptor: AvatarDescriptor?
    private var loadedID: String?
    private var requestedID: String?
    private var loadTask: Task<Void, Never>?
    private var generation = 0
    private var lastRefit = -1
    private var lastRetry = -1
    private var lastTimestamp: TimeInterval = 0
    private var faceID: UUID?
    private var calibrator = NeutralFaceCalibrator()
    private var mapper = ExpressionMapper()
    private var maskTopology: FaceMaskTopology?
    private var morphEntities: [Entity] = []
    private var leftEye: Entity?
    private var rightEye: Entity?
    private var leftEyeNeutral = simd_quatf()
    private var rightEyeNeutral = simd_quatf()
    private var leftEyeBase = simd_quatf()
    private var rightEyeBase = simd_quatf()

    init(view: ARView, controller: FaceTrackingController, compositor: AvatarCompositor) {
        self.view = view
        self.controller = controller
        self.compositor = compositor
        anchor.isEnabled = false
        view.scene.addAnchor(anchor)
        controller.frameConsumer = { [weak self] frame in self?.update(frame) }
    }

    func configure() {
        if lastRetry != controller.avatarRetryGeneration {
            lastRetry = controller.avatarRetryGeneration
            requestedID = nil
            compositor.retry()
        }
        if lastRefit != controller.refitGeneration {
            lastRefit = controller.refitGeneration
            calibrator.reset()
            mapper.reset()
            hide()
        }
        if controller.previewMode != .avatar { hide() }
        guard let selected = controller.selectedAvatar else { return }
        guard requestedID != selected.id else { return }
        requestedID = selected.id
        generation += 1
        let token = generation
        loadTask?.cancel()
        hide()
        loadTask = Task { [weak self] in
            guard let self, !Task.isCancelled, token == generation else { return }
            controller.avatarLoadStarted()
            do {
                guard let url = AvatarCatalog.resource(selected.file) else {
                    throw CocoaError(.fileNoSuchFile)
                }
                let entity = try await Entity(contentsOf: url)
                guard !Task.isCancelled, token == generation else { return }
                var morphs: [Entity] = []
                walk(entity) { child in
                    if let mesh = child.components[ModelComponent.self]?.mesh,
                       child.components[BlendShapeWeightsComponent.self] == nil {
                        let weights = BlendShapeWeightsComponent(weightsMapping: BlendShapeWeightsMapping(meshResource: mesh))
                        if !weights.weightSet.isEmpty { child.components.set(weights) }
                    }
                    if child.components[BlendShapeWeightsComponent.self] != nil { morphs.append(child) }
                }
                let names = Set(morphs.flatMap { child in
                    child.components[BlendShapeWeightsComponent.self]!.weightSet.flatMap(\.weightNames)
                })
                guard names.contains("jawOpen"), names.contains("eyeBlinkLeft"), names.contains("eyeBlinkRight"),
                      let left = entity.findEntity(named: selected.leftEyeEntity),
                      let right = entity.findEntity(named: selected.rightEyeEntity) else {
                    throw AvatarLoadError.missingExpressions
                }
                model?.removeFromParent()
                model = entity
                descriptor = selected
                loadedID = selected.id
                morphEntities = morphs
                leftEye = left
                rightEye = right
                leftEyeBase = left.orientation
                rightEyeBase = right.orientation
                anchor.addChild(entity)
                mapper.reset()
                controller.avatarLoadFinished(id: selected.id)
            } catch {
                guard !Task.isCancelled, token == generation else { return }
                loadedID = nil
                hide()
                controller.avatarLoadFinished(id: selected.id, error: error.localizedDescription)
            }
        }
    }

    func stop() {
        generation += 1
        loadTask?.cancel()
        controller.frameConsumer = nil
        hide()
        anchor.removeFromParent()
    }

    private func hide() {
        anchor.isEnabled = false
        calibrator.interrupt()
        if controller.previewMode == .avatar, controller.isSessionRunning,
           let frame = controller.latestFrame, let view, view.bounds.width > 0, view.bounds.height > 0 {
            compositor.publish(CompositeFrame.camera(frame: frame, view: view))
        } else {
            compositor.publish(nil)
        }
    }

    private func update(_ frame: ARFrame?) {
        guard controller.previewMode == .avatar, controller.avatarError == nil, controller.isSessionRunning,
              let frame, let view, view.bounds.width > 0, view.bounds.height > 0 else {
            hide()
            return
        }
        // Raw camera passthrough is also published while loading, fitting, or losing tracking.
        guard let face = frame.anchors.compactMap({ $0 as? ARFaceAnchor }).first(where: \.isTracked) else {
            calibrator.sample(FaceMeasurements(leftEye: .zero, rightEye: .zero, width: 0, height: 0), neutral: false, time: frame.timestamp)
            anchor.isEnabled = false
            compositor.publish(CompositeFrame.camera(frame: frame, view: view))
            return
        }
        if faceID != face.identifier {
            faceID = face.identifier
            calibrator.reset()
            mapper.reset()
            lastTimestamp = 0
            maskTopology = nil
            controller.setFitReady(false)
            leftEyeNeutral = simd_quatf(face.leftEyeTransform)
            rightEyeNeutral = simd_quatf(face.rightEyeTransform)
        }
        let sources = Dictionary(uniqueKeysWithValues: face.blendShapes.map { ($0.key.rawValue, $0.value.floatValue) })
        let vertices = face.geometry.vertices
        let minY = vertices.map(\.y).min() ?? 0
        let maxY = vertices.map(\.y).max() ?? 0
        let width = (vertices.map(\.x).max() ?? 0) - (vertices.map(\.x).min() ?? 0)
        let faceMeasure = FaceMeasurements(
            leftEye: SIMD3(face.leftEyeTransform.columns.3.x, face.leftEyeTransform.columns.3.y, face.leftEyeTransform.columns.3.z),
            rightEye: SIMD3(face.rightEyeTransform.columns.3.x, face.rightEyeTransform.columns.3.y, face.rightEyeTransform.columns.3.z),
            width: width, height: maxY - minY
        )
        let cameraFace = frame.camera.transform.inverse * face.transform
        let forward = SIMD3(cameraFace.columns.2.x, cameraFace.columns.2.y, cameraFace.columns.2.z)
        let facingCamera = simd_normalize(forward).z > 0.94
        let neutral = facingCamera && ["jawOpen", "mouthSmileLeft", "mouthSmileRight", "eyeBlinkLeft", "eyeBlinkRight"]
            .allSatisfy { (sources[$0] ?? 0) < 0.18 }
        let wasReady = calibrator.measurements != nil
        calibrator.sample(faceMeasure, neutral: neutral, time: frame.timestamp)
        if !wasReady && calibrator.measurements != nil {
            leftEyeNeutral = simd_quatf(face.leftEyeTransform)
            rightEyeNeutral = simd_quatf(face.rightEyeTransform)
        }
        controller.setFitReady(calibrator.measurements != nil)
        guard let model, let descriptor, loadedID == controller.selectedAvatarID,
              let measurement = calibrator.measurements,
              let fit = AvatarFit.solve(face: measurement, model: descriptor.fitting) else {
            anchor.isEnabled = false
            compositor.publish(CompositeFrame.camera(frame: frame, view: view))
            return
        }
        anchor.transform = Transform(matrix: face.transform)
        model.scale = fit.scale
        model.position = fit.translation
        anchor.isEnabled = true
        if frame.timestamp - lastTimestamp >= 1.0 / 30.0 - 0.002 {
            lastTimestamp = frame.timestamp
            let weights = mapper.update(sources: sources, bindings: descriptor.expressions, time: frame.timestamp)
            for entity in morphEntities {
                guard var component = entity.components[BlendShapeWeightsComponent.self] else { continue }
                for index in component.weightSet.indices {
                    var data = component.weightSet[index]
                    for weightIndex in data.weights.indices {
                        data.weights[weightIndex] = weights[data.weightNames[weightIndex]] ?? 0
                    }
                    component.weightSet[index] = data
                }
                entity.components.set(component)
            }
            leftEye?.orientation = simd_quatf(face.leftEyeTransform) * leftEyeNeutral.inverse * leftEyeBase
            rightEye?.orientation = simd_quatf(face.rightEyeTransform) * rightEyeNeutral.inverse * rightEyeBase
        }
        if maskTopology?.vertexCount != vertices.count {
            maskTopology = FaceMaskTopology(
                indices: face.geometry.triangleIndices.map { UInt16(bitPattern: $0) }, vertices: vertices
            )
        }
        compositor.publish(CompositeFrame.camera(frame: frame, view: view, face: face, topology: maskTopology))
    }

    private func walk(_ entity: Entity, visit: (Entity) -> Void) {
        visit(entity)
        for child in entity.children { walk(child, visit: visit) }
    }
}

private enum AvatarLoadError: LocalizedError {
    case missingExpressions
    var errorDescription: String? {
        "This avatar is missing its facial expressions or eyes. Showing the original camera."
    }
}
