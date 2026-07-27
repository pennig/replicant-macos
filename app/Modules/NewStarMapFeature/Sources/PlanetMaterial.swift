//
//  PlanetMaterial.swift
//  NewStarMapFeature
//
//  The texture/material lookup for orrery planet bodies: a `PlanetType` (+ its
//  `lifeStage`) resolves to a `PlanetSurface` — two albedos, a procedural surface
//  *style*, a biosphere strength, and an `estimated` flag — which the renderer packs
//  into `OrreryBodyUniform` for `orrery_body_fragment` to texture on the GPU.
//
//  Like the scaffold/pip tints in `OrreryGeometry`, these colours live here (the
//  orrery renders in Metal and can't read the asset catalog) as the single source,
//  approximating the design tokens. The base hexes deliberately match the schematic
//  `OrreryMapping.planetColor` values for the types they share.
//

import simd

/// Which procedural terrain family the shader draws for a body. Raw values are the
/// `style` indices `orrery_body_fragment` switches on — keep them in sync.
enum PlanetSurfaceStyle: Int32, Sendable {
    case rocky    = 0   // barren / unknown — cratered mottle
    case banded   = 1   // gas giant — many bands, swirls, a storm (seed-varied)
    case icy      = 2   // frozen / dwarf — bright, fractured, polar caps
    case molten   = 3   // volcanic — dark crust with glowing lava cracks (emissive)
    case ocean    = 4   // ocean / terrestrial — continents, clouds, biosphere
    case desert   = 5   // desert — wind-blown dunes
    case iceGiant = 6   // ice giant — near-featureless with a few crisp spots
}

/// Intensity nudges derived from a body's scan `tags`. The base `PlanetType` still
/// picks the surface *style*; these only dial the amount of a feature that style
/// already draws. Neutral defaults (1× / no frost) reproduce the untagged look, so a
/// body with no useful tags renders exactly as its type does.
struct SurfaceModifiers: Equatable, Sendable {
    var craters: Float = 1      // × crater relief (rocky style)
    var atmosphere: Float = 1   // × cloud/haze amount (ocean style); 0 = airless
    var lava: Float = 1         // × molten crack emissive (molten style)
    var frost: Float = 0        // additive frost/ice overlay on any style (0…1)
}

/// Everything the body shader needs to texture one planet. `base`/`detail` are 0…1
/// linear-ish RGB; `life` (0…1) grows vegetation + night-side city lights on
/// ocean/terrestrial worlds; `estimated` triggers the duller, staticky treatment;
/// `mods` fine-tune feature intensity from the body's tags; `polarIce` (0…1) grows
/// ice caps at the poles of a cold, otherwise-unfrozen world (temperature-driven).
struct PlanetSurface: Equatable, Sendable {
    var base: SIMD3<Float>
    var detail: SIMD3<Float>
    var style: PlanetSurfaceStyle
    var life: Float
    var estimated: Bool
    var mods: SurfaceModifiers
    var polarIce: Float = 0
    /// Saturation multiplier for the world's *green* (land + vegetation); 1 = unchanged.
    /// > 1 only for terran/super-Earth worlds, stronger inside the habitable zone. The
    /// blue ocean is untouched. The land `base` is boosted CPU-side (here); the shader
    /// applies the same factor to its vegetation tint so a living world reads livelier.
    var greenVibrancy: Float = 1
}

/// The atmosphere halo drawn as a soft glow shell bleeding beyond a terrestrial body's
/// limb (see `orrery_atmosphere_fragment`). `extent` is the shell's outer radius as a
/// multiple of the body radius; `density` (0…1) scales the glow's opacity/intensity;
/// `tint` is its 0…1 RGB colour. Only non-giant bodies with a confirmed, non-`none`
/// reading get one — see `PlanetMaterial.atmosphereShell`.
struct AtmosphereShell: Equatable, Sendable {
    var tint: SIMD3<Float>
    var extent: Float
    var density: Float
}

/// A ring system, drawn as a flat annulus in the body's equatorial plane (see
/// `orrery_ring_fragment`). `innerFrac`/`outerFrac` are multiples of the body's
/// rendered radius; `seed` places the gaps so a body's rings look identical every
/// time it is viewed. Only bodies whose scan reports `rings == true` get one —
/// SOL-6 and SOL-7 are the live examples.
struct RingSystem: Equatable, Sendable {
    var innerFrac: Float
    var outerFrac: Float
    var seed: Float
    var tint: SIMD3<Float>
}

