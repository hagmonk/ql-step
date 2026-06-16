import SceneKit
import SwiftUI

public struct StepPreviewView: NSViewRepresentable {
    public var scene: SCNScene?

    public init(scene: SCNScene?) {
        self.scene = scene
    }

    public static func configure(_ scnView: SCNView) {
        scnView.allowsCameraControl = true
        scnView.autoresizingMask = [.width, .height]
        scnView.backgroundColor = .clear
        scnView.preferredFramesPerSecond = 60
        scnView.antialiasingMode = .multisampling4X
        scnView.autoenablesDefaultLighting = false
    }

    public static func display(_ scene: SCNScene?, in scnView: SCNView) {
        scnView.scene = scene
        scnView.pointOfView = scene?.rootNode.childNode(withName: "camera", recursively: true)
    }

    public func makeNSView(context: Context) -> SCNView {
        let scnView = SCNView()
        Self.configure(scnView)
        return scnView
    }

    public func updateNSView(_ nsView: SCNView, context: Context) {
        Self.display(scene, in: nsView)
    }
}
