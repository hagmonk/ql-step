import AppKit
import Foundation
import SceneKit

// Under SwiftPM the OCCT bridge is a C module; under the Xcode build the same
// symbols arrive via Shared-Bridging-Header.h, where this module doesn't exist.
#if canImport(COcctBridge)
import COcctBridge
#endif

public enum StepPreviewKitError: Error, LocalizedError {
    case failedToLoadSTEP(String)
    case snapshotFailed

    public var errorDescription: String? {
        switch self {
        case .failedToLoadSTEP(let source):
            return "Failed to load STEP file: \(source)"
        case .snapshotFailed:
            return "Failed to render STEP thumbnail"
        }
    }
}

public enum StepSceneLoader {
    public struct Options: Sendable, Equatable {
        public var linearDeflection: Double
        public var angularDeflection: Double
        public var relativeDeflection: Bool
        public var parallelMeshing: Bool

        public init(
            linearDeflection: Double = 0.1,
            angularDeflection: Double = 0.5,
            relativeDeflection: Bool = false,
            parallelMeshing: Bool = true
        ) {
            self.linearDeflection = linearDeflection
            self.angularDeflection = angularDeflection
            self.relativeDeflection = relativeDeflection
            self.parallelMeshing = parallelMeshing
        }

        public static let `default` = Options()

        /// Coarser tessellation for dense browser/canvas use, where load time
        /// and triangle count matter more than close-up edge smoothness.
        public static let fastPreview = Options(linearDeflection: 0.5, angularDeflection: 1.0)

        fileprivate var occtOptions: OcctLoadOptions {
            OcctLoadOptions(
                linear_deflection: linearDeflection,
                angular_deflection: angularDeflection,
                relative_deflection: relativeDeflection,
                parallel_meshing: parallelMeshing
            )
        }
    }

    public static func scene(
        fromFileAt url: URL,
        options: Options = .default
    ) throws -> SCNScene {
        try StepSceneBuilder.scene(from: .file(url), options: options)
    }

    public static func scene(
        from data: Data,
        name: String = "memory.step",
        options: Options = .default
    ) throws -> SCNScene {
        try StepSceneBuilder.scene(from: .data(data, name: name), options: options)
    }
}

private enum StepSceneSource {
    case file(URL)
    case data(Data, name: String)

    var displayName: String {
        switch self {
        case .file(let url):
            return url.path
        case .data(_, let name):
            return name
        }
    }
}

/// Converts STEP input into a ready-to-render `SCNScene`, preserving the same
/// camera, material, and lighting setup for previews and thumbnails.
private enum StepSceneBuilder {
    private static let shouldLogLoads = ProcessInfo.processInfo.environment["QLSTEP_LOG_LOADS"] != nil

    private struct F3DLightSpec {
        let name: String
        let cameraLocalPosition: SCNVector3
        let color: NSColor
        let intensity: CGFloat
    }

    private static let f3dLightTargetPosition = SCNVector3(0, 0, -1)

