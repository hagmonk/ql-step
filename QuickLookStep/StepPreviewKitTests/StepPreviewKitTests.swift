import AppKit
import Foundation
import SceneKit
import XCTest
@testable import StepPreviewKit

final class StepPreviewKitTests: XCTestCase {
    func testFixtureLoadsFromFile() throws {
        let scene = try StepSceneLoader.scene(fromFileAt: try fixtureURL())

        assertLoadedScene(scene)
    }

    func testFixtureLoadsFromMemory() throws {
        let url = try fixtureURL()
        let data = try Data(contentsOf: url)

        let scene = try StepSceneLoader.scene(from: data, name: url.lastPathComponent)

        assertLoadedScene(scene)
    }

    func testFixtureRendersThumbnail() throws {
        let image = try StepThumbnailRenderer.cgImage(
            fromFileAt: try fixtureURL(),
            pixelSize: CGSize(width: 128, height: 128)
        )

        XCTAssertEqual(image.width, 128)
        XCTAssertEqual(image.height, 128)
    }

    func testFastPreviewUsesCoarserMesh() throws {
        let url = try fixtureURL()
        let defaultScene = try StepSceneLoader.scene(fromFileAt: url)
        let fastScene = try StepSceneLoader.scene(fromFileAt: url, options: .fastPreview)

        XCTAssertLessThan(primitiveCount(in: fastScene), primitiveCount(in: defaultScene))
    }

    @MainActor
    func testSceneViewConfigurationDisablesImplicitLighting() {
        let view = SCNView()
        let minimumVerticalAngle = view.defaultCameraController.minimumVerticalAngle
        let maximumVerticalAngle = view.defaultCameraController.maximumVerticalAngle

        StepPreviewView.configure(view)

        XCTAssertFalse(view.allowsCameraControl)
        XCTAssertEqual(view.antialiasingMode, .multisampling4X)
        XCTAssertFalse(view.autoenablesDefaultLighting)
        XCTAssertEqual(view.backgroundColor, StepPreviewAppearance.backgroundColor)
        XCTAssertFalse(view.gestureRecognizers.isEmpty)
        XCTAssertEqual(view.defaultCameraController.minimumVerticalAngle, minimumVerticalAngle)
        XCTAssertEqual(view.defaultCameraController.maximumVerticalAngle, maximumVerticalAngle)
    }

    @MainActor
    func testSceneViewDisplayUsesSceneCamera() {
        let scene = SCNScene()
        let cameraNode = SCNNode()
        cameraNode.name = "camera"
        cameraNode.camera = SCNCamera()
        scene.rootNode.addChildNode(cameraNode)
        let view = SCNView()

        StepPreviewView.display(scene, in: view)

        XCTAssertTrue(view.scene === scene)
        XCTAssertTrue(view.pointOfView === cameraNode)
    }

    @MainActor
    func testSceneViewReplacementUsesSharedConfiguredSubclass() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let original = SCNView(frame: container.bounds)
        container.addSubview(original)

        let replacement = StepPreviewView.replaceWithConfiguredSceneView(original)