enum PlanetMaterial {

    /// Primary albedo hex per type. Shared with `OrreryMapping.planetColor` for the
    /// overlapping types (schematic HUD colour == texture base colour).
    static func baseHex(_ type: PlanetType) -> String {
        switch type {
        case .oceanWorld:  "#3f7fd0"
        case .desertWorld: "#c98b5a"
        case .terrestrial: "#5fb07a"
        case .superEarth:  "#6fb583"
        case .iceGiant:    "#9fd0e0"
        case .gasGiant:    "#caa06a"
        case .frozen:      "#cdd6e6"
        case .volcanic:    "#3a2b26"   // dark basalt crust; lava lives in `detail`
        case .barren:      "#8f857a"
        case .dwarfPlanet: "#b8bcc6"
        case .unknown:     "#a89a86"
        }
    }

    /// Secondary/terrain tint the shader mixes in (bands, continents, dunes, or — for
    /// molten worlds — the self-illuminated lava colour).
    static func detailHex(_ type: PlanetType) -> String {
        switch type {
        case .oceanWorld:  "#cbb894"   // sandy coasts against the sea
        case .desertWorld: "#9a6238"   // darker dune troughs
        case .terrestrial: "#3f6f9a"   // oceans against green land
        case .superEarth:  "#4a7a5a"
        case .iceGiant:    "#d6ecf4"   // pale band highlights
        case .gasGiant:    "#8f6f44"   // darker belts
        case .frozen:      "#eaf1fb"
        case .volcanic:    "#ff6a2a"   // glowing lava (emissive)
        case .barren:      "#6f665c"   // crater shadow
        case .dwarfPlanet: "#8f95a2"
        case .unknown:     "#8a7f70"
        }
    }

    static func style(_ type: PlanetType) -> PlanetSurfaceStyle {
        switch type {
        case .gasGiant:                 .banded
        case .iceGiant:                 .iceGiant
        case .frozen, .dwarfPlanet:     .icy
        case .volcanic:                 .molten
        case .oceanWorld, .terrestrial, .superEarth: .ocean
        case .desertWorld:              .desert
        case .barren, .unknown:         .rocky
        }
    }

    /// Biosphere strength (0 = dead … 1 = intelligent) from the backend `lifeStage`
    /// string. Drives vegetation greening + night-side city lights on living worlds.
    static func lifeIntensity(_ lifeStage: String?) -> Float {
        switch (lifeStage ?? "").lowercased() {
        case "", "none":          0.0
        case "microbial":         0.35
        case "prebiotic":         0.5
        case "flora":             0.6
        case "fauna":             0.8
        case "intelligent":       1.0
        default:                  0.4   // some unknown-but-present biosignature
        }
    }

    /// Fold a body's scan `tags` into feature-intensity modifiers. Only tags that
    /// carry a rendering hint have an effect; everything else (and any new tag the
    /// game adds) is ignored, so the base type still fully determines the look. When
    /// several tags touch the same modifier the strongest wins.
    static func modifiers(tags: [String]) -> SurfaceModifiers {
        var m = SurfaceModifiers()
        for raw in tags {
            switch raw.lowercased() {
            case "cratered":            m.craters = max(m.craters, 1.6)
            case "no_atmosphere":       m.atmosphere = 0
            case "thin_atmosphere":     m.atmosphere = min(m.atmosphere, 0.5)
            case "thick_atmosphere", "methane_atmosphere":
                                        m.atmosphere = max(m.atmosphere, 1.35)
            case "volcanic":            m.lava = max(m.lava, 1.4)
            case "tectonically_active": m.lava = max(m.lava, 1.5)
            case "hellworld":           m.lava = max(m.lava, 1.8)
            case "ice_surface":         m.frost = max(m.frost, 0.7)
            case "frozen":              m.frost = max(m.frost, 0.6)
            case "cold":                m.frost = max(m.frost, 0.3)
            default:                    break   // no rendering hint (barren, ice_giant, …)
            }
        }
        return m
    }

    // MARK: - Atmosphere

