import CStarMapShaderTypes
import Foundation
import simd

// Nebula generation — the reworked interstellar medium. Where the old `AmbientField`
// scattered fixed-pixel point sprites (which read as a conglomeration of dots), this
// builds soft, depth-projected WORLD-SPACE billboards (`NebulaPuff`) whose overlap
// reads as diffuse gas. The cloud SHAPE comes from how the puffs are distributed, not
// the individual sprite, so three distinct "experiments" (styles) share one emitter:
//
//   • puffs      — anisotropic gaussian dust balls (soft, rounded).
//   • filaments  — curved strands walked through the volume (wispy, threadlike).
//   • turbulent  — fBm-density rejection sampling (fractal, holey, cloud-like).
//
// All three domain-warp their positions by a CPU value-noise field (`turbulence`) for
// organic irregularity, pull their hues from a small nebula palette (two-tone per
// cloud), and — crucially — DIFFUSE where they meet surveyed stars: a puff near a star
// is thinned and spread wispier, as if stellar radiation had cleared the dust. This is
// tuned live in `NebulaPlayground`; the same generator is meant to feed the live map.

/// The three nebula generation experiments.
public enum NebulaStyle: Int, CaseIterable, Identifiable, Sendable {
    case puffs, filaments, turbulent
    public var id: Int { rawValue }
    public var label: String {
        switch self {
        case .puffs: return "Puffs"
        case .filaments: return "Filaments"
        case .turbulent: return "Turbulent"
        }
    }
}

/// Generation-side tunables (a CPU rebuild is needed when any of these change — hence
/// `Equatable`, so the renderer only regenerates on an actual change). Live render
/// knobs (exposure, size, softness…) live in `NebulaUniforms` instead. Distances are
/// light-years, matching `Galaxy` (Sol at the origin, survey bulk within ~90 ly).
public struct NebulaConfig: Equatable, Sendable {
    public var style: NebulaStyle = .filaments
    public var seed: UInt32 = 0x4EB0_1A55

    /// Master scale of the nebulae vs. the known galaxy — multiplies cloud spread,
    /// puff radius and star-avoidance together, so one knob grows/shrinks the whole
    /// medium relative to the charted bubble while `fieldRadius` controls how far the
    /// clouds are scattered across it.
    public var scale: Float = 4.0

    public var cloudCount: Int = 32          // number of distinct clouds
    public var puffsPerCloud: Int = 509      // density of each cloud
    public var fieldRadius: Float = 1613.755 // DISTANCE of the cloud shell from origin (ly)
    public var thickness: Float = 0.85       // flatten the shell toward the plane (1 = sphere, <1 = disc)
    public var cloudSpread: Float = 81.923   // one cloud's extent (ly)
    public var elongation: Float = 2.4       // anisotropy of a cloud's long axis
    public var puffRadius: Float = 69.634    // base puff world radius (ly)
    public var puffRadiusJitter: Float = 0.65 // 0…1 shrink variation per puff
    public var turbulence: Float = 1.0       // domain-warp strength (organic irregularity)
    public var noiseScale: Float = 0.03      // spatial frequency of the noise field
    public var baseAlpha: Float = 0.01       // per-puff opacity before additive accumulation
    public var twoTone: Float = 0.6          // core→edge hue contrast within a cloud

    public var starAvoidRadius: Float = 26   // diffuse puffs within this of any star (ly)
    public var starAvoidStrength: Float = 0.9 // 0 = ignore stars, 1 = fully clear at the star

    public init() {}
}

extension NebulaRenderParams {
    /// The live-map render defaults (mirrors the playground's starting look).
    public static var live: NebulaRenderParams {
        var p = NebulaRenderParams()
        p.sizeScale = 0.718
        p.brightness = 0.078
        p.softness = 1.777
        p.saturation = 1.1
        p.coreBoost = 2.0
        return p
    }
}

public enum NebulaField {

    /// A hard cap so cranking the sliders can't allocate an unbounded buffer. The
    /// generator stops emitting at this many puffs (the playground surfaces the cap).
    public static let maxPuffs = 60_000

