import AppKit
import ObjectiveC
import SceneKit
import simd
import SwiftUI

public enum StepPreviewAppearance {
    public static let backgroundColor = NSColor(calibratedWhite: 0.055, alpha: 1)
}

enum StepSceneMetadata {
    static let modelRootName = "step-model-root"

    nonisolated(unsafe) private static var modelRadiusKey: UInt8 = 0
    nonisolated(unsafe) private static var explosionBasePositionKey: UInt8 = 0
    nonisolated(unsafe) private static var explosionOffsetKey: UInt8 = 0

    static func setModelRadius(_ radius: Float, on node: SCNNode) {
        objc_setAssociatedObject(
            node,
            &modelRadiusKey,
            NSNumber(value: radius),
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }

    static func modelRadius(on node: SCNNode) -> Float? {
        (objc_getAssociatedObject(node, &modelRadiusKey) as? NSNumber)?.floatValue
    }

    static func setExplosion(basePosition: SCNVector3, offset: SCNVector3, on node: SCNNode) {
        objc_setAssociatedObject(
            node,
            &explosionBasePositionKey,
            NSValue(scnVector3: basePosition),
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
        objc_setAssociatedObject(
            node,
            &explosionOffsetKey,
            NSValue(scnVector3: offset),
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }

    static func explosion(on node: SCNNode) -> (basePosition: SCNVector3, offset: SCNVector3)? {
        guard let base = objc_getAssociatedObject(node, &explosionBasePositionKey) as? NSValue,
              let offset = objc_getAssociatedObject(node, &explosionOffsetKey) as? NSValue else {
            return nil
        }
        return (base.scnVector3Value, offset.scnVector3Value)
    }
}

@MainActor
final class StepOrbitCameraRig {
    private(set) var target = SIMD3<Float>.zero
    private(set) var distance: Float = 1
    private(set) var accumulatedPitchRadians: Float = 0
    private var rotation = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))

    func reset(cameraNode: SCNNode, modelRadius: Float, fieldOfView: CGFloat) {
        let fovRadians = max(Float(fieldOfView) * .pi / 360.0, 0.001)
        let axisDistance = max(modelRadius / tanf(fovRadians), 1)
        let position = SIMD3<Float>(axisDistance, axisDistance, axisDistance)

        target = .zero
        distance = max(simd_length(position), 1)
        accumulatedPitchRadians = 0
        rotation = Self.lookAtRotation(
            position: position,
            target: target,
            worldUp: SIMD3<Float>(0, 1, 0)
        )
        apply(to: cameraNode)
    }

    func orbitBy(yawRadians: Float, pitchRadians: Float, cameraNode: SCNNode) {
        guard yawRadians.isFinite, pitchRadians.isFinite else { return }
        let yaw = simd_quatf(angle: yawRadians, axis: SIMD3<Float>(0, 1, 0))
        let pitch = simd_quatf(angle: pitchRadians, axis: SIMD3<Float>(1, 0, 0))
        rotation = simd_normalize(yaw * rotation * pitch)
        accumulatedPitchRadians += pitchRadians
        apply(to: cameraNode)
    }

    func panBy(screenDeltaX dx: Float, screenDeltaY dy: Float, cameraNode: SCNNode) {
        guard dx.isFinite, dy.isFinite else { return }
        let scale = max(distance, 1) * 0.0015
        let right = rotation.act(SIMD3<Float>(1, 0, 0))
        let up = rotation.act(SIMD3<Float>(0, 1, 0))
        target += right * (-dx * scale) + up * (dy * scale)
        apply(to: cameraNode)
    }

    func dollyBy(screenDelta delta: Float, cameraNode: SCNNode) {
        guard delta.isFinite else { return }
        distance = max(distance * expf(delta * 0.01), 0.1)
        apply(to: cameraNode)
    }

    func magnify(by magnification: Float, cameraNode: SCNNode) {
        guard magnification.isFinite else { return }
        distance = max(distance * expf(-magnification * 2.5), 0.1)
        apply(to: cameraNode)
    }

    func rollBy(rotationRadians: Float, cameraNode: SCNNode) {
        guard rotationRadians.isFinite else { return }
        let roll = simd_quatf(angle: rotationRadians, axis: SIMD3<Float>(0, 0, 1))
        rotation = simd_normalize(rotation * roll)
        apply(to: cameraNode)
    }

    func apply(to cameraNode: SCNNode) {
        cameraNode.simdPosition = target + rotation.act(SIMD3<Float>(0, 0, distance))
        cameraNode.simdOrientation = rotation
    }

    private static func lookAtRotation(
        position: SIMD3<Float>,
        target: SIMD3<Float>,
        worldUp: SIMD3<Float>
    ) -> simd_quatf {
        let forward = simd_normalize(target - position)
        var right = simd_cross(forward, worldUp)
        if simd_length_squared(right) < 0.000001 {
            right = simd_cross(forward, SIMD3<Float>(0, 0, 1))
        }
        right = simd_normalize(right)
        let up = simd_normalize(simd_cross(right, forward))
        let localZ = -forward
        return simd_quatf(simd_float3x3(columns: (right, up, localZ)))
    }
}

@MainActor
private final class StepPreviewGestureTarget: NSObject {
    static let shared = StepPreviewGestureTarget()