    /// Resolve the atmosphere halo for a terrestrial body, or `nil` for one that gets
    /// none: a giant (its banded/icy texture already conveys its atmosphere), or a body
    /// whose reading is `none` (airless) or `unknown` (not yet scanned). Thickness comes
    /// straight from the scan's ordinal `atmosphere` value — extent and density grow with
    /// it. The tint is that ordinal's colour, with a methane world (from `tags`) shifted
    /// to an orange haze (Titan-like) regardless of thickness.
    static func atmosphereShell(for type: PlanetType, atmosphere: Atmosphere,
                                tags: [String] = []) -> AtmosphereShell? {
        guard !type.isGiant else { return nil }
        let extent: Float, density: Float, hex: String
        switch atmosphere {
        case .none, .unknown:
            return nil
        case .thin:
            extent = 1.06; density = 0.30; hex = "#8fb8ff"   // faint Rayleigh blue
        case .standard:
            extent = 1.10; density = 0.55; hex = "#9cc2ff"   // Earth-like sky blue
        case .dense:
            extent = 1.15; density = 0.80; hex = "#dfe4ee"   // thick pale haze
        case .crushing:
            extent = 1.21; density = 1.00; hex = "#ecdca6"   // Venusian ochre cloud
        }
        let methane = tags.contains { $0.lowercased() == "methane_atmosphere" }
        let tint = OrreryGeometry.rgb(hex: methane ? "#e0a15a" : hex)
        return AtmosphereShell(tint: tint, extent: extent, density: density)
    }

    // MARK: - Rings

    /// Resolve a body's ring system, or nil for a body that reports no rings. Giants
    /// carry broad, bright ice rings; a rocky world's are narrower and dustier. The
    /// band always starts clear of the body's own limb.
    static func ringSystem(hasRings: Bool, type: PlanetType, seed: Float) -> RingSystem? {
        guard hasRings else { return nil }
        let giant = type.isGiant
        return RingSystem(
            innerFrac: giant ? 1.35 : 1.25,
            outerFrac: giant ? 2.30 : 1.85,
            seed: seed,
            tint: OrreryGeometry.rgb(hex: giant ? "#d8cfb4" : "#9c9186"))
    }

    // MARK: - Saturation

    /// Push an RGB colour away from its own grey (luma-preserving), boosting saturation.
    /// `factor` > 1 saturates, 1 leaves it unchanged, < 1 desaturates. Result is clamped
    /// to 0…1 so a strong boost can't produce out-of-gamut channels.
    private static func saturated(_ c: SIMD3<Float>, by factor: Float) -> SIMD3<Float> {
        let luma = simd_dot(c, SIMD3<Float>(0.2126, 0.7152, 0.0722))
        let grey = SIMD3<Float>(repeating: luma)
        return simd_clamp(grey + (c - grey) * factor, SIMD3<Float>(repeating: 0),
                          SIMD3<Float>(repeating: 1))
    }

    /// Saturation boost for a terran world's land-green `base`, tuned by habitable-zone
    /// membership: a world in the zone reads livelier (more saturated green) than one
    /// whose green is a colder, sparser fringe. Only the green *base* is boosted — the
    /// blue ocean `detail` keeps its own (already full) saturation, per the brief.
    private static func terranGreenBoost(inHabitableZone: Bool) -> Float {
        inHabitableZone ? 1.55 : 1.25
    }

    // MARK: - Temperature effects

    /// Smoothstep on a raw ratio (Hermite `3t²−2t³`), clamped to 0…1.
    private static func smooth01(_ x: Double) -> Float {
        let t = min(max(x, 0), 1)
        return Float(t * t * (3 - 2 * t))
    }

    /// Blackbody-ish lava emissive colour for a volcanic world at `tempC` (°C).
    /// Follows the standard hot-rock progression: dull red (~600–800), bright red
    /// (~800–1000), orange (~1000–1200), yellow/white (~1200–1400). Below or above
    /// the band it clamps to the coolest / hottest stop. Fed to the molten style as
    /// its `detail` (the self-illuminated lava tint).
    static func lavaColor(tempC: Double) -> SIMD3<Float> {
        // Colour stops at the centre of each blackbody band.
        let stops: [(t: Double, c: SIMD3<Float>)] = [
            (700,  SIMD3(0.42, 0.045, 0.02)),   // dull red
            (900,  SIMD3(0.95, 0.13,  0.04)),   // bright red
            (1100, SIMD3(1.0,  0.45,  0.10)),   // orange
            (1300, SIMD3(1.0,  0.88,  0.62)),   // yellow / white
        ]
        if tempC <= stops.first!.t { return stops.first!.c }
        if tempC >= stops.last!.t { return stops.last!.c }
        for i in 1..<stops.count where tempC <= stops[i].t {
            let lo = stops[i - 1], hi = stops[i]
            let f = Float((tempC - lo.t) / (hi.t - lo.t))
            return lo.c + (hi.c - lo.c) * f
        }
        return stops.last!.c
    }