    /// On-palette nebula hues — emission rose/magenta, reflection blues, teal, violet,
    /// gold dust, oxygen green. Each cloud picks a core + edge pair for a two-tone look.
    static let palette: [SIMD3<Float>] = [
        SIMD3(0.85, 0.30, 0.42),   // H-alpha rose
        SIMD3(0.42, 0.52, 0.92),   // reflection blue
        SIMD3(0.36, 0.74, 0.78),   // teal
        SIMD3(0.62, 0.44, 0.86),   // violet
        SIMD3(0.90, 0.66, 0.40),   // gold dust
        SIMD3(0.44, 0.78, 0.54),   // oxygen green
        SIMD3(0.80, 0.40, 0.66),   // magenta
    ]

    /// Build the whole field deterministically from `config`, diffusing puffs that fall
    /// within `starAvoidRadius` of any position in `stars` (world-space, ly).
    public static func generate(config configIn: NebulaConfig, stars: [SIMD3<Float>]) -> [NebulaPuff] {
        // Fold the master `scale` in up front. It pushes the whole shell OUTWARD
        // (distance) and grows the clouds with it, so turning it up makes the medium
        // recede into the distance and read as vaster — not just fatter in place.
        var config = configIn
        let s = max(config.scale, 0.01)
        config.fieldRadius *= s
        config.cloudSpread *= s
        config.puffRadius *= s
        config.starAvoidRadius *= s

        var rng = SeededLCG(seed: config.seed == 0 ? 1 : config.seed)
        var puffs: [NebulaPuff] = []
        puffs.reserveCapacity(min(config.cloudCount * config.puffsPerCloud, maxPuffs))
        let grid = StarGrid(stars: stars, cell: max(config.starAvoidRadius, 1))

        func rnd() -> Float { Float(rng.next()) }
        func gaussian() -> Float { Float(rng.gaussian()) }
        func gaussian3() -> SIMD3<Float> { SIMD3(gaussian(), gaussian(), gaussian()) }
        func unitVec() -> SIMD3<Float> {
            let z = rnd() * 2 - 1
            let a = rnd() * 2 * .pi
            let r = (1 - z * z).squareRoot()
            return SIMD3(r * cos(a), z, r * sin(a))
        }

        // Emit one puff, applying star-diffusion: near a star the opacity drops toward
        // `1 - starAvoidStrength` and the radius grows (spread thin), so clouds read as
        // hollowed/wispy where they overlap charted systems rather than solid over them.
        func emit(_ p: SIMD3<Float>, radius: Float, core: SIMD3<Float>, edge: SIMD3<Float>,
                  colorMix t: Float, density: Float) {
            guard puffs.count < maxPuffs else { return }
            let clear = smooth01(grid.nearestDistance(to: p) / max(config.starAvoidRadius, 0.001))
            let starFactor = mixf(1 - config.starAvoidStrength, 1, clear)
            let alpha = config.baseAlpha * density * starFactor
            if alpha < 0.004 { return }
            let r = radius * mixf(1.6, 1.0, clear)
            let cm = min(max(t * config.twoTone, 0), 1)
            var rgb = core + (edge - core) * cm
            rgb *= (0.75 + 0.35 * rnd())   // gentle per-puff brightness jitter
            puffs.append(NebulaPuff(positionSize: SIMD4(p.x, p.y, p.z, r),
                                    color: SIMD4(rgb.x, rgb.y, rgb.z, alpha)))
        }

        // Emit one whole cloud of `style` centered at `center`. Both the far-field shell
        // clouds and the single origin cloud go through this — "same rules", differing
        // only in placement and style.
        func emitCloud(center: SIMD3<Float>, style: NebulaStyle,
                       core: SIMD3<Float>, edge: SIMD3<Float>) {
            // A random orthonormal basis so the cloud's long axis points anywhere.
            let w = unitVec()
            var uAxis = simd_cross(w, SIMD3(0, 1, 0))
            if simd_length(uAxis) < 0.01 { uAxis = simd_cross(w, SIMD3(1, 0, 0)) }
            uAxis = simd_normalize(uAxis)
            let vAxis = simd_normalize(simd_cross(w, uAxis))
            let elong = 1 + (config.elongation - 1) * rnd()

            func place(_ local: SIMD3<Float>) -> SIMD3<Float> {
                center + uAxis * local.x + vAxis * local.y + w * local.z
            }
            func warp(_ p: SIMD3<Float>, _ amt: Float) -> SIMD3<Float> {
                p + Noise.warp(p * config.noiseScale) * amt
            }

            switch style {
            case .puffs:
                for _ in 0..<config.puffsPerCloud {
                    let g = gaussian3()
                    let local = SIMD3(g.x * elong, g.y, g.z) * (config.cloudSpread * 0.5)
                    let p = warp(place(local), config.turbulence * config.puffRadius)
                    let dN = min(1, simd_length(local) / max(config.cloudSpread, 0.001))
                    let density = exp(-2.2 * dN * dN)   // brighter core, faded edge
                    let radius = config.puffRadius * (1 - config.puffRadiusJitter * rnd())
                    emit(p, radius: radius, core: core, edge: edge, colorMix: dN, density: density)
                }

            case .filaments:
                let steps = max(6, config.puffsPerCloud / 14)
                let perStep = max(1, config.puffsPerCloud / steps)
                var pos = center
                var dir = unitVec()
                let stepLen = (config.cloudSpread / Float(steps)) * 2.0
                for s in 0..<steps {
                    dir = simd_normalize(dir + unitVec() * 0.4)   // gentle random curve
                    pos += dir * stepLen
                    let along = Float(s) / Float(max(1, steps - 1))
                    for _ in 0..<perStep {
                        let g = gaussian3()
                        let p = warp(pos + g * (config.puffRadius * 0.9),
                                     config.turbulence * config.puffRadius)
                        let density = 0.55 + 0.45 * sin(along * .pi)   // brighter mid-strand
                        let radius = config.puffRadius * (1 - config.puffRadiusJitter * rnd()) * 0.8
                        emit(p, radius: radius, core: core, edge: edge, colorMix: rnd(), density: density)
                    }
                }

            case .turbulent:
                let attempts = config.puffsPerCloud * 3
                var made = 0
                for _ in 0..<attempts {
                    if made >= config.puffsPerCloud || puffs.count >= maxPuffs { break }
                    let g = gaussian3()
                    let local = SIMD3(g.x * elong, g.y, g.z) * (config.cloudSpread * 0.65)
                    let p = warp(place(local), config.turbulence * config.puffRadius * 1.4)
                    // Fractal density field, sharpened to carve holes; kept inside a soft
                    // envelope so the cloud still falls off at its edge.
                    let n = Noise.fbm(p * config.noiseScale * 2.0)
                    let dN = min(1, simd_length(local) / max(config.cloudSpread * 0.65, 0.001))
                    let envelope = exp(-1.6 * dN * dN)
                    let d = min(max(n * 1.5 - 0.4, 0), 1) * envelope
                    if rnd() > d { continue }   // reject low-density samples → fractal structure
                    let radius = config.puffRadius * (0.5 + rnd())
                    emit(p, radius: radius, core: core, edge: edge, colorMix: 1 - d, density: 0.5 + 0.5 * d)
                    made += 1
                }
            }
        }

        // Far-field shell clouds: each thrown out along a random direction so the medium
        // reads as a vast backdrop wrapping the charted bubble rather than mixed into it.
        // `fieldRadius` is the distance; a ±40% radial band scatters the shell in depth;
        // `thickness` flattens it toward the plane (1 = sphere, <1 = disc). `scale`
        // (folded above) pushes it out.
        for cloud in 0..<max(config.cloudCount, 0) {
            if puffs.count >= maxPuffs { break }
            let d = unitVec()
            let dir = simd_normalize(SIMD3(d.x, d.y * config.thickness, d.z))
            let center = dir * (config.fieldRadius * (1 + (rnd() * 2 - 1) * 0.4))
            emitCloud(center: center, style: config.style,
                      core: palette[cloud % palette.count],
                      edge: palette[(cloud + 1 + Int(rnd() * 3)) % palette.count])
        }

        return puffs
    }
}