    @objc func resetCamera(_ gesture: NSClickGestureRecognizer) {
        guard gesture.state == .ended, let view = gesture.view as? SCNView else { return }
        StepPreviewView.resetCamera(in: view)
    }
}

public final class StepPreviewSceneView: SCNView {
    private let cameraRig = StepOrbitCameraRig()
    private var activeDragLocation: CGPoint?
    private var activeDragButton: Int?

    var cameraRigForTesting: StepOrbitCameraRig { cameraRig }

    public override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            StepPreviewView.resetCamera(in: self)
            return
        }
        beginDrag(with: event, button: 0)
    }

    public override func mouseDragged(with event: NSEvent) {
        drag(with: event, button: 0)
    }

    public override func mouseUp(with event: NSEvent) {
        endDrag(button: 0)
    }

    public override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else {
            super.otherMouseDown(with: event)
            return
        }
        beginDrag(with: event, button: event.buttonNumber)
    }

    public override func otherMouseDragged(with event: NSEvent) {
        guard event.buttonNumber == 2 else {
            super.otherMouseDragged(with: event)
            return
        }
        drag(with: event, button: event.buttonNumber)
    }

    public override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2 {
            endDrag(button: event.buttonNumber)
        } else {
            super.otherMouseUp(with: event)
        }
    }

    public override func scrollWheel(with event: NSEvent) {
        guard let cameraNode = pointOfView else {
            super.scrollWheel(with: event)
            return
        }
        handleScroll(
            deltaX: Float(event.scrollingDeltaX),
            deltaY: Float(event.scrollingDeltaY),
            hasPreciseScrollingDeltas: event.hasPreciseScrollingDeltas,
            modifierFlags: event.modifierFlags,
            cameraNode: cameraNode
        )
    }

    func handleScroll(
        deltaX: Float,
        deltaY: Float,
        hasPreciseScrollingDeltas: Bool,
        modifierFlags: NSEvent.ModifierFlags,
        cameraNode: SCNNode
    ) {
        if modifierFlags.contains(.control) || modifierFlags.contains(.option) {
            cameraRig.dollyBy(screenDelta: deltaY, cameraNode: cameraNode)
        } else if hasPreciseScrollingDeltas {
            cameraRig.panBy(
                screenDeltaX: deltaX,
                screenDeltaY: deltaY,
                cameraNode: cameraNode
            )
        } else {
            cameraRig.dollyBy(screenDelta: deltaY, cameraNode: cameraNode)
        }
    }

    func handleDrag(
        deltaX dx: Float,
        deltaY dy: Float,
        modifierFlags: NSEvent.ModifierFlags,
        cameraNode: SCNNode
    ) {
        if modifierFlags.contains(.shift) {
            cameraRig.panBy(screenDeltaX: dx, screenDeltaY: dy, cameraNode: cameraNode)
        } else if modifierFlags.contains(.control) || modifierFlags.contains(.option) {
            cameraRig.dollyBy(screenDelta: dy, cameraNode: cameraNode)
        } else {
            let radiansPerPoint = Float.pi / 180.0 * 0.35
            cameraRig.orbitBy(
                yawRadians: -dx * radiansPerPoint,
                pitchRadians: dy * radiansPerPoint,
                cameraNode: cameraNode
            )
        }
    }

    public override func magnify(with event: NSEvent) {
        guard let cameraNode = pointOfView else {
            super.magnify(with: event)
            return
        }
        cameraRig.magnify(by: Float(event.magnification), cameraNode: cameraNode)
    }

    public override func rotate(with event: NSEvent) {
        guard let cameraNode = pointOfView else {
            super.rotate(with: event)
            return
        }
        cameraRig.rollBy(rotationRadians: Float(event.rotation) * .pi / 180.0, cameraNode: cameraNode)
    }

    func resetCameraRig() {
        guard let scene, let cameraNode = scene.rootNode.childNode(withName: "camera", recursively: true) else {
            return
        }
        guard let camera = cameraNode.camera else {
            pointOfView = cameraNode
            return
        }
        cameraRig.reset(
            cameraNode: cameraNode,
            modelRadius: StepPreviewView.modelRadius(in: scene),
            fieldOfView: camera.fieldOfView
        )
        pointOfView = cameraNode
    }

    private func beginDrag(with event: NSEvent, button: Int) {
        activeDragButton = button
        activeDragLocation = convert(event.locationInWindow, from: nil)
    }

    private func drag(with event: NSEvent, button: Int) {
        guard activeDragButton == button, let previous = activeDragLocation, let cameraNode = pointOfView else {
            return
        }

        let location = convert(event.locationInWindow, from: nil)
        let dx = Float(location.x - previous.x)
        let dy = Float(location.y - previous.y)
        activeDragLocation = location

        handleDrag(deltaX: dx, deltaY: dy, modifierFlags: event.modifierFlags, cameraNode: cameraNode)
    }

    private func endDrag(button: Int) {
        if activeDragButton == button {
            activeDragButton = nil
            activeDragLocation = nil
        }
    }
}

