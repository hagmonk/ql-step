import AppKit
import Foundation
import SceneKit
import simd

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

/// Physical bounding-box extents of a model, in original STEP units
/// (millimetres) — recovered from a scene's metadata, independent of the
/// on-screen normalization applied to the render mesh.
public struct StepModelBounds: Sendable, Equatable {
    public let dx: Double
    public let dy: Double
    public let dz: Double

    public init(dx: Double, dy: Double, dz: Double) {
        self.dx = dx
        self.dy = dy
        self.dz = dz
    }

    public var maxExtent: Double { Swift.max(dx, Swift.max(dy, dz)) }
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

    /// Physical extents (mm) of a scene produced by this loader, read from the
    /// metadata captured before the render mesh was normalized. Returns nil for
    /// scenes not built by `StepSceneLoader`.
    public static func modelBounds(in scene: SCNScene) -> StepModelBounds? {
        guard let (min, max) = StepSceneMetadata.modelBounds(on: scene.rootNode) else {
            return nil
        }
        return StepModelBounds(
            dx: abs(Double(max.x - min.x)),
            dy: abs(Double(max.y - min.y)),
            dz: abs(Double(max.z - min.z))
        )
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

    private struct MeshBounds {
        let minX: Float
        let minY: Float
        let minZ: Float
        let maxX: Float
        let maxY: Float
        let maxZ: Float

        var centerX: Float { (minX + maxX) / 2 }
        var centerY: Float { (minY + maxY) / 2 }
        var centerZ: Float { (minZ + maxZ) / 2 }
        var sizeX: Float { maxX - minX }
        var sizeY: Float { maxY - minY }
        var sizeZ: Float { maxZ - minZ }
    }

    private struct PartSlice {
        let vertexStart: Int
        let vertexCount: Int
        let triangleStart: Int
        let triangleCount: Int
        let bounds: MeshBounds
    }

    private static func meshBounds(vertices: UnsafePointer<Float>, vertexCount: Int) -> MeshBounds {
        var minX = Float.greatestFiniteMagnitude
        var minY = Float.greatestFiniteMagnitude
        var minZ = Float.greatestFiniteMagnitude
        var maxX = -Float.greatestFiniteMagnitude
        var maxY = -Float.greatestFiniteMagnitude
        var maxZ = -Float.greatestFiniteMagnitude

        for i in 0..<vertexCount {
            let offset = i * 3
            let x = vertices[offset]
            let y = vertices[offset + 1]
            let z = vertices[offset + 2]
            minX = min(minX, x)
            minY = min(minY, y)
            minZ = min(minZ, z)
            maxX = max(maxX, x)
            maxY = max(maxY, y)
            maxZ = max(maxZ, z)
        }

        return MeshBounds(minX: minX, minY: minY, minZ: minZ, maxX: maxX, maxY: maxY, maxZ: maxZ)
    }

    private static func partSlices(from mesh: OcctMesh, vertexCount: Int, triangleCount: Int, bounds: MeshBounds) -> [PartSlice] {
        var slices: [PartSlice] = []
        if let rawParts = mesh.parts, mesh.part_count > 0 {
            for i in 0..<Int(mesh.part_count) {
                let part = rawParts[i]
                let vertexStart = Int(part.vertex_start)
                let partVertexCount = Int(part.vertex_count)
                let triangleStart = Int(part.triangle_start)
                let partTriangleCount = Int(part.triangle_count)
                guard partVertexCount > 0,
                      partTriangleCount > 0,
                      vertexStart >= 0,
                      triangleStart >= 0,
                      vertexStart + partVertexCount <= vertexCount,
                      triangleStart + partTriangleCount <= triangleCount else {
                    continue
                }
                let partBounds = MeshBounds(
                    minX: part.min_x,
                    minY: part.min_y,
                    minZ: part.min_z,
                    maxX: part.max_x,
                    maxY: part.max_y,
                    maxZ: part.max_z
                )
                slices.append(PartSlice(
                    vertexStart: vertexStart,
                    vertexCount: partVertexCount,
                    triangleStart: triangleStart,
                    triangleCount: partTriangleCount,
                    bounds: partBounds
                ))
            }
        }

        if slices.isEmpty {
            slices.append(PartSlice(
                vertexStart: 0,
                vertexCount: vertexCount,
                triangleStart: 0,
                triangleCount: triangleCount,
                bounds: bounds
            ))
        }
        return slices
    }

    private static func vertexSource(
        vertices: UnsafePointer<Float>,
        slice: PartSlice,
        bounds: MeshBounds,
        scaleFactor: Float
    ) -> SCNGeometrySource {
        var out = [Float](repeating: 0, count: slice.vertexCount * 3)
        for i in 0..<slice.vertexCount {
            let sourceOffset = (slice.vertexStart + i) * 3
            let targetOffset = i * 3
            out[targetOffset] = (vertices[sourceOffset] - bounds.centerX) * scaleFactor
            out[targetOffset + 1] = (vertices[sourceOffset + 1] - bounds.centerY) * scaleFactor
            out[targetOffset + 2] = (vertices[sourceOffset + 2] - bounds.centerZ) * scaleFactor
        }

        let data = out.withUnsafeBufferPointer { Data(buffer: $0) }
        return SCNGeometrySource(
            data: data,
            semantic: .vertex,
            vectorCount: slice.vertexCount,
            usesFloatComponents: true,
            componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: 3 * MemoryLayout<Float>.size
        )
    }

    private static func normalSource(normals: UnsafePointer<Float>?, slice: PartSlice) -> SCNGeometrySource? {
        guard let normals else { return nil }
        let byteCount = slice.vertexCount * 3 * MemoryLayout<Float>.size
        let data = Data(bytes: normals.advanced(by: slice.vertexStart * 3), count: byteCount)
        return SCNGeometrySource(
            data: data,
            semantic: .normal,
            vectorCount: slice.vertexCount,
            usesFloatComponents: true,
            componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: 3 * MemoryLayout<Float>.size
        )
    }

    private static func colorSource(
        colors: UnsafePointer<Float>?,
        slice: PartSlice,
        converted: inout [UInt64: (Float, Float, Float)]
    ) -> SCNGeometrySource? {
        guard let raw = colors else { return nil }

        // RGBA, not RGB: the physically-based shader reads a 4-component
        // color; a 3-component source leaves alpha undefined and the model
        // multiplies to black.
        var out = [Float](repeating: 1, count: slice.vertexCount * 4)
        for i in 0..<slice.vertexCount {
            let sourceOffset = (slice.vertexStart + i) * 3
            let r = raw[sourceOffset], g = raw[sourceOffset + 1], b = raw[sourceOffset + 2]
            let key = UInt64(r.bitPattern) << 42 ^ UInt64(g.bitPattern) << 21 ^ UInt64(b.bitPattern)
            let c: (Float, Float, Float)
            if let cached = converted[key] {
                c = cached
            } else {
                c = legibleLinearColor(r, g, b)
                converted[key] = c
            }
            let targetOffset = i * 4
            out[targetOffset] = c.0
            out[targetOffset + 1] = c.1
            out[targetOffset + 2] = c.2
        }

        let data = out.withUnsafeBufferPointer { Data(buffer: $0) }
        return SCNGeometrySource(
            data: data,
            semantic: .color,
            vectorCount: slice.vertexCount,
            usesFloatComponents: true,
            componentsPerVector: 4,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: 4 * MemoryLayout<Float>.size
        )
    }

    private static func geometryElement(triangles: UnsafePointer<UInt32>, slice: PartSlice) -> SCNGeometryElement {
        var indices = [UInt32](repeating: 0, count: slice.triangleCount * 3)
        for i in 0..<indices.count {
            let globalIndex = Int(triangles[slice.triangleStart * 3 + i])
            indices[i] = UInt32(globalIndex - slice.vertexStart)
        }
        let data = indices.withUnsafeBufferPointer { Data(buffer: $0) }
        return SCNGeometryElement(
            data: data,
            primitiveType: .triangles,
            primitiveCount: slice.triangleCount,
            bytesPerIndex: MemoryLayout<UInt32>.size
        )
    }

    private static func material() -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.roughness.contents = 0.55
        material.metalness.contents = 0.05
        material.diffuse.contents = NSColor.white
        material.isDoubleSided = true
        return material
    }

