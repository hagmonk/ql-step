import SceneKit
import Cocoa
import Quartz


/// A tiny helper that converts a STEP file into a ready-to-render `SCNScene`,
/// replicating the same camera and lighting configuration we use in the preview
/// extension so thumbnails and previews look identical before any user
/// interaction.
enum SceneBuilder {

    // MARK: - OKLab color handling

    /// OKLab lightness stays faithful to the file across the midrange —
    /// exposure is the lighting rig's job, not the albedo's — and is only
    /// compressed at the extremes so true black stays barely visible against
    /// a dark Quick Look panel and pure-white powder-coat stays visible
    /// against a light Finder background.
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

    /// OKLab -> linear sRGB (SceneKit expects linear components in raw vertex
    /// data; it only color-matches NSColor/CGColor inputs).
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

    /// Remaps one STEP body color into legible lightness, keeping hue and
    /// chroma. Input is sRGB-encoded (STEP COLOUR_RGB convention), output is
    /// linear for the GPU.
    private static func legibleLinearColor(_ r: Float, _ g: Float, _ b: Float) -> (Float, Float, Float) {
        let lab = srgbToOKLab(r, g, b)
        return oklabToLinearSRGB(softClampLightness(lab.L), lab.a, lab.b)
    }

    /// Builds the per-vertex color buffer for SceneKit from the raw bridge
    /// colors, deduplicating the conversion since STEP files style whole
    /// bodies (a handful of unique colors across the whole mesh).
    private static func colorSource(from mesh: OcctMesh, vertexCount: Int) -> SCNGeometrySource? {
        guard let raw = mesh.colors else { return nil }

        // RGBA, not RGB: the physically-based shader reads a 4-component
        // color; a 3-component source leaves alpha undefined (zero) and the
        // whole model multiplies to black.
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

    /// Builds a SceneKit scene containing the geometry loaded from the STEP
    /// file at `url`.
    /// - Throws: An `NSError` if the STEP file cannot be parsed by the Rust
    ///           backend.
    static func scene(for url: URL) throws -> SCNScene {
        // --- Load via the OpenCascade bridge and measure duration ---
        var mesh = OcctMesh()
        let start = CFAbsoluteTimeGetCurrent()
        let ok = url.path.withCString { cPath in
            occt_load_step(cPath, &mesh)
        }
        let elapsedMs = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
        NSLog("occt_load_step(%@) -> %@ in %.2f ms", url.path, ok ? "OK" : "FAIL", elapsedMs)
        guard ok else {
            throw NSError(
                domain: "SceneBuilder",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to load STEP file"]
            )
        }
        defer { occt_free_mesh(mesh) }

        // Build SceneKit geometry from the raw buffers.
        let vertexCount = Int(mesh.vert_count)
        let indexCount = Int(mesh.tri_count) * 3

        let vertexData = Data(
            bytes: mesh.verts!,
            count: vertexCount * 3 * MemoryLayout<Float>.size
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

        let indexData = Data(
            bytes: mesh.tris!,
            count: indexCount * MemoryLayout<UInt32>.size
        )
        let geometryElement = SCNGeometryElement(
            data: indexData,
            primitiveType: .triangles,
            primitiveCount: Int(mesh.tri_count),
            bytesPerIndex: MemoryLayout<UInt32>.size
        )

        var sources = [vertexSource]
        if let colors = colorSource(from: mesh, vertexCount: vertexCount) {
            sources.append(colors)
        }

        let geometry = SCNGeometry(sources: sources, elements: [geometryElement])
        let material = SCNMaterial()
        // PBR + image-based lighting (below) keeps every orientation lit the
        // way f3d's environment lighting does — point lights alone plunge
        // faces into shadow as soon as the user orbits the model.
        material.lightingModel = .physicallyBased
        material.roughness.contents = 0.55
        material.metalness.contents = 0.05
        // Vertex colors modulate diffuse; white keeps them unscaled.
        material.diffuse.contents = NSColor.white
        material.isDoubleSided = true
        geometry.firstMaterial = material

        // Assemble the scene graph.
        let scene = SCNScene()
        let node = SCNNode(geometry: geometry)
        scene.rootNode.addChildNode(node)

        // --- Scale & centre geometry ---
        let (minBounds, maxBounds) = node.boundingBox
        let size = SCNVector3(
            maxBounds.x - minBounds.x,
            maxBounds.y - minBounds.y,
            maxBounds.z - minBounds.z
        )

        // Uniformly scale so the largest dimension maps to `targetSize` units.
        let targetSize: CGFloat = 100.0
        let maxExtent = max(size.x, max(size.y, size.z))
        let scaleFactor = targetSize / maxExtent
        let sf = Float(scaleFactor)
        node.scale = SCNVector3(sf, sf, sf)

        // Re-centre so model origin is at (0,0,0)
        let center = SCNVector3(
            (maxBounds.x + minBounds.x) / 2.0,
            (maxBounds.y + minBounds.y) / 2.0,
            (maxBounds.z + minBounds.z) / 2.0
        )
        node.position = SCNVector3(Float(-center.x * scaleFactor),
                                   Float(-center.y * scaleFactor),
                                   Float(-center.z * scaleFactor))

        // --- Camera setup ---
        let cameraNode = SCNNode()
        cameraNode.name = "camera"
        let camera = SCNCamera()
        camera.zNear = 1
        camera.zFar = 10000
        camera.fieldOfView = 45
        cameraNode.camera = camera

        // Place camera so the entire bounding sphere fits inside the view.
        let sx = Float(size.x), sy = Float(size.y), sz = Float(size.z)
        let radius = (sqrt(sx*sx + sy*sy + sz*sz) / 2.0) * sf
        let fovRadians = (Float(camera.fieldOfView) / 2.0) * (.pi / 180.0)
        let distance = radius / tanf(fovRadians)

        // Use a diagonal viewing direction for depth.
        cameraNode.position = SCNVector3(distance, distance, distance)
        cameraNode.look(at: SCNVector3Zero)
        scene.rootNode.addChildNode(cameraNode)

        // --- Lighting ---
        // Studio-dome image-based lighting: bright zenith, mid horizon, dark
        // ground. Lights every orientation coherently (rotating the model in
        // the preview can't plunge a face into blackness) and gives the same
        // tonal range f3d's environment lighting produces. A modest key omni
        // at the camera adds definition on top.
        if let environment = studioEnvironment() {
            scene.lightingEnvironment.contents = environment
            scene.lightingEnvironment.intensity = 1.2
        }
        // Directional headlight: PBR treats omni intensity as lumens with
        // inverse-square falloff, so a camera-distance omni contributes
        // nothing; directional lights don't attenuate (intensity = lux).
        let keyNode = SCNNode()
        keyNode.light = SCNLight()
        keyNode.light?.type = .directional
        keyNode.light?.intensity = 700
        keyNode.position = cameraNode.position
        keyNode.look(at: SCNVector3Zero)
        scene.rootNode.addChildNode(keyNode)

        return scene
    }

    /// Vertical gray gradient used as the lighting environment — a cheap
    /// procedural studio dome. Drawn with CoreGraphics directly: AppKit's
    /// lockFocus path has no graphics context inside the sandboxed headless
    /// thumbnail extension and yields a dead (black) environment texture.
    private static func studioEnvironment() -> CGImage? {
        // 2:1 aspect — SceneKit only accepts equirectangular environment
        // textures with this ratio and silently ignores anything else
        let width = 256, height = 128
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        for y in 0..<height {
            // bottom row = ground (dark), top row = zenith (bright)
            let t = CGFloat(y) / CGFloat(height - 1)
            let white = 0.18 + t * (1.00 - 0.18)
            ctx.setFillColor(CGColor(gray: white, alpha: 1))
            ctx.fill(CGRect(x: 0, y: y, width: width, height: 1))
        }
        return ctx.makeImage()
    }
}
