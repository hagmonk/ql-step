import AppKit
import Metal
import SceneKit

public enum StepThumbnailRenderer {
    public static func cgImage(
        for scene: SCNScene,
        pixelSize: CGSize,
        time: TimeInterval = 0,
        antialiasingMode: SCNAntialiasingMode = .multisampling4X
    ) throws -> CGImage {
        StepPreviewView.setExplosionAmount(0, in: scene)

        let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
        renderer.scene = scene
        renderer.pointOfView = scene.rootNode.childNode(withName: "camera", recursively: true)

        let image = renderer.snapshot(atTime: time, with: pixelSize, antialiasingMode: antialiasingMode)
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw StepPreviewKitError.snapshotFailed
        }
        return cgImage
    }

    public static func cgImage(
        fromFileAt url: URL,
        pixelSize: CGSize,
        options: StepSceneLoader.Options = .default
    ) throws -> CGImage {
        try cgImage(for: StepSceneLoader.scene(fromFileAt: url, options: options), pixelSize: pixelSize)
    }

    public static func cgImage(
        from data: Data,
        name: String = "memory.step",
        pixelSize: CGSize,
        options: StepSceneLoader.Options = .default
    ) throws -> CGImage {
        try cgImage(for: StepSceneLoader.scene(from: data, name: name, options: options), pixelSize: pixelSize)
    }
}