    private static func partCenter(slice: PartSlice, modelBounds: MeshBounds, scaleFactor: Float) -> SCNVector3 {
        SCNVector3(
            (slice.bounds.centerX - modelBounds.centerX) * scaleFactor,
            (slice.bounds.centerY - modelBounds.centerY) * scaleFactor,
            (slice.bounds.centerZ - modelBounds.centerZ) * scaleFactor
        )
    }

    /// Per-part explosion offsets (applied at amount = 1).
    ///
    /// Each part (or group of parts) is exploded along the axis-aligned direction
    /// in which it is *least blocked* by the rest of the assembly — its natural
    /// disassembly direction. This is the standard approach for automatic
    /// exploded views (Li & Agrawala, SIGGRAPH 2008): restrict motion to the
    /// model's axes and pick the direction that frees it with the least travel,
    /// breaking ties toward the part's position relative to the assembly centre.
    /// An end panel slides off its face; a part nested in an open channel lifts
    /// straight out.
    ///
    /// **Repeated small parts explode as a group.** A regular array of identical
    /// parts — IDC contacts, a row of outlets, a set of fasteners — would
    /// otherwise each pick its own radial direction and fan apart, scrambling the
    /// pattern. Instead we cluster identical (same triangle count + bounding box),
    /// nearby, *small* parts and move the whole cluster as one rigid unit, so the
    /// array keeps its arrangement. The "small" test is what keeps two large
    /// identical shell-halves out of a group, so a clamshell still splits.
    ///
    /// The single largest part is held fixed as the anchor (offset zero). A
    /// relaxation pass over the groups removes any residual interpenetration.
    ///
    /// Returns the per-part offsets plus the bounding radius of the fully
    /// exploded assembly, so the camera can be re-framed as the model opens up.
    private static func explosionOffsets(
        slices: [PartSlice],
        modelBounds: MeshBounds,
        scaleFactor: Float,
        radius: Float
    ) -> (offsets: [SCNVector3], explodedRadius: Float) {
        let n = slices.count
        guard n > 1 else { return ([SCNVector3Zero], radius) }

        func size(_ s: PartSlice) -> SIMD3<Float> {
            SIMD3(s.bounds.sizeX, s.bounds.sizeY, s.bounds.sizeZ) * scaleFactor
        }
        let anchor = (0..<n).max {
            let a = size(slices[$0]), b = size(slices[$1])
            return a.x * a.y * a.z < b.x * b.y * b.z
        }!

        func unit(_ axis: Int) -> SIMD3<Float> {
            var v = SIMD3<Float>(0, 0, 0)
            v[axis] = 1
            return v
        }

        // Assembled (centered, scaled) centers, half-extents, and AABBs.
        var baseCenter = [SIMD3<Float>](repeating: .zero, count: n)
        var halfExtent = [SIMD3<Float>](repeating: .zero, count: n)
        for i in 0..<n {
            let c = partCenter(slice: slices[i], modelBounds: modelBounds, scaleFactor: scaleFactor)
            baseCenter[i] = SIMD3<Float>(Float(c.x), Float(c.y), Float(c.z))
            halfExtent[i] = size(slices[i]) * 0.5
        }
        let lo = (0..<n).map { baseCenter[$0] - halfExtent[$0] }
        let hi = (0..<n).map { baseCenter[$0] + halfExtent[$0] }
        let modelExtent = SIMD3<Float>(
            Float(modelBounds.sizeX), Float(modelBounds.sizeY), Float(modelBounds.sizeZ)
        ) * scaleFactor
        let modelMax = max(modelExtent.x, max(modelExtent.y, modelExtent.z))

        // --- Cluster identical, nearby, small parts into rigid groups ----------
        let sortedHalf = (0..<n).map { i -> SIMD3<Float> in
            let h = halfExtent[i]
            let s = [h.x, h.y, h.z].sorted()
            return SIMD3(s[0], s[1], s[2])
        }
        func isSmall(_ i: Int) -> Bool {
            let s = halfExtent[i] * 2
            return max(s.x, max(s.y, s.z)) < modelMax * 0.45
        }
        func sameShape(_ i: Int, _ j: Int) -> Bool {
            guard slices[i].triangleCount == slices[j].triangleCount else { return false }
            let tol = max(modelMax * 0.01, 0.01)
            return simd_length(sortedHalf[i] - sortedHalf[j]) < tol
        }
        func nearby(_ i: Int, _ j: Int) -> Bool {
            var gapSq: Float = 0
            for a in 0..<3 {
                let g = max(0, max(lo[i][a] - hi[j][a], lo[j][a] - hi[i][a]))
                gapSq += g * g
            }
            return gapSq.squareRoot() < max(radius * 0.12, 2)
        }
        var parent = Array(0..<n)
        func find(_ x: Int) -> Int {
            var r = x
            while parent[r] != r { parent[r] = parent[parent[r]]; r = parent[r] }
            return r
        }
        for i in 0..<n where i != anchor {
            for j in (i + 1)..<n where j != anchor {
                if isSmall(i), isSmall(j), sameShape(i, j), nearby(i, j) {
                    parent[find(i)] = find(j)
                }
            }
        }
        var groupMembers: [Int: [Int]] = [:]
        for i in 0..<n { groupMembers[find(i), default: []].append(i) }
        let anchorRoot = find(anchor)

        // --- Per-group escape direction ----------------------------------------
        let spread = max(radius * 0.22, 1)
        let tieTolerance = max(radius * 0.05, 1)
        let epsilon = max(radius * 0.08, 1)

        // How far a box must travel along (axis a, sign s) to clear every part
        // outside `members` that blocks it (projections overlap on the other two
        // axes). Works for a single part or a whole group's union box.
        func escapeDistance(boxLo: SIMD3<Float>, boxHi: SIMD3<Float>,
                            members: Set<Int>, axis a: Int, sign s: Float) -> Float {
            let p1 = (a + 1) % 3, p2 = (a + 2) % 3
            var dist: Float = 0
            for j in 0..<n where !members.contains(j) {
                guard boxLo[p1] < hi[j][p1], lo[j][p1] < boxHi[p1],
                      boxLo[p2] < hi[j][p2], lo[j][p2] < boxHi[p2] else { continue }
                let needed = s > 0 ? hi[j][a] - boxLo[a] : boxHi[a] - lo[j][a]
                dist = max(dist, max(0, needed))
            }
            return dist
        }

        var groupOffset: [Int: SIMD3<Float>] = [:]
        for (root, members) in groupMembers {
            if root == anchorRoot { groupOffset[root] = .zero; continue }
            var gLo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
            var gHi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
            for m in members { gLo = simd_min(gLo, lo[m]); gHi = simd_max(gHi, hi[m]) }
            let memberSet = Set(members)
            let hint = (gLo + gHi) * 0.5
            var bestDistance = Float.greatestFiniteMagnitude
            var bestAlignment = -Float.greatestFiniteMagnitude
            var bestDirection = SIMD3<Float>(0, 0, 0)
            for a in 0..<3 {
                for s in [Float(1), Float(-1)] {
                    let distance = escapeDistance(boxLo: gLo, boxHi: gHi, members: memberSet, axis: a, sign: s)
                    let direction = unit(a) * s
                    let alignment = simd_dot(direction, hint)
                    if distance < bestDistance - tieTolerance
                        || (distance < bestDistance + tieTolerance && alignment > bestAlignment) {
                        bestDistance = min(bestDistance, distance)
                        bestAlignment = alignment
                        bestDirection = direction
                    }
                }
            }
            groupOffset[root] = bestDirection * (bestDistance + spread)
        }

        // --- Relax overlapping groups (whole groups move, so arrays stay rigid) -
        let roots = groupMembers.keys.sorted()
        for _ in 0..<24 {
            var moved = false
            for ai in 0..<roots.count {
                for bi in (ai + 1)..<roots.count {
                    let ra = roots[ai], rb = roots[bi]
                    let offA = groupOffset[ra] ?? .zero, offB = groupOffset[rb] ?? .zero
                    // Worst-overlapping member pair between the two groups.
                    var worstVol: Float = 0
                    var worstPen = SIMD3<Float>(0, 0, 0)
                    var sign: Float = 1
                    for i in groupMembers[ra]! {
                        for j in groupMembers[rb]! {
                            let ca = baseCenter[i] + offA, cb = baseCenter[j] + offB
                            let pen = (halfExtent[i] + halfExtent[j]) - abs(ca - cb)
                            guard pen.x > 0, pen.y > 0, pen.z > 0 else { continue }
                            let vol = pen.x * pen.y * pen.z
                            if vol > worstVol {
                                var k = 0
                                if pen.y < pen.x { k = 1 }
                                if pen.z < pen[k] { k = 2 }
                                worstVol = vol
                                worstPen = pen
                                sign = ca[k] >= cb[k] ? 1 : -1
                            }
                        }
                    }
                    guard worstVol > 0 else { continue }
                    var k = 0
                    if worstPen.y < worstPen.x { k = 1 }
                    if worstPen.z < worstPen[k] { k = 2 }
                    let clear = worstPen[k] + epsilon
                    if ra == anchorRoot {
                        var o = offB; o[k] -= sign * clear; groupOffset[rb] = o
                    } else if rb == anchorRoot {
                        var o = offA; o[k] += sign * clear; groupOffset[ra] = o
                    } else {
                        var oa = offA; oa[k] += sign * clear * 0.5; groupOffset[ra] = oa
                        var ob = offB; ob[k] -= sign * clear * 0.5; groupOffset[rb] = ob
                    }
                    moved = true
                }
            }
            if !moved { break }
        }

        var offsets = [SIMD3<Float>](repeating: .zero, count: n)
        for i in 0..<n { offsets[i] = groupOffset[find(i)] ?? .zero }

        // Bounding radius once fully exploded, so the camera can pull back to
        // keep the opened-up assembly in frame.
        var explodedRadius = radius
        for i in 0..<n {
            let farCorner = abs(baseCenter[i] + offsets[i]) + halfExtent[i]
            explodedRadius = max(explodedRadius, simd_length(farCorner))
        }

        return (offsets.map { SCNVector3($0.x, $0.y, $0.z) }, explodedRadius)
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
        defer { occt_free_mesh(mesh) }

        let vertexCount = Int(mesh.vert_count)
        let triangleCount = Int(mesh.tri_count)
        guard vertexCount > 0,
              triangleCount > 0,
              let vertices = mesh.verts,
              let triangles = mesh.tris else {
            throw StepPreviewKitError.failedToLoadSTEP(source.displayName)
        }

        let bounds = meshBounds(vertices: vertices, vertexCount: vertexCount)
        let maxExtent = max(bounds.sizeX, max(bounds.sizeY, bounds.sizeZ))
        let targetSize: Float = 100.0
        let scaleFactor = maxExtent > 0 ? targetSize / maxExtent : 1
        let radius = sqrtf(bounds.sizeX * bounds.sizeX + bounds.sizeY * bounds.sizeY + bounds.sizeZ * bounds.sizeZ) / 2 * scaleFactor
        let slices = partSlices(from: mesh, vertexCount: vertexCount, triangleCount: triangleCount, bounds: bounds)

        let scene = SCNScene()
        scene.background.contents = StepPreviewAppearance.backgroundColor
        StepSceneMetadata.setModelRadius(radius, on: scene.rootNode)
        // Capture physical (pre-normalization) extents before the mesh is
        // rescaled to `targetSize`; this is the only surviving record of the
        // model's real dimensions in STEP units (mm).
        StepSceneMetadata.setModelBounds(
            min: SCNVector3(bounds.minX, bounds.minY, bounds.minZ),
            max: SCNVector3(bounds.maxX, bounds.maxY, bounds.maxZ),
            on: scene.rootNode
        )

        let modelRoot = SCNNode()
        modelRoot.name = StepSceneMetadata.modelRootName
        scene.rootNode.addChildNode(modelRoot)

        let sharedMaterial = material()
        let explosion = explosionOffsets(
            slices: slices,
            modelBounds: bounds,
            scaleFactor: scaleFactor,
            radius: radius
        )
        let partOffsets = explosion.offsets
        StepSceneMetadata.setExplodedRadius(explosion.explodedRadius, on: scene.rootNode)
        var convertedColors: [UInt64: (Float, Float, Float)] = [:]
        for (index, slice) in slices.enumerated() {
            var sources = [
                vertexSource(
                    vertices: vertices,
                    slice: slice,
                    bounds: bounds,
                    scaleFactor: scaleFactor
                )
            ]
            if let normals = normalSource(normals: mesh.normals, slice: slice) {
                sources.append(normals)
            }
            if let colors = colorSource(colors: mesh.colors, slice: slice, converted: &convertedColors) {
                sources.append(colors)
            }

            let geometry = SCNGeometry(
                sources: sources,
                elements: [geometryElement(triangles: triangles, slice: slice)]
            )
            geometry.firstMaterial = sharedMaterial

            let node = SCNNode(geometry: geometry)
            node.name = "step-part-\(index)"
            node.castsShadow = false
            StepSceneMetadata.setExplosion(
                basePosition: SCNVector3Zero,
                offset: partOffsets[index],
                on: node
            )
            modelRoot.addChildNode(node)
        }

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