public final class StepPreviewContainerView: NSView {
    public let sceneView: StepPreviewSceneView

    private let explosionControlsView: NSVisualEffectView
    private let explodeSlider: NSSlider

    public var showsExplosionControls: Bool = true {
        didSet {
            updateExplosionControlsVisibility()
        }
    }

    public var scene: SCNScene? {
        sceneView.scene
    }

    public var explosionAmount: Float {
        get {
            explodeSlider.floatValue
        }
        set {
            setExplosionAmount(newValue)
        }
    }

    var isExplosionControlsVisible: Bool {
        !explosionControlsView.isHidden
    }

    public override init(frame frameRect: NSRect) {
        sceneView = StepPreviewSceneView(frame: .zero)
        explosionControlsView = NSVisualEffectView()
        explodeSlider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
        super.init(frame: frameRect)
        commonInit()
    }

    public required init?(coder: NSCoder) {
        sceneView = StepPreviewSceneView(frame: .zero)
        explosionControlsView = NSVisualEffectView()
        explodeSlider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
        super.init(coder: coder)
        commonInit()
    }

    public func display(_ scene: SCNScene?) {
        StepPreviewView.display(scene, in: sceneView)
        setExplosionAmount(0)
        updateExplosionControlsVisibility()
    }

    public func resetCamera() {
        StepPreviewView.resetCamera(in: sceneView)
    }

    public func setExplosionAmount(_ amount: Float) {
        let clamped = min(max(amount, 0), 1)
        if abs(explodeSlider.floatValue - clamped) > 0.0001 {
            explodeSlider.floatValue = clamped
        }
        StepPreviewView.setExplosionAmount(clamped, in: sceneView)
    }

