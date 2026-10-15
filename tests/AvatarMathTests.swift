import Foundation
import simd


final class AvatarMathTests {
    private func face(scale: Float = 1, offset: SIMD3<Float> = .zero) -> FaceMeasurements {
        FaceMeasurements(leftEye: SIMD3(0.032, 0, 0) * scale + offset,
                         rightEye: SIMD3(-0.032, 0, 0) * scale + offset,
                         width: 0.14 * scale, height: 0.18 * scale)
    }

    func testFitAlignsEyeMidpointAndMeters() throws {
        let model = AvatarFittingMetadata(leftEye: [0.032, 0.02, 0.01], rightEye: [-0.032, 0.02, 0.01], faceWidth: 0.14, faceHeight: 0.18)
        let measured = face(scale: 1.15, offset: SIMD3(0.004, 0.006, 0.009))
        let fit = AvatarFit.solve(face: measured, model: model)!
        let mapped = SIMD3<Float>(0, 0.02, 0.01) * fit.scale + fit.translation
        try expect(simd_distance(mapped, (measured.leftEye + measured.rightEye) / 2) < 0.00001)
        try expect(abs(fit.scale.x - 1.15) < 0.001)
        let wrongUnits = AvatarFittingMetadata(leftEye: [32, 20, 10], rightEye: [-32, 20, 10], faceWidth: 140, faceHeight: 180)
        try expectNil(AvatarFit.solve(face: measured, model: wrongUnits))
    }

    func testFitRejectsInvalidTrackingMeasurements() throws {
        let model = AvatarFittingMetadata(leftEye: [0.032, 0, 0], rightEye: [-0.032, 0, 0], faceWidth: 0.14, faceHeight: 0.18)
        let invalid = FaceMeasurements(leftEye: SIMD3(.nan, 0, 0), rightEye: .zero, width: 0.14, height: 0.18)
        try expectNil(AvatarFit.solve(face: invalid, model: model))
    }

    func testCalibrationRequiresAContinuousNeutralSecond() throws {
        var calibrator = NeutralFaceCalibrator()
        for i in 0..<24 { calibrator.sample(face(), neutral: true, time: Double(i) / 30) }
        try expectNil(calibrator.measurements)
        calibrator.sample(face(), neutral: false, time: 0.8)
        for i in 0..<30 { calibrator.sample(face(), neutral: true, time: 1 + Double(i) / 30) }
        try expectNil(calibrator.measurements)
        calibrator.sample(face(), neutral: true, time: 2.01)
        try expectNotNil(calibrator.measurements)
        calibrator.reset()
        try expectNil(calibrator.measurements)
    }

    func testCalibrationDoesNotBridgeAFrameGap() throws {
        var calibrator = NeutralFaceCalibrator()
        for i in 0..<25 { calibrator.sample(face(), neutral: true, time: Double(i) / 30) }
        calibrator.sample(face(), neutral: true, time: 5)
        try expectNil(calibrator.measurements)
        for i in 1...31 { calibrator.sample(face(), neutral: true, time: 5 + Double(i) / 30) }
        try expectNotNil(calibrator.measurements)
        calibrator.interrupt()
        try expectNotNil(calibrator.measurements)
    }

    func testFastBlinkDoesNotDriveOtherExpressions() throws {
        var mapper = ExpressionMapper()
        let bindings: [String: AvatarDescriptor.ExpressionBinding] = [
            "eyeBlinkLeft": .init(source: "eyeBlinkLeft", gain: 1.08),
            "eyeBlinkRight": .init(source: "eyeBlinkRight", gain: 1.08),
            "browInnerUp": .init(source: "browInnerUp", gain: 1),
            "jawOpen": .init(source: "jawOpen", gain: 1.04),
        ]
        let result = mapper.update(sources: ["eyeBlinkLeft": 1, "browInnerUp": 1, "jawOpen": 1.5], bindings: bindings, time: 1)
        try expect(result["eyeBlinkLeft"]! > 0.9)
        try expectEqual(result["eyeBlinkRight"], 0)
        try expect(result["eyeBlinkLeft"]! > result["browInnerUp"]!)
        try expect(result["jawOpen"]! <= 1)
        mapper.reset()
        let zero = mapper.update(sources: [:], bindings: bindings, time: 2)
        try expect(zero.values.allSatisfy { $0 == 0 })
    }

    func testNonFiniteExpressionCannotReachRenderer() throws {
        var mapper = ExpressionMapper()
        let value = mapper.update(sources: ["jawOpen": .nan], bindings: ["jawOpen": .init(source: "jawOpen", gain: 1)], time: 0)
        try expectEqual(value["jawOpen"], 0)
    }

    func testMaskFillsHolesWithoutCappingTheOuterBoundary() throws {
        let vertices: [SIMD3<Float>] = [SIMD3(-2,-2,0), SIMD3(2,-2,0), SIMD3(2,2,0), SIMD3(-2,2,0),
                                      SIMD3(-1,-1,0), SIMD3(1,-1,0), SIMD3(1,1,0), SIMD3(-1,1,0)]
        let triangles: [UInt16] = [0,1,5, 0,5,4, 1,2,6, 1,6,5, 2,3,7, 2,7,6, 3,0,4, 3,4,7]
        try expectEqual(Set(FaceOutline.outerLoop(indices: triangles, vertices: vertices)), Set([0,1,2,3]))
        try expect(FaceOutline.outerLoop(indices: [0,1,99], vertices: vertices).isEmpty)
        let topology = FaceMaskTopology(indices: triangles, vertices: vertices)!
        let points = vertices.map { SIMD2($0.x, $0.y) / 5 + SIMD2(repeating: 0.5) }
        let surface = triangles.map { points[Int($0)] }
        try expect(!FaceMaskFixtures.contains(SIMD2(0.5, 0.5), triangles: surface))
        let filled = topology.triangles(projected: points)
        try expect(FaceMaskFixtures.contains(SIMD2(0.5, 0.5), triangles: filled))
        try expect(!FaceMaskFixtures.contains(SIMD2(0.98, 0.5), triangles: filled))
    }