// MARK: - Small helpers

@inline(__always) private func mixf(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
@inline(__always) private func smooth01(_ x: Float) -> Float {
    let t = min(max(x, 0), 1)
    return t * t * (3 - 2 * t)
}

/// A uniform spatial grid over the star positions so `nearestDistance` is O(1) amortized
/// (checking only the puff's cell + 26 neighbors) rather than scanning every star per puff.
/// Cell size == the avoidance radius, so any star within that radius is guaranteed to sit
/// in the 3×3×3 neighborhood.
private struct StarGrid {
    private struct Cell: Hashable { var x: Int32; var y: Int32; var z: Int32 }
    private let cell: Float
    private let empty: Bool
    private var buckets: [Cell: [SIMD3<Float>]] = [:]

    init(stars: [SIMD3<Float>], cell: Float) {
        self.cell = cell
        self.empty = stars.isEmpty
        for s in stars { buckets[Self.key(s, cell), default: []].append(s) }
    }

    private static func key(_ p: SIMD3<Float>, _ cell: Float) -> Cell {
        Cell(x: Int32((p.x / cell).rounded(.down)),
             y: Int32((p.y / cell).rounded(.down)),
             z: Int32((p.z / cell).rounded(.down)))
    }

    /// Distance to the nearest star, or `.greatestFiniteMagnitude` if none is within the
    /// neighborhood (i.e. farther than the avoidance radius — treated as "fully clear").
    func nearestDistance(to p: SIMD3<Float>) -> Float {
        if empty { return .greatestFiniteMagnitude }
        let base = Self.key(p, cell)
        var best = Float.greatestFiniteMagnitude
        for dx in -1...1 {
            for dy in -1...1 {
                for dz in -1...1 {
                    let k = Cell(x: base.x + Int32(dx), y: base.y + Int32(dy), z: base.z + Int32(dz))
                    guard let arr = buckets[k] else { continue }
                    for s in arr {
                        let dd = simd_distance_squared(s, p)
                        if dd < best { best = dd }
                    }
                }
            }
        }
        return best == .greatestFiniteMagnitude ? best : best.squareRoot()
    }
}

/// CPU value-noise / fBm / domain-warp, mirroring the GPU `hash13`/`vnoise`/`fbm` in
/// `ShaderCommon.h` so the tuned look matches if any of this later moves to the shader.
private enum Noise {
    @inline(__always) static func fr(_ x: Float) -> Float { x - x.rounded(.down) }

    static func hash13(_ p0: SIMD3<Float>) -> Float {
        var p = SIMD3(fr(p0.x * 0.1031), fr(p0.y * 0.1031), fr(p0.z * 0.1031))
        let d = simd_dot(p, SIMD3(p.y, p.z, p.x) + SIMD3(repeating: 31.32))
        p += SIMD3(repeating: d)
        return fr((p.x + p.y) * p.z)
    }

    static func vnoise(_ x: SIMD3<Float>) -> Float {
        let i = SIMD3(x.x.rounded(.down), x.y.rounded(.down), x.z.rounded(.down))
        let f0 = x - i
        let f = f0 * f0 * (SIMD3<Float>(repeating: 3) - 2 * f0)
        func c(_ dx: Float, _ dy: Float, _ dz: Float) -> Float { hash13(i + SIMD3(dx, dy, dz)) }
        let x00 = mixf(c(0, 0, 0), c(1, 0, 0), f.x)
        let x10 = mixf(c(0, 1, 0), c(1, 1, 0), f.x)
        let x01 = mixf(c(0, 0, 1), c(1, 0, 1), f.x)
        let x11 = mixf(c(0, 1, 1), c(1, 1, 1), f.x)
        return mixf(mixf(x00, x10, f.y), mixf(x01, x11, f.y), f.z)
    }

    static func fbm(_ x0: SIMD3<Float>) -> Float {
        var x = x0, s: Float = 0, a: Float = 0.5
        for _ in 0..<4 { s += a * vnoise(x); x *= 2.03; a *= 0.5 }
        return s
    }

    /// Three decorrelated fBm samples → a displacement vector in ~[-1, 1]³.
    static func warp(_ p: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(fbm(p) * 2 - 1,
              fbm(p + SIMD3(17.1, 9.2, 4.3)) * 2 - 1,
              fbm(p + SIMD3(-8.7, 23.4, 11.9)) * 2 - 1)
    }
}