    /// Temperature multiplier on a molten world's `lava` modifier: cooler volcanic
    /// worlds show thin, dim seams; hotter ones crack wide and glow bright. ~1× at
    /// mid-range (≈950 °C) so it composes with the tag-driven intensity.
    static func lavaAmount(tempC: Double) -> Float {
        0.6 + 1.1 * smooth01((tempC - 600) / 800)   // 0.6× at ≤600°C → 1.7× at ≥1400°C
    }

    /// Polar ice-cap *extent* on a cold world (0 = none … 1 = caps reach farthest
    /// toward the equator): smoothly ramps in from 40 °C down to −200 °C. This drives
    /// how much of each pole is iced. The shader renders the cap at full opacity so even
    /// a small amount reads clearly as ice.
    /// Only thecaller's type gate decides whether a body gets caps at all.
    static func polarIce(tempC: Double) -> Float {
        smooth01((40 - tempC) / 240)   // 0 at 40°C → 1 at −200°C
    }

    /// Cloud-cover strength (feeds `SurfaceModifiers.atmosphere`, the shader's cloud
    /// amount) from the scanned atmosphere thickness: thicker air → more overcast, up to
    /// full cover for a `crushing` (Venusian) sky. `.none` and `.unknown` (airless or
    /// not-yet-scanned) return 0 → no clouds.
    static func cloudAmount(for atmosphere: Atmosphere) -> Float {
        switch atmosphere {
        case .none:     0.0
        case .thin:     0.4
        case .standard: 0.65
        case .dense:    0.95
        case .crushing: 1.3    // saturates the coverage threshold → total overcast
        case .unknown:  0.0
        }
    }

    /// Resolve the full surface for a body. `estimated` (the body's `typeEstimated`
    /// flag) drives the duller, staticky treatment for unconfirmed intel; `tags` (the
    /// body's scan tags, empty until scanned) fine-tune feature intensity; `surfaceTempC`
    /// (the scanned surface temperature, °C) shifts lava hue/amount on volcanic worlds
    /// and grows polar ice caps on cold desert/terrestrial/super-earth/ocean worlds;
    /// `atmosphere` (the scanned thickness) sets the animated cloud cover on non-giant
    /// worlds, overriding the tag-derived amount once a real reading is in.
    static func surface(for type: PlanetType, lifeStage: String?, estimated: Bool,
                        tags: [String] = [], surfaceTempC: Double? = nil,
                        atmosphere: Atmosphere = .unknown,
                        inHabitableZone: Bool = false) -> PlanetSurface {
        var base = OrreryGeometry.rgb(hex: baseHex(type))
        var detail = OrreryGeometry.rgb(hex: detailHex(type))
        var mods = modifiers(tags: tags)
        var polar: Float = 0

        // Terran/super-Earth worlds' land-green reads washed out at the raw albedo, so
        // saturate the green — livelier inside the habitable zone. The ocean `detail`
        // (blue) is deliberately left at full saturation. The same factor is carried to
        // the shader so the vegetation tint (which dominates a high-life world) matches.
        var greenVibrancy: Float = 1
        switch type {
        case .terrestrial, .superEarth:
            greenVibrancy = terranGreenBoost(inHabitableZone: inHabitableZone)
            base = saturated(base, by: greenVibrancy)
        default:
            break
        }

        // Cloud cover on terrestrial worlds is driven entirely by the scanned atmosphere
        // reading — authoritative over the (atmosphere-blind) tags. `.unknown`/`.none`
        // map to 0, so an unscanned or airless body shows no clouds. Giants don't draw
        // the cloud layer (shader gate), so their cloud amount is left untouched.
        if !type.isGiant {
            mods.atmosphere = cloudAmount(for: atmosphere)
        }

        if let temp = surfaceTempC {
            switch type {
            case .volcanic:
                // Temperature sets the lava's black-body hue and how much of it shows.
                detail = lavaColor(tempC: temp)
                mods.lava *= lavaAmount(tempC: temp)
            case .desertWorld, .terrestrial, .superEarth, .oceanWorld:
                // A cold rocky/terran/ocean world ices over at the poles.
                polar = polarIce(tempC: temp)
            default:
                break
            }
        }

        return PlanetSurface(
            base: base,
            detail: detail,
            style: style(type),
            life: lifeIntensity(lifeStage),
            estimated: estimated,
            mods: mods,
            polarIce: polar,
            greenVibrancy: greenVibrancy)
    }
}