        XCTAssertTrue(replacement is StepPreviewSceneView)
        XCTAssertTrue(replacement.superview === container)
        XCTAssertFalse(original.superview === container)
        XCTAssertEqual(replacement.backgroundColor, StepPreviewAppearance.backgroundColor)
        XCTAssertFalse(replacement.allowsCameraControl)
    }

    @MainActor
    func testPreviewContainerViewOwnsSharedExplosionControls() {
        let view = StepPreviewContainerView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        let singlePartScene = syntheticScene(partOffsets: [SCNVector3Zero])

        view.display(singlePartScene)

        XCTAssertTrue(view.scene === singlePartScene)
        XCTAssertFalse(view.sceneView.allowsCameraControl)
        XCTAssertFalse(view.isExplosionControlsVisible)
        XCTAssertEqual(view.explosionAmount, 0, accuracy: 0.0001)

        let multiPartScene = syntheticScene(partOffsets: [
            SCNVector3(10, 0, 0),
            SCNVector3(-10, 0, 0)
        ])
        view.display(multiPartScene)

        XCTAssertTrue(view.isExplosionControlsVisible)
        view.setExplosionAmount(1)
        XCTAssertEqual(view.explosionAmount, 1, accuracy: 0.0001)
        XCTAssertEqual(partNodes(in: multiPartScene).first?.position.x ?? 0, 10, accuracy: 0.0001)

        view.showsExplosionControls = false

        XCTAssertFalse(view.isExplosionControlsVisible)
        XCTAssertEqual(view.explosionAmount, 0, accuracy: 0.0001)
        XCTAssertEqual(partNodes(in: multiPartScene).first?.position.x ?? 0, 0, accuracy: 0.0001)
    }

    @MainActor
    func testCameraResetRestoresDefaultSceneCameraPosition() throws {
        let scene = try StepSceneLoader.scene(fromFileAt: try fixtureURL())
        let cameraNode = try XCTUnwrap(scene.rootNode.childNode(withName: "camera", recursively: true))
        let initialPosition = cameraNode.position

        let view = StepPreviewView.configuredSceneView()
        StepPreviewView.display(scene, in: view)
        cameraNode.position = SCNVector3(-1, -2, -3)

        StepPreviewView.resetCamera(in: view)

        XCTAssertEqual(cameraNode.position.x, initialPosition.x, accuracy: 0.0001)
        XCTAssertEqual(cameraNode.position.y, initialPosition.y, accuracy: 0.0001)
        XCTAssertEqual(cameraNode.position.z, initialPosition.z, accuracy: 0.0001)
        XCTAssertTrue(view.pointOfView === cameraNode)
    }

    @MainActor
    func testOrbitCameraRigAllowsPitchBeyondFullRotation() {
        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        let rig = StepOrbitCameraRig()
        rig.reset(cameraNode: cameraNode, modelRadius: 50, fieldOfView: 45)

        rig.orbitBy(yawRadians: 0, pitchRadians: Float.pi * 2.25, cameraNode: cameraNode)

        XCTAssertGreaterThan(abs(rig.accumulatedPitchRadians), Float.pi * 2)
        XCTAssertTrue(cameraNode.position.x.isFinite)
        XCTAssertTrue(cameraNode.position.y.isFinite)
        XCTAssertTrue(cameraNode.position.z.isFinite)
    }

    @MainActor
    func testOrbitCameraRigResetRestoresCameraAfterMovement() {
        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        let rig = StepOrbitCameraRig()
        rig.reset(cameraNode: cameraNode, modelRadius: 50, fieldOfView: 45)
        let initialPosition = cameraNode.position

        rig.orbitBy(yawRadians: 0.7, pitchRadians: 1.3, cameraNode: cameraNode)
        rig.panBy(screenDeltaX: 80, screenDeltaY: -20, cameraNode: cameraNode)
        rig.dollyBy(screenDelta: 35, cameraNode: cameraNode)
        rig.reset(cameraNode: cameraNode, modelRadius: 50, fieldOfView: 45)

        XCTAssertEqual(cameraNode.position.x, initialPosition.x, accuracy: 0.0001)
        XCTAssertEqual(cameraNode.position.y, initialPosition.y, accuracy: 0.0001)
        XCTAssertEqual(cameraNode.position.z, initialPosition.z, accuracy: 0.0001)
        XCTAssertEqual(rig.accumulatedPitchRadians, 0, accuracy: 0.0001)
    }

    @MainActor
    func testOrbitCameraRigMagnifyZoomsCameraDistance() {
        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        let rig = StepOrbitCameraRig()
        rig.reset(cameraNode: cameraNode, modelRadius: 50, fieldOfView: 45)
        let initialDistance = rig.distance

        rig.magnify(by: 0.2, cameraNode: cameraNode)
        let zoomedInDistance = rig.distance
        rig.magnify(by: -0.2, cameraNode: cameraNode)

        XCTAssertLessThan(zoomedInDistance, initialDistance)
        XCTAssertGreaterThan(rig.distance, zoomedInDistance)
    }

    @MainActor
    func testOrbitCameraRigRollRotatesWithoutChangingDistance() {
        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        let rig = StepOrbitCameraRig()
        rig.reset(cameraNode: cameraNode, modelRadius: 50, fieldOfView: 45)
        let initialPosition = cameraNode.position
        let initialOrientation = cameraNode.simdOrientation

        rig.rollBy(rotationRadians: 0.5, cameraNode: cameraNode)

        XCTAssertEqual(cameraNode.position.x, initialPosition.x, accuracy: 0.0001)
        XCTAssertEqual(cameraNode.position.y, initialPosition.y, accuracy: 0.0001)
        XCTAssertEqual(cameraNode.position.z, initialPosition.z, accuracy: 0.0001)
        XCTAssertNotEqual(cameraNode.simdOrientation.vector.z, initialOrientation.vector.z)
    }

    @MainActor
    func testPrimaryDragUpAndDownUseExpectedOrbitDirections() {
        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        let view = StepPreviewView.configuredSceneView() as! StepPreviewSceneView

        view.cameraRigForTesting.reset(cameraNode: cameraNode, modelRadius: 50, fieldOfView: 45)
        view.handleDrag(deltaX: 0, deltaY: 20, modifierFlags: [], cameraNode: cameraNode)
        let upwardPitch = view.cameraRigForTesting.accumulatedPitchRadians

        view.cameraRigForTesting.reset(cameraNode: cameraNode, modelRadius: 50, fieldOfView: 45)
        view.handleDrag(deltaX: 0, deltaY: -20, modifierFlags: [], cameraNode: cameraNode)
        let downwardPitch = view.cameraRigForTesting.accumulatedPitchRadians

        XCTAssertGreaterThan(upwardPitch, 0)
        XCTAssertLessThan(downwardPitch, 0)
    }

    @MainActor
    func testPreciseScrollPansWhileMouseWheelDollies() {
        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        let view = StepPreviewView.configuredSceneView() as! StepPreviewSceneView
        view.cameraRigForTesting.reset(cameraNode: cameraNode, modelRadius: 50, fieldOfView: 45)
        let initialTarget = view.cameraRigForTesting.target
        let initialDistance = view.cameraRigForTesting.distance

        view.handleScroll(
            deltaX: 18,
            deltaY: -12,
            hasPreciseScrollingDeltas: true,
            modifierFlags: [],
            cameraNode: cameraNode
        )

        XCTAssertEqual(view.cameraRigForTesting.distance, initialDistance, accuracy: 0.0001)
        XCTAssertNotEqual(view.cameraRigForTesting.target.x, initialTarget.x)
        XCTAssertNotEqual(view.cameraRigForTesting.target.y, initialTarget.y)

        view.handleScroll(
            deltaX: 0,
            deltaY: 12,
            hasPreciseScrollingDeltas: false,
            modifierFlags: [],
            cameraNode: cameraNode
        )

        XCTAssertNotEqual(view.cameraRigForTesting.distance, initialDistance)
    }

    func testSceneContainsModelRootWithPartNodes() throws {
        let scene = try StepSceneLoader.scene(fromFileAt: try fixtureURL())
        let root = try XCTUnwrap(modelRoot(in: scene))
        let parts = partNodes(in: scene)

        XCTAssertFalse(parts.isEmpty)
        XCTAssertEqual(root.childNodes.count, parts.count)
        XCTAssertTrue(parts.allSatisfy { $0.geometry != nil })
    }

    func testExplodeAvailabilityRequiresMultipleExplodableParts() throws {
        let scene = try StepSceneLoader.scene(fromFileAt: try fixtureURL())
        XCTAssertEqual(StepPreviewView.canExplode(scene), partNodes(in: scene).count > 1)

        let singlePartScene = SCNScene()
        let root = SCNNode()
        root.name = StepSceneMetadata.modelRootName
        let part = SCNNode()
        StepSceneMetadata.setExplosion(
            basePosition: SCNVector3Zero,
            offset: SCNVector3(0, 0, 0),
            on: part
        )
        root.addChildNode(part)
        singlePartScene.rootNode.addChildNode(root)

        XCTAssertFalse(StepPreviewView.canExplode(singlePartScene))
    }

    func testExplosionAmountZeroLeavesPartNodesAtBasePositions() throws {
        let scene = try StepSceneLoader.scene(fromFileAt: try fixtureURL())
        let parts = partNodes(in: scene)
        let basePositions = parts.map(\.position)

        StepPreviewView.setExplosionAmount(0, in: scene)

        for (node, basePosition) in zip(parts, basePositions) {
            assertEqual(node.position, basePosition)
        }
    }

    func testExplosionAmountMovesMultipartNodesWithoutChangingPrimitiveCounts() throws {
        let scene = try StepSceneLoader.scene(fromFileAt: try fixtureURL())
        let parts = partNodes(in: scene)
        let primitiveCountBefore = primitiveCount(in: scene)

        StepPreviewView.setExplosionAmount(1, in: scene)

        XCTAssertEqual(primitiveCount(in: scene), primitiveCountBefore)
        let moved = parts.contains { length($0.position) > 0.001 }
        XCTAssertEqual(moved, parts.count > 1)
    }

    func testThumbnailRenderingClearsExplodedState() throws {
        let scene = try StepSceneLoader.scene(fromFileAt: try fixtureURL())
        StepPreviewView.setExplosionAmount(1, in: scene)

        _ = try StepThumbnailRenderer.cgImage(for: scene, pixelSize: CGSize(width: 64, height: 64))

        for node in partNodes(in: scene) {
            assertEqual(node.position, SCNVector3Zero)
        }
    }

    func testInvalidMemoryInputThrows() {
        let data = Data("not a step file".utf8)

        XCTAssertThrowsError(try StepSceneLoader.scene(from: data, name: "invalid.step")) { error in
            XCTAssertTrue(error is StepPreviewKitError)
        }
    }

    func testMissingFileThrows() {
        let missingURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("missing-\(UUID().uuidString).step")

        XCTAssertThrowsError(try StepSceneLoader.scene(fromFileAt: missingURL)) { error in
            XCTAssertTrue(error is StepPreviewKitError)
        }
    }

    private func fixtureURL(file: StaticString = #filePath, line: UInt = #line) throws -> URL {
        // Under SwiftPM, `.copy("Fixtures")` resources live in Bundle.module;
        // under the Xcode test target they're in the test bundle itself.
        #if SWIFT_PACKAGE
        if let url = Bundle.module.url(forResource: "178CT", withExtension: "stp", subdirectory: "Fixtures")
            ?? Bundle.module.url(forResource: "178CT", withExtension: "stp") {
            return url
        }
        #endif
        let bundle = Bundle(for: Self.self)
        if let url = bundle.url(forResource: "178CT", withExtension: "stp", subdirectory: "Fixtures") {
            return url
        }
        return try XCTUnwrap(
            bundle.url(forResource: "178CT", withExtension: "stp"),
            "Missing 178CT STEP fixture",
            file: file,
            line: line
        )
    }

    private func assertLoadedScene(_ scene: SCNScene, file: StaticString = #filePath, line: UInt = #line) {
        let geometryNodes = scene.rootNode.childNodes(passingTest: { node, _ in
            node.geometry != nil
        })
        let vertexCount = geometryNodes.reduce(0) { count, node in
            count + (node.geometry?.sources(for: .vertex).first?.vectorCount ?? 0)
        }
        let normalCount = geometryNodes.reduce(0) { count, node in
            count + (node.geometry?.sources(for: .normal).first?.vectorCount ?? 0)
        }
        let camera = scene.rootNode.childNode(withName: "camera", recursively: true)?.camera
        let f3dLights = scene.rootNode.childNodes(passingTest: { node, _ in
            node.light != nil && node.name?.hasPrefix("f3d-") == true
        })
        let shadowLights = scene.rootNode.childNodes(passingTest: { node, _ in
            node.light?.castsShadow == true
        })

        XCTAssertFalse(geometryNodes.isEmpty, file: file, line: line)
        XCTAssertGreaterThan(vertexCount, 0, file: file, line: line)
        XCTAssertEqual(normalCount, vertexCount, file: file, line: line)
        XCTAssertGreaterThan(primitiveCount(in: scene), 0, file: file, line: line)
        XCTAssertNotNil(camera, file: file, line: line)
        XCTAssertGreaterThan(camera?.screenSpaceAmbientOcclusionIntensity ?? 0, 0, file: file, line: line)
        XCTAssertEqual(scene.background.contents as? NSColor, StepPreviewAppearance.backgroundColor, file: file, line: line)
        XCTAssertEqual(f3dLights.count, 5, file: file, line: line)
        XCTAssertTrue(geometryNodes.allSatisfy { !$0.castsShadow }, file: file, line: line)
        XCTAssertTrue(shadowLights.isEmpty, file: file, line: line)
    }

    private func modelRoot(in scene: SCNScene) -> SCNNode? {
        scene.rootNode.childNode(withName: StepSceneMetadata.modelRootName, recursively: false)
    }

    private func partNodes(in scene: SCNScene) -> [SCNNode] {
        modelRoot(in: scene)?.childNodes.filter { $0.geometry != nil } ?? []
    }

    private func syntheticScene(partOffsets: [SCNVector3]) -> SCNScene {
        let scene = SCNScene()
        StepSceneMetadata.setModelRadius(50, on: scene.rootNode)

        let root = SCNNode()
        root.name = StepSceneMetadata.modelRootName
        for offset in partOffsets {
            let part = SCNNode()
            part.geometry = SCNSphere(radius: 1)
            StepSceneMetadata.setExplosion(basePosition: SCNVector3Zero, offset: offset, on: part)
            root.addChildNode(part)
        }
        scene.rootNode.addChildNode(root)

        let cameraNode = SCNNode()
        cameraNode.name = "camera"
        cameraNode.camera = SCNCamera()
        scene.rootNode.addChildNode(cameraNode)

        return scene
    }

    private func length(_ vector: SCNVector3) -> Float {
        let x = Float(vector.x)
        let y = Float(vector.y)
        let z = Float(vector.z)
        return sqrtf(x * x + y * y + z * z)
    }

    private func assertEqual(
        _ lhs: SCNVector3,
        _ rhs: SCNVector3,
        accuracy: CGFloat = 0.0001,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(lhs.x, rhs.x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(lhs.y, rhs.y, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(lhs.z, rhs.z, accuracy: accuracy, file: file, line: line)
    }

    private func primitiveCount(in scene: SCNScene) -> Int {
        scene.rootNode
            .childNodes(passingTest: { node, _ in node.geometry != nil })
            .reduce(0) { count, node in
                count + (node.geometry?.elements.reduce(0) { $0 + $1.primitiveCount } ?? 0)
            }
    }
}