    // F3D creates VTK's default vtkLightKit when no scene lights are present:
    // a headlight, key light, fill light, and two back lights. VTK camera
    // lights live in normalized camera space where the camera is at (0,0,1)
    // looking at the origin, matching SceneKit camera-local -Z after z-1.
    private static let f3dLightKit: [F3DLightSpec] = {
        let scale: CGFloat = 1000
        let neutral = NSColor(calibratedRed: 0.9998, green: 0.9998, blue: 0.9998, alpha: 1)
        return [
            F3DLightSpec(
                name: "f3d-head-light",
                cameraLocalPosition: SCNVector3Zero,
                color: neutral,
                intensity: 0.75 / 3.0 * scale
            ),
            F3DLightSpec(
                name: "f3d-key-light",
                cameraLocalPosition: cameraLocalPosition(elevation: 50.0, azimuth: 10.0),
                color: NSColor(calibratedRed: 1.0, green: 0.97232, blue: 0.90222, alpha: 1),
                intensity: 0.75 * scale
            ),
            F3DLightSpec(
                name: "f3d-fill-light",
                cameraLocalPosition: cameraLocalPosition(elevation: -75.0, azimuth: -10.0),
                color: NSColor(calibratedRed: 0.90824, green: 0.93314, blue: 1.0, alpha: 1),
                intensity: 0.75 / 3.0 * scale
            ),
            F3DLightSpec(
                name: "f3d-back-light-left",
                cameraLocalPosition: cameraLocalPosition(elevation: 0.0, azimuth: 110.0),
                color: neutral,
                intensity: 0.75 / 3.5 * scale
            ),
            F3DLightSpec(
                name: "f3d-back-light-right",
                cameraLocalPosition: cameraLocalPosition(elevation: 0.0, azimuth: -110.0),
                color: neutral,
                intensity: 0.75 / 3.5 * scale
            )
        ]
    }()

    // MARK: - OKLab color handling

    private static func cameraLocalPosition(elevation: Double, azimuth: Double) -> SCNVector3 {
        let elevationRadians = elevation * .pi / 180.0
        let azimuthRadians = azimuth * .pi / 180.0
        let x = cos(elevationRadians) * sin(azimuthRadians)
        let y = sin(elevationRadians)
        let z = cos(elevationRadians) * cos(azimuthRadians)
        return SCNVector3(Float(x), Float(y), Float(z - 1.0))
    }

    private static func softClampLightness(_ L: Float) -> Float {
        if L < 0.30 { return 0.12 + (L / 0.30) * 0.18 }
        if L > 0.85 { return 0.85 + ((L - 0.85) / 0.15) * 0.05 }
        return L
    }

