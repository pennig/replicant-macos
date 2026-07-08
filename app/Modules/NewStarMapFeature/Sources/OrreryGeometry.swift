import CStarMapShaderTypes
import simd

// Geometry for the system-focus orrery: a shared unit sphere (scaled per body),
// the flat scaffold (orbit rings, habitable-zone band, kuiper ring) as colored
// world-space line segments, and the asteroid belt as an additive point ring.
// Pure and deterministic — unit-testable. Scene units map ≈ 1:1 to the map's
// light-year world, positioned around the focused star (`center`).

enum OrreryGeometry {

    // Scaffold colours (approximating the design tokens the SceneKit orrery used).
    private static let orbitColor = SIMD4<Float>(0.55, 0.58, 0.66, 0.5)
    private static let kuiperColor = SIMD4<Float>(0.50, 0.55, 0.70, 0.28)
    private static let hzColor = SIMD4<Float>(0.40, 0.82, 0.55, 0.5)
    private static let beltColor = SIMD3<Float>(0.90, 0.72, 0.42)

    /// A unit sphere (radius 1) as indexed triangles. On a unit sphere the normal
    /// equals the position, so it survives the per-body uniform scale + translate.
    /// Built once and reused for the sun and every planet.
    static func unitSphere(rings: Int = 18, sectors: Int = 28) -> (vertices: [OrreryMeshVertex], indices: [UInt16]) {
        var verts: [OrreryMeshVertex] = []
        verts.reserveCapacity((rings + 1) * (sectors + 1))
        for r in 0...rings {
            let phi = Float.pi * Float(r) / Float(rings)
            let y = cos(phi), ring = sin(phi)
            for s in 0...sectors {
                let theta = 2 * Float.pi * Float(s) / Float(sectors)
                let p = SIMD3<Float>(ring * cos(theta), y, ring * sin(theta))
                verts.append(OrreryMeshVertex(position: p, normal: p))
            }
        }
        var indices: [UInt16] = []
        let cols = sectors + 1
        for r in 0..<rings {
            for s in 0..<sectors {
                let a = UInt16(r * cols + s)
                let b = UInt16(r * cols + s + 1)
                let c = UInt16((r + 1) * cols + s)
                let d = UInt16((r + 1) * cols + s + 1)
                indices.append(contentsOf: [a, c, b, b, c, d])
            }
        }
        return (verts, indices)
    }

    /// Orbit rings (one per planet), the kuiper ring, and the habitable-zone band
    /// (inner + outer edge) as world-space colored line-segment pairs. `scale`
    /// converts orrery scene units to world (light-year) units around `center`.
    static func scaffoldLines(model: SystemModel, center: SIMD3<Float>, scale: Float, segments: Int = 128) -> [OrreryLineVertex] {
        var verts: [OrreryLineVertex] = []

        func addRing(radius sceneRadius: Double, color: SIMD4<Float>) {
            let radius = Float(sceneRadius) * scale
            var prev = center + SIMD3<Float>(radius, 0, 0)
            for i in 1...segments {
                let a = 2 * Float.pi * Float(i) / Float(segments)
                let p = center + SIMD3<Float>(cos(a) * radius, 0, sin(a) * radius)
                verts.append(OrreryLineVertex(position: SIMD4(prev, 1), color: color))
                verts.append(OrreryLineVertex(position: SIMD4(p, 1), color: color))
                prev = p
            }
        }

        for planet in model.planets { addRing(radius: planet.semiMajorScene, color: orbitColor) }
        if let kuiper = model.kuiperScene { addRing(radius: kuiper, color: kuiperColor) }
        if let inner = model.hzInnerScene { addRing(radius: inner, color: hzColor) }
        if let outer = model.hzOuterScene { addRing(radius: outer, color: hzColor) }
        return verts
    }

    /// The asteroid belt(s) as a deterministic world-space additive point ring.
    /// Reuses `AmbientVertex` (position+size / color+brightness). `scale` as above.
    static func beltPoints(model: SystemModel, center: SIMD3<Float>, scale: Float, countPerBelt: Int = 260) -> [AmbientVertex] {
        var rng = SeededLCG(seed: 0xBE17)
        var pts: [AmbientVertex] = []
        pts.reserveCapacity(model.belts.count * countPerBelt)
        for belt in model.belts {
            let inner = belt.innerScene, outer = belt.outerScene
            for _ in 0..<countPerBelt {
                let r = (inner + rng.next() * (outer - inner)) * Double(scale)
                let a = rng.next(in: 0...(2 * .pi))
                let y = (rng.next() - 0.5) * 0.8 * Double(scale)
                let p = center + SIMD3<Float>(Float(cos(a) * r), Float(y), Float(sin(a) * r))
                let brightness = Float(rng.next(in: 0.3...0.85))
                pts.append(AmbientVertex(positionSize: SIMD4(p, 2.0), color: SIMD4(beltColor, brightness)))
            }
        }
        return pts
    }

    /// Parse "#rrggbb" → 0…1 rgb (gamma handling left to the tone-map).
    static func rgb(hex: String) -> SIMD3<Float> {
        var s = Substring(hex)
        if s.first == "#" { s = s.dropFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return SIMD3(1, 1, 1) }
        return SIMD3(Float((v >> 16) & 0xFF), Float((v >> 8) & 0xFF), Float(v & 0xFF)) / 255
    }
}
