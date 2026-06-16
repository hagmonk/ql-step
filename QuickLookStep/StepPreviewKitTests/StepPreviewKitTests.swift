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

        StepPreviewView.configure(view)

        XCTAssertTrue(view.allowsCameraControl)
        XCTAssertEqual(view.antialiasingMode, .multisampling4X)
        XCTAssertFalse(view.autoenablesDefaultLighting)
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
        XCTAssertEqual(f3dLights.count, 5, file: file, line: line)
        XCTAssertTrue(geometryNodes.allSatisfy { !$0.castsShadow }, file: file, line: line)
        XCTAssertTrue(shadowLights.isEmpty, file: file, line: line)
    }

    private func primitiveCount(in scene: SCNScene) -> Int {
        scene.rootNode
            .childNodes(passingTest: { node, _ in node.geometry != nil })
            .reduce(0) { count, node in
                count + (node.geometry?.elements.reduce(0) { $0 + $1.primitiveCount } ?? 0)
            }
    }
}