    /// sRGB -> OKLab, per https://bottosson.github.io/posts/oklab/
    private static func srgbToOKLab(_ r: Float, _ g: Float, _ b: Float) -> (L: Float, a: Float, b: Float) {
        func toLinear(_ c: Float) -> Float {
            c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let lr = toLinear(r), lg = toLinear(g), lb = toLinear(b)

        let l = cbrt(0.4122214708 * lr + 0.5363325363 * lg + 0.0514459929 * lb)
        let m = cbrt(0.2119034982 * lr + 0.6806995451 * lg + 0.1073969566 * lb)
        let s = cbrt(0.0883024619 * lr + 0.2817188376 * lg + 0.6299787005 * lb)

        return (0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }

    /// OKLab -> linear sRGB. SceneKit expects linear components in raw vertex
    /// data; it only color-matches NSColor/CGColor inputs.
    private static func oklabToLinearSRGB(_ L: Float, _ a: Float, _ b: Float) -> (r: Float, g: Float, b: Float) {
        let l3 = L + 0.3963377774 * a + 0.2158037573 * b
        let m3 = L - 0.1055613458 * a - 0.0638541728 * b
        let s3 = L - 0.0894841775 * a - 1.2914855480 * b
        let l = l3 * l3 * l3, m = m3 * m3 * m3, s = s3 * s3 * s3

        func clamp01(_ c: Float) -> Float { min(max(c, 0), 1) }
        return (clamp01( 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
                clamp01(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
                clamp01(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s))
    }

    private static func legibleLinearColor(_ r: Float, _ g: Float, _ b: Float) -> (Float, Float, Float) {
        let lab = srgbToOKLab(r, g, b)
        return oklabToLinearSRGB(softClampLightness(lab.L), lab.a, lab.b)
    }

    private static func colorSource(from mesh: OcctMesh, vertexCount: Int) -> SCNGeometrySource? {
        guard let raw = mesh.colors else { return nil }
        defer { occt_free_float_buffer(raw) }

        // RGBA, not RGB: the physically-based shader reads a 4-component
        // color; a 3-component source leaves alpha undefined and the model
        // multiplies to black.
        var converted: [UInt64: (Float, Float, Float)] = [:]
        var out = [Float](repeating: 1, count: vertexCount * 4)
        for i in 0..<vertexCount {
            let r = raw[i * 3], g = raw[i * 3 + 1], b = raw[i * 3 + 2]
            let key = UInt64(r.bitPattern) << 42 ^ UInt64(g.bitPattern) << 21 ^ UInt64(b.bitPattern)
            let c: (Float, Float, Float)
            if let cached = converted[key] {
                c = cached
            } else {
                c = legibleLinearColor(r, g, b)
                converted[key] = c
            }
            out[i * 4] = c.0
            out[i * 4 + 1] = c.1
            out[i * 4 + 2] = c.2
        }

        let data = out.withUnsafeBufferPointer { Data(buffer: $0) }
        return SCNGeometrySource(
            data: data,
            semantic: .color,
            vectorCount: vertexCount,
            usesFloatComponents: true,
            componentsPerVector: 4,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: 4 * MemoryLayout<Float>.size
        )
    }

    private static func normalSource(from mesh: OcctMesh, vertexCount: Int) -> SCNGeometrySource? {
        guard let normals = mesh.normals else { return nil }
        let byteCount = vertexCount * 3 * MemoryLayout<Float>.size
        let data = Data(
            bytesNoCopy: UnsafeMutableRawPointer(mutating: normals),
            count: byteCount,
            deallocator: .custom { pointer, _ in
                occt_free_float_buffer(pointer.assumingMemoryBound(to: Float.self))
            }
        )
        return SCNGeometrySource(
            data: data,
            semantic: .normal,
            vectorCount: vertexCount,
            usesFloatComponents: true,
            componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: 3 * MemoryLayout<Float>.size
        )
    }

    static func scene(from source: StepSceneSource, options: StepSceneLoader.Options) throws -> SCNScene {
        var mesh = OcctMesh()
        let start = CFAbsoluteTimeGetCurrent()
        let ok: Bool
        var occtOptions = options.occtOptions

        switch source {
        case .file(let url):
            ok = withUnsafePointer(to: &occtOptions) { optionsPointer in
                url.path.withCString { cPath in
                    occt_load_step_with_options(cPath, optionsPointer, &mesh)
                }
            }
        case .data(let data, let name):
            ok = withUnsafePointer(to: &occtOptions) { optionsPointer in
                data.withUnsafeBytes { bytes in
                    name.withCString { cName in
                        occt_load_step_data_with_options(
                            bytes.baseAddress,
                            bytes.count,
                            cName,
                            optionsPointer,
                            &mesh
                        )
                    }
                }
            }
        }

        let elapsedMs = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
        if shouldLogLoads {
            NSLog("STEP load(%@) -> %@ in %.2f ms", source.displayName, ok ? "OK" : "FAIL", elapsedMs)
        }
        guard ok else {
            throw StepPreviewKitError.failedToLoadSTEP(source.displayName)
        }

        let vertexCount = Int(mesh.vert_count)
        let indexCount = Int(mesh.tri_count) * 3

        let vertexByteCount = vertexCount * 3 * MemoryLayout<Float>.size
        let vertexData = Data(
            bytesNoCopy: UnsafeMutableRawPointer(mutating: mesh.verts!),
            count: vertexByteCount,
            deallocator: .custom { pointer, _ in
                occt_free_float_buffer(pointer.assumingMemoryBound(to: Float.self))
            }
        )
        let vertexSource = SCNGeometrySource(
            data: vertexData,
            semantic: .vertex,
            vectorCount: vertexCount,
            usesFloatComponents: true,
            componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: 3 * MemoryLayout<Float>.size
        )

        let indexByteCount = indexCount * MemoryLayout<UInt32>.size
        let indexData = Data(
            bytesNoCopy: UnsafeMutableRawPointer(mutating: mesh.tris!),
            count: indexByteCount,
            deallocator: .custom { pointer, _ in
                occt_free_uint32_buffer(pointer.assumingMemoryBound(to: UInt32.self))
            }
        )
        let geometryElement = SCNGeometryElement(
            data: indexData,
            primitiveType: .triangles,
            primitiveCount: Int(mesh.tri_count),
            bytesPerIndex: MemoryLayout<UInt32>.size
        )

        var sources = [vertexSource]
        if let normals = normalSource(from: mesh, vertexCount: vertexCount) {
            sources.append(normals)
        }
        if let colors = colorSource(from: mesh, vertexCount: vertexCount) {
            sources.append(colors)
        }

        let geometry = SCNGeometry(sources: sources, elements: [geometryElement])
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.roughness.contents = 0.55
        material.metalness.contents = 0.05
        material.diffuse.contents = NSColor.white
        material.isDoubleSided = true
        geometry.firstMaterial = material

        let scene = SCNScene()
        let node = SCNNode(geometry: geometry)
        node.castsShadow = false
        scene.rootNode.addChildNode(node)

        let (minBounds, maxBounds) = node.boundingBox
        let size = SCNVector3(
            maxBounds.x - minBounds.x,
            maxBounds.y - minBounds.y,
            maxBounds.z - minBounds.z
        )

        let targetSize: CGFloat = 100.0
        let maxExtent = max(size.x, max(size.y, size.z))
        let scaleFactor = targetSize / maxExtent
        let sf = Float(scaleFactor)
        node.scale = SCNVector3(sf, sf, sf)

        let center = SCNVector3(
            (maxBounds.x + minBounds.x) / 2.0,
            (maxBounds.y + minBounds.y) / 2.0,
            (maxBounds.z + minBounds.z) / 2.0
        )
        node.position = SCNVector3(Float(-center.x * scaleFactor),
                                   Float(-center.y * scaleFactor),
                                   Float(-center.z * scaleFactor))

        let cameraNode = SCNNode()
        cameraNode.name = "camera"
        let camera = SCNCamera()
        camera.zNear = 1
        camera.zFar = 10000
        camera.fieldOfView = 45
        camera.screenSpaceAmbientOcclusionIntensity = 1.15
        camera.screenSpaceAmbientOcclusionRadius = 8.0
        camera.screenSpaceAmbientOcclusionBias = 0.03
        camera.screenSpaceAmbientOcclusionDepthThreshold = 0.20
        camera.screenSpaceAmbientOcclusionNormalThreshold = 0.25
        cameraNode.camera = camera

        let sx = Float(size.x), sy = Float(size.y), sz = Float(size.z)
        let radius = (sqrt(sx*sx + sy*sy + sz*sz) / 2.0) * sf
        let fovRadians = (Float(camera.fieldOfView) / 2.0) * (.pi / 180.0)
        let distance = radius / tanf(fovRadians)

        cameraNode.position = SCNVector3(distance, distance, distance)
        cameraNode.look(at: SCNVector3Zero)
        scene.rootNode.addChildNode(cameraNode)

        addF3DLightKit(to: cameraNode)

        return scene
    }

    private static func addF3DLightKit(to cameraNode: SCNNode) {
        let targetNode = SCNNode()
        targetNode.name = "f3d-light-target"
        targetNode.position = f3dLightTargetPosition
        cameraNode.addChildNode(targetNode)

        for spec in f3dLightKit {
            let light = SCNLight()
            light.type = .directional
            light.color = spec.color
            light.intensity = spec.intensity
            light.castsShadow = false

            let lightNode = SCNNode()
            lightNode.name = spec.name
            lightNode.position = spec.cameraLocalPosition
            lightNode.light = light

            let constraint = SCNLookAtConstraint(target: targetNode)
            constraint.isGimbalLockEnabled = true
            lightNode.constraints = [constraint]
            cameraNode.addChildNode(lightNode)
        }
    }
}