    func testMaskKeepsTheNoseDuringYawAndPitch() throws {
        let topology = FaceMaskTopology(indices: FaceMaskFixtures.indices, vertices: FaceMaskFixtures.vertices)!
        for angle: Float in [-60, -45, -30, 0, 30, 45, 60] {
            for pitch in [false, true] {
                let points = FaceMaskFixtures.projection(yaw: pitch ? 0 : angle, pitch: pitch ? angle : 0)
                let probe = FaceMaskFixtures.noseProbe(points)
                try expect(FaceMaskFixtures.contains(probe, triangles: topology.triangles(projected: points)))
                if abs(angle) >= 45 {
                    // This is the regression: the old outer-boundary fan cuts off the projected nose.
                    try expect(!FaceMaskFixtures.contains(probe, triangles: FaceMaskFixtures.legacyOutline(points)))
                }
            }
        }
    }

    func testMaskProjectionSharesTheCameraCropWithoutReflection() throws {
        var camera = matrix_identity_float4x4
        camera.columns.3 = SIMD4(0, 0, -0.5, 1)
        let vertices: [SIMD3<Float>] = [SIMD3(-0.03, 0.02, 0), SIMD3(0.03, 0.02, 0)]
        let raw = FaceMaskProjection.project(vertices: vertices, cameraFromFace: camera,
            intrinsics: FaceMaskFixtures.intrinsics, imageSize: FaceMaskFixtures.imageSize,
            imageToScreen: matrix_identity_float3x3)
        try expect(simd_distance(raw[0], SIMD2(0.452, 0.46)) < 0.00001)
        try expect(raw[0].x < raw[1].x)
        let portraitCrop = simd_float3x3(SIMD3(0, 1.2, 0), SIMD3(-1.1, 0, 0), SIMD3(1.05, -0.1, 1))
        let cropped = FaceMaskProjection.project(vertices: vertices, cameraFromFace: camera,
            intrinsics: FaceMaskFixtures.intrinsics, imageSize: FaceMaskFixtures.imageSize, imageToScreen: portraitCrop)
        for i in raw.indices {
            let expected = portraitCrop * SIMD3(raw[i], 1)
            try expect(simd_distance(cropped[i], SIMD2(expected.x, expected.y)) < 0.00001)
        }
    }

    func testMaskRejectsInvalidTopologyAndProjection() throws {
        try expectNil(FaceMaskTopology(indices: [0, 1, 99], vertices: FaceMaskFixtures.vertices))
        try expectNil(FaceMaskTopology(indices: [0, 1], vertices: FaceMaskFixtures.vertices))
        try expectNil(FaceMaskTopology(indices: [0, 0, 1], vertices: FaceMaskFixtures.vertices))
        let topology = FaceMaskTopology(indices: FaceMaskFixtures.indices, vertices: FaceMaskFixtures.vertices)!
        try expect(topology.triangles(projected: []).isEmpty)
        var points = FaceMaskFixtures.projection()
        points[0].x = .nan
        try expect(topology.triangles(projected: points).isEmpty)
        let behind = FaceMaskProjection.project(vertices: FaceMaskFixtures.vertices,
            cameraFromFace: matrix_identity_float4x4, intrinsics: FaceMaskFixtures.intrinsics,
            imageSize: FaceMaskFixtures.imageSize, imageToScreen: matrix_identity_float3x3)
        try expect(behind.isEmpty)
    }
}

private struct TestFailure: Error { let line: UInt }
private func expect(_ condition: @autoclosure () -> Bool, line: UInt = #line) throws {
    if !condition() { throw TestFailure(line: line) }
}
private func expectEqual<T: Equatable>(_ a: T, _ b: T, line: UInt = #line) throws { try expect(a == b, line: line) }
private func expectNil<T>(_ value: T?, line: UInt = #line) throws { try expect(value == nil, line: line) }
private func expectNotNil<T>(_ value: T?, line: UInt = #line) throws { try expect(value != nil, line: line) }

@main
struct TestRunner {
    static func main() throws {
        let suite = AvatarMathTests()
        let tests: [(String, () throws -> Void)] = [
            ("fit aligns eye midpoint and meters", suite.testFitAlignsEyeMidpointAndMeters),
            ("fit rejects invalid tracking", suite.testFitRejectsInvalidTrackingMeasurements),
            ("fit requires a continuous neutral second", suite.testCalibrationRequiresAContinuousNeutralSecond),
            ("calibration does not bridge a frame gap", suite.testCalibrationDoesNotBridgeAFrameGap),
            ("blink responds quickly without cross-talk", suite.testFastBlinkDoesNotDriveOtherExpressions),
            ("non-finite expressions stay out of the renderer", suite.testNonFiniteExpressionCannotReachRenderer),
            ("mask fills eye/mouth holes without capping the outer boundary", suite.testMaskFillsHolesWithoutCappingTheOuterBoundary),
            ("3D mask keeps the nose through yaw and pitch", suite.testMaskKeepsTheNoseDuringYawAndPitch),
            ("mask projection shares camera orientation and crop without reflection", suite.testMaskProjectionSharesTheCameraCropWithoutReflection),
            ("invalid mask topology and projection are rejected", suite.testMaskRejectsInvalidTopologyAndProjection),
        ]
        for (name, test) in tests { try test(); print("PASS: " + name) }
        print("\(tests.count) avatar math tests passed.")
    }
}
