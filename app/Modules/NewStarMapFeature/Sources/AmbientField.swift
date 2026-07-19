import CStarMapShaderTypes
import simd

// The diffuse interstellar medium that sits *between* the charted systems — the
// systems themselves are the galaxy; this is the stuff in between. Ported from
// the SceneKit `AmbientField` (SCNGeometry point clouds) to a single additive
// Metal point-sprite buffer: a faint dust haze, a few abstract nebula clouds, a
// scatter of hot proto-star masses, and a distant star shell. Deterministic in
// `seed`, so it renders identically every launch and is unit-testable.
//
// World scale is light-years (Sol at the origin), matching `Galaxy` — the charted
// bubble is ~90 ly (coreSigma 30), so the field extends an order of magnitude
// beyond it to surround and permeate the systems rather than read as its own
// galaxy. Sizes stay inside the camera's far plane (bumped in the renderer).

/// A small, deterministic linear-congruential RNG (ported from the SceneKit
/// field). A value type so field generation is pure.
struct SeededLCG {
    private var state: UInt32

    init(seed: UInt32) {
        self.state = seed == 0 ? 0x9E37_79B9 : seed
    }

    /// Next value in [0, 1).
    mutating func next() -> Double {
        state = state &* 1_103_515_245 &+ 12_345
        state &= 0x7FFF_FFFF
        return Double(state) / Double(0x7FFF_FFFF)
    }

    /// Next value in [low, high).
    mutating func next(in range: ClosedRange<Double>) -> Double {
        range.lowerBound + next() * (range.upperBound - range.lowerBound)
    }

    /// Approximately normal value (mean 0, std ≈ 0.58) via the central-limit
    /// trick — cheap, deterministic, good enough for soft clustering.
    mutating func gaussian() -> Double {
        (next() + next() + next() + next()) * 0.5 - 1.0
    }
}

enum AmbientField {

    /// On-palette hues for the medium. Muted, desaturated — a backdrop, not chrome.
    struct Tints {
        var dustWarm: SIMD3<Float>
        var dustCool: SIMD3<Float>
        var nebula: [SIMD3<Float>]
        var protostar: SIMD3<Float>

        static let neutral = Tints(
            dustWarm: SIMD3(0.62, 0.58, 0.50),
            dustCool: SIMD3(0.46, 0.54, 0.72),
            nebula: [
                SIMD3(0.62, 0.50, 0.86),   // violet
                SIMD3(0.40, 0.74, 0.78),   // teal
                SIMD3(0.46, 0.80, 0.56),   // green
                SIMD3(0.46, 0.62, 0.92),   // blue
            ],
            protostar: SIMD3(1.00, 0.78, 0.48)   // warm amber
        )
    }

    /// Tunables (light years). The charted systems span ~90 ly; this field is an
    /// order of magnitude larger so it surrounds them. Kept inside the renderer's
    /// far plane.
    struct Config {
        var dustCount = 7000
        var protostarCount = 120
        var radius: Double = 2600
        var thickness: Double = 2600
        var shellCount = 900
        var shellRadius: Double = 2000
    }

    /// Point sizes (pixels), one per category. Clamped again in the shader.
    private static let dustSize: Float = 2.3
    private static let protostarSize: Float = 3.8
    private static let shellSize: Float = 1.8

    /// Build the whole field as one additive point-sprite array. Deterministic.
    static func generate(
        seed: UInt32 = 0xBADC_0FFE,
        config: Config = Config(),
        tints: Tints = .neutral
    ) -> [AmbientVertex] {
        var rng = SeededLCG(seed: seed)
        var motes: [AmbientVertex] = []
        motes.reserveCapacity(
            config.dustCount + config.protostarCount + config.shellCount)

        func emit(_ p: SIMD3<Float>, size: Float, _ rgb: SIMD3<Float>, _ alpha: Float) {
            motes.append(AmbientVertex(
                positionSize: SIMD4(p, size),
                color: SIMD4(rgb, alpha)))
        }

        // — Dust haze: a flattened, lumpy ellipsoid of dim motes. Mild center bias
        //   so it thins toward the edges and fades into the backdrop. —
        for _ in 0..<config.dustCount {
            let theta = rng.next(in: 0...(2 * .pi))
            let rr = pow(rng.next(), 0.55) * config.radius
            let flatten = 1 - 0.45 * (rr / config.radius)
            let p = SIMD3<Float>(
                Float(cos(theta) * rr),
                Float(rng.gaussian() * config.thickness * flatten),
                Float(sin(theta) * rr))
            let mix = Float(rng.next())
            let rgb = mix * tints.dustWarm + (1 - mix) * tints.dustCool
            emit(p, size: dustSize, rgb, Float(rng.next(in: 0.03...0.16)))
        }

        // Nebula clouds moved to the dedicated volumetric `NebulaField` (billboard
        // puffs, star-diffused) drawn in its own pass — see StarFieldRenderer.

        // — Proto-stars: a few hot, bright masses seeded inside the clouds. —
        for _ in 0..<config.protostarCount {
            let theta = rng.next(in: 0...(2 * .pi))
            let rr = rng.next(in: 0 ... config.radius * 0.7)
            let p = SIMD3<Float>(
                Float(cos(theta) * rr + rng.gaussian() * 12),
                Float(rng.gaussian() * config.thickness * 0.7),
                Float(sin(theta) * rr + rng.gaussian() * 12))
            let heat = Float(rng.next())
            let rgb = tints.protostar * (1 - 0.35 * heat) + SIMD3(repeating: 0.35 * heat)
            emit(p, size: protostarSize, rgb, Float(rng.next(in: 0.6...1.0)))
        }

        // — Star shell: a distant sphere of faint stars, the universe beyond. It
        //   parallaxes as the camera orbits (real 3D, not a flat backdrop). —
        var shellRng = SeededLCG(seed: seed ^ 0xCAFE_BABE)
        for _ in 0..<config.shellCount {
            let z = shellRng.next(in: -1...1)
            let theta = shellRng.next(in: 0...(2 * .pi))
            let ring = (1 - z * z).squareRoot()
            let p = SIMD3<Float>(
                Float(cos(theta) * ring * config.shellRadius),
                Float(z * config.shellRadius),
                Float(sin(theta) * ring * config.shellRadius))
            let warm = Float(shellRng.next())
            let rgb = SIMD3<Float>(0.86 + 0.14 * warm, 0.88 + 0.10 * warm, 1.0 - 0.10 * warm)
            emit(p, size: shellSize, rgb, Float(shellRng.next(in: 0.20...0.85)))
        }

        return motes
    }
}