    private func commonInit() {
        StepPreviewView.configure(sceneView)

        sceneView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(sceneView)

        NSLayoutConstraint.activate([
            sceneView.leadingAnchor.constraint(equalTo: leadingAnchor),
            sceneView.trailingAnchor.constraint(equalTo: trailingAnchor),
            sceneView.topAnchor.constraint(equalTo: topAnchor),
            sceneView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        addExplosionControls()
        updateExplosionControlsVisibility()
    }

    private func addExplosionControls() {
        explosionControlsView.material = .hudWindow
        explosionControlsView.blendingMode = .withinWindow
        explosionControlsView.state = .active
        explosionControlsView.translatesAutoresizingMaskIntoConstraints = false
        explosionControlsView.isHidden = true
        explosionControlsView.wantsLayer = true
        explosionControlsView.layer?.cornerRadius = 6

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: "Explode")
        label.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .labelColor

        explodeSlider.controlSize = .small
        explodeSlider.target = self
        explodeSlider.action = #selector(explosionSliderChanged(_:))
        explodeSlider.translatesAutoresizingMaskIntoConstraints = false
        explodeSlider.widthAnchor.constraint(equalToConstant: 120).isActive = true

        stack.addArrangedSubview(label)
        stack.addArrangedSubview(explodeSlider)
        explosionControlsView.addSubview(stack)
        addSubview(explosionControlsView)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: explosionControlsView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: explosionControlsView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: explosionControlsView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: explosionControlsView.bottomAnchor),
            explosionControlsView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            explosionControlsView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10)
        ])
    }

    private func updateExplosionControlsVisibility() {
        let shouldShow = showsExplosionControls && StepPreviewView.canExplode(sceneView.scene)
        explosionControlsView.isHidden = !shouldShow
        explodeSlider.isEnabled = shouldShow
        if !shouldShow {
            setExplosionAmount(0)
        }
    }

    @objc private func explosionSliderChanged(_ sender: NSSlider) {
        StepPreviewView.setExplosionAmount(sender.floatValue, in: sceneView)
    }
}

public struct StepPreviewView: NSViewRepresentable {
    public var scene: SCNScene?
    public var explosionAmount: Float
    public var showsExplosionControls: Bool

    public init(
        scene: SCNScene?,
        explosionAmount: Float = 0,
        showsExplosionControls: Bool = true
    ) {
        self.scene = scene
        self.explosionAmount = explosionAmount
        self.showsExplosionControls = showsExplosionControls
    }

    public static func configure(_ scnView: SCNView) {
        scnView.allowsCameraControl = false
        scnView.autoresizingMask = [.width, .height]
        scnView.backgroundColor = StepPreviewAppearance.backgroundColor
        scnView.preferredFramesPerSecond = 60
        scnView.antialiasingMode = .multisampling4X
        scnView.autoenablesDefaultLighting = false
        if scnView.gestureRecognizers.isEmpty {
            let resetGesture = NSClickGestureRecognizer(
                target: StepPreviewGestureTarget.shared,
                action: #selector(StepPreviewGestureTarget.resetCamera(_:))
            )
            resetGesture.numberOfClicksRequired = 2
            resetGesture.buttonMask = 0x1
            scnView.addGestureRecognizer(resetGesture)
        }
    }

    public static func configuredSceneView(frame: NSRect = .zero) -> SCNView {
        let scnView = StepPreviewSceneView(frame: frame)
        configure(scnView)
        return scnView
    }

    @discardableResult
    public static func replaceWithConfiguredSceneView(_ scnView: SCNView) -> SCNView {
        if scnView is StepPreviewSceneView {
            configure(scnView)
            return scnView
        }

        let replacement = configuredSceneView(frame: scnView.frame)
        replacement.autoresizingMask = scnView.autoresizingMask
        replacement.translatesAutoresizingMaskIntoConstraints = scnView.translatesAutoresizingMaskIntoConstraints
        if let superview = scnView.superview {
            superview.replaceSubview(scnView, with: replacement)
        }
        return replacement
    }

    public static func display(_ scene: SCNScene?, in scnView: SCNView) {
        scnView.scene = scene
        resetCamera(in: scnView)
    }

    public static func resetCamera(in scnView: SCNView) {
        if let stepView = scnView as? StepPreviewSceneView {
            stepView.resetCameraRig()
            return
        }

        let cameraNode = scnView.scene?.rootNode.childNode(withName: "camera", recursively: true)
        if let scene = scnView.scene, let cameraNode {
            reset(cameraNode, in: scene)
        }
        scnView.pointOfView = cameraNode
    }

    public static func setExplosionAmount(_ amount: Float, in scnView: SCNView) {
        setExplosionAmount(amount, in: scnView.scene)
    }

