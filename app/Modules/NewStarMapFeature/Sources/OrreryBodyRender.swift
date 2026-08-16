//
//  OrreryBodyRender.swift
//  NewStarMapFeature
//
//  A placed body's material inputs and its GPU uniform builders — pure functions
//  of `PlacedBody`, callable by any renderer that draws a body, not only the orrery.
//

import CStarMapShaderTypes
import UniverseModels
import simd

/// A body's placement and material inputs for one frame, shared by the body,
/// ring, and atmosphere-halo passes so all three draw at exactly the same spot.
struct PlacedBody {
    var isCentral: Bool           // the drilled planet (opaque + size-morphing), not a moon/planet
    var center: SIMD3<Float>
    var radius: Float
    var sun: SIMD3<Float>         // light source (world), so both draws share it
    var type: PlanetType
    var lifeStage: String?
    var estimated: Bool
    var tags: [String]
    var inHabitableZone: Bool
    var surfaceTempC: Double?
    var atmosphere: Atmosphere
    var appearanceSeed: Float
    /// Spin phase in radians at t = 0. For a TIDALLY LOCKED body this is its orbit
    /// angle, which — paired with `spinRate == 0` — keeps its near face toward its
    /// parent as it goes round.
    var spinPhase: Float
    /// The body's north pole (unit, world space) — the frame it is textured in.
    var spinAxis: SIMD3<Float>
    /// Signed spin rate (rad/s); negative is retrograde, 0 is tidally locked.
    var spinRate: Float
    /// Subsurface-ocean cryo-fracture amount (0…1).
    var ocean: Float
    /// Silhouette irregularity (0 = smooth sphere). See `PlanetMaterial.irregularity`.
    var irregularity: Float
    /// The body's ring system, if it has one — drives the ring pass.
    var rings: RingSystem?
}

/// Pack a placed body's resolved `PlanetMaterial` surface into the GPU uniform:
/// albedos, procedural style, biosphere strength, the estimated flag, and a
/// deterministic per-body spin seed for stable, distinct planet rotation.
func bodyUniform(_ p: PlacedBody) -> OrreryBodyUniform {
    let s = PlanetMaterial.surface(for: p.type, lifeStage: p.lifeStage, estimated: p.estimated,
                                   tags: p.tags, surfaceTempC: p.surfaceTempC,
                                   atmosphere: p.atmosphere,
                                   inHabitableZone: p.inHabitableZone,
                                   hasSubsurfaceOcean: p.ocean > 0)
    // Only the MID and SHORT semi-axes travel to the GPU, unit-product-normalised —
    // the shader recovers the long axis as 1/(mid·short).
    let axes = p.irregularity > 0
        ? PlanetMaterial.irregularAxes(seed: p.appearanceSeed)
        : SIMD3<Float>(1, 0, 0)
    return OrreryBodyUniform(
        centerRadius: SIMD4(p.center, p.radius),
        color: SIMD4(s.base, s.polarIce),
        sunEmissive: SIMD4(p.sun, s.greenVibrancy),
        detailColor: SIMD4(s.detail, Float(s.style.rawValue)),
        surfaceParams: SIMD4(s.estimated ? 1 : 0, s.life, p.spinPhase, p.appearanceSeed),
        surfaceMods: SIMD4(s.mods.craters, s.mods.atmosphere, s.mods.lava, s.mods.frost),
        spinAxis: SIMD4(p.spinAxis, p.spinRate),
        surfaceExtras: SIMD4(p.ocean, p.irregularity, axes.y, axes.z))
}

/// The ring uniform for a placed body, or `nil` if it has no rings. Same
/// centre/radius/sun as the body draw so the annulus registers exactly with the
/// limb, and the same pole so it lies in the body's true equatorial plane.
func ringUniform(_ p: PlacedBody) -> OrreryRingUniform? {
    guard let r = p.rings else { return nil }
    return OrreryRingUniform(
        centerRadius: SIMD4(p.center, p.radius),
        poleInner: SIMD4(p.spinAxis, r.innerFrac),
        sunOuter: SIMD4(p.sun, r.outerFrac),
        tintSeed: SIMD4(r.tint, r.seed))
}

/// The atmosphere-halo uniform for a placed body, or `nil` if it gets no shell (a
/// giant, or an airless/unscanned reading). Same center/radius as the body draw so
/// the halo registers exactly with the limb; lit by the same orrery sun.
func atmosphereUniform(_ p: PlacedBody) -> OrreryAtmosphereUniform? {
    guard let shell = PlanetMaterial.atmosphereShell(for: p.type, atmosphere: p.atmosphere,
                                                     tags: p.tags) else { return nil }
    return OrreryAtmosphereUniform(
        centerRadius: SIMD4(p.center, p.radius),
        sunExtent: SIMD4(p.sun, shell.extent),
        tintDensity: SIMD4(shell.tint, shell.density))
}

extension PlacedBody {
    /// A body drawn alone, filling its own frame: no orbit, no siblings, no parent
    /// star. A locked body takes the free-rotator phase, as a central body does.
    init(portrait a: BodyAppearance, designation: String,
         center: SIMD3<Float>, radius: Float, sun: SIMD3<Float>) {
        let irregularity = PlanetMaterial.irregularity(type: a.rawType)
        self.init(
            isCentral: false, center: center, radius: radius, sun: sun,
            type: a.planetType, lifeStage: a.lifeStage, estimated: a.estimated,
            tags: a.tags, inHabitableZone: a.inHabitableZone,
            surfaceTempC: a.surfaceTempC, atmosphere: a.atmosphere,
            appearanceSeed: a.appearanceSeed,
            spinPhase: Float(OrreryMapping.phaseDeg(designation)) * .pi / 180,
            spinAxis: BodySpin.renderSpinAxis(
                irregularity: irregularity, locked: false,
                pole: a.spin.pole(seed: a.appearanceSeed),
                tumbleSeed: a.appearanceSeed),
            spinRate: a.spin.spinRate(),
            ocean: a.hasSubsurfaceOcean ? 1 : 0,
            irregularity: irregularity,
            rings: a.rings)
    }
}