    nonisolated public static func canExplode(_ scene: SCNScene?) -> Bool {
        guard let modelRoot = scene?.rootNode.childNode(withName: StepSceneMetadata.modelRootName, recursively: false),
              modelRoot.childNodes.count > 1 else {
            return false
        }

        return modelRoot.childNodes.contains { node in
            guard let offset = StepSceneMetadata.explosion(on: node)?.offset else {
                return false
            }
            let x = Float(offset.x)
            let y = Float(offset.y)
            let z = Float(offset.z)
            return sqrtf(x * x + y * y + z * z) > 0.001
        }
    }

    nonisolated public static func setExplosionAmount(_ amount: Float, in scene: SCNScene?) {
        guard let modelRoot = scene?.rootNode.childNode(withName: StepSceneMetadata.modelRootName, recursively: false) else {
            return
        }

        let clamped = CGFloat(min(max(amount, 0), 1))
        for node in modelRoot.childNodes {
            guard let explosion = StepSceneMetadata.explosion(on: node) else {
                continue
            }
            let basePosition = explosion.basePosition
            let explosionOffset = explosion.offset
            node.position = SCNVector3(
                basePosition.x + explosionOffset.x * clamped,
                basePosition.y + explosionOffset.y * clamped,
                basePosition.z + explosionOffset.z * clamped
            )
        }
    }

    nonisolated static func modelRadius(in scene: SCNScene) -> Float {
        if let radius = StepSceneMetadata.modelRadius(on: scene.rootNode) {
            return max(radius, 1)
        }

        var radius: Float = 50.0
        scene.rootNode.enumerateChildNodes { node, _ in
            guard node.geometry != nil else { return }

            let (minBounds, maxBounds) = node.boundingBox
            let corners = [
                SCNVector3(minBounds.x, minBounds.y, minBounds.z),
                SCNVector3(minBounds.x, minBounds.y, maxBounds.z),
                SCNVector3(minBounds.x, maxBounds.y, minBounds.z),
                SCNVector3(minBounds.x, maxBounds.y, maxBounds.z),
                SCNVector3(maxBounds.x, minBounds.y, minBounds.z),
                SCNVector3(maxBounds.x, minBounds.y, maxBounds.z),
                SCNVector3(maxBounds.x, maxBounds.y, minBounds.z),
                SCNVector3(maxBounds.x, maxBounds.y, maxBounds.z)
            ]

            for corner in corners {
                let world = node.convertPosition(corner, to: scene.rootNode)
                let dx = Float(world.x)
                let dy = Float(world.y)
                let dz = Float(world.z)
                let distance = sqrtf(dx * dx + dy * dy + dz * dz)
                radius = Swift.max(radius, distance)
            }
        }

        return radius
    }

    private static func reset(_ cameraNode: SCNNode, in scene: SCNScene) {
        guard let camera = cameraNode.camera else { return }
        let rig = StepOrbitCameraRig()
        rig.reset(
            cameraNode: cameraNode,
            modelRadius: modelRadius(in: scene),
            fieldOfView: camera.fieldOfView
        )
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    public func makeNSView(context: Context) -> StepPreviewContainerView {
        let view = StepPreviewContainerView(frame: .zero)
        view.showsExplosionControls = showsExplosionControls
        view.display(scene)
        view.setExplosionAmount(explosionAmount)
        context.coordinator.displayedScene = scene
        context.coordinator.appliedExplosionAmount = explosionAmount
        return view
    }

    public func updateNSView(_ nsView: StepPreviewContainerView, context: Context) {
        nsView.showsExplosionControls = showsExplosionControls
        if context.coordinator.displayedScene !== scene {
            nsView.display(scene)
            context.coordinator.displayedScene = scene
            context.coordinator.appliedExplosionAmount = nil
        }
        if context.coordinator.appliedExplosionAmount != explosionAmount {
            nsView.setExplosionAmount(explosionAmount)
            context.coordinator.appliedExplosionAmount = explosionAmount
        }
    }

    public final class Coordinator {
        var displayedScene: SCNScene?
        var appliedExplosionAmount: Float?
    }
}
