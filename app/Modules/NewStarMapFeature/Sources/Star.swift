import CStarMapShaderTypes
import Foundation
import simd

// The star domain model — the game's data, independent of how it's drawn.
//
// Position is an xyz coordinate in LIGHT YEARS with the origin at Sol (so the
// world unit == 1 ly, and (0,0,0) is home). Each star also carries the physical
// data the game reasons about: surface temperature, spectral (stellar) class,
// and age. Rendering is DERIVED from this (color from temperature, below); the
// GPU-side `StarInstance` is a projection of a `Star`, never the source of truth.

public struct Star: Equatable {
    /// Display name of the system. Procedural stand-in here; real catalog/lore
    /// names in the game.
    var name: String
    /// Position in light years, origin = Sol.
    var position: SIMD3<Float>
    /// Surface temperature in Kelvin.
    var temperature: Float
    /// Spectral class (Morgan–Keenan O B A F G K M).
    var stellarClass: StellarClass
    /// Age in millions of years.
    var ageMyr: Float
    /// Whether this system has an FTL relay installed. Relays within 7.5 ly of
    /// each other form the comms mesh; a lone relay is an orphan node. (Game state
    /// in the real thing; assigned procedurally here as a stand-in.)
    var hasFTLRelay: Bool
    /// Biological development of the system.
    var life: LifeLevel
    /// Resource abundances, each 0…1.
    var resources: Resources
    /// How thoroughly the player has surveyed this system.
    var scan: ScanState
    /// Whether the player has resources stored/cached in this system. (Player state
    /// in the real game; a stand-in flag here.)
    var hasInventory: Bool
}

/// Biological development, none → teeming.
enum LifeLevel: Int, CaseIterable {
    case none, microbial, complex, teeming
    var label: String {
        switch self {
        case .none: "Lifeless"
        case .microbial: "Microbial"
        case .complex: "Complex"
        case .teeming: "Teeming"
        }
    }
    /// 0…1 for filter/relevance weighting.
    var normalized: Float { Float(rawValue) / Float(LifeLevel.teeming.rawValue) }
}

/// Survey progress for a system.
enum ScanState: String, CaseIterable {
    case unexplored, partial, full
    var label: String { rawValue.capitalized }
}

/// Per-system resource abundances (0…1 each).
struct Resources: Equatable {
    var minerals: Float
    var gas: Float
    var rare: Float
    /// Overall richness 0…1 (the strongest resource), for the gauge symbol.
    var richness: Float { max(minerals, max(gas, rare)) }
}

/// One symbol in the label's status row. `value` (0…1) drives SF Symbols'
/// variable rendering (e.g. the resource gauge fills proportionally); nil = a
/// plain, non-variable symbol.
struct StatusSymbol: Equatable {
    let name: String
    let value: Float?
}

extension Star {
    /// SF Symbols for the status row under the label (toggleable): exploration
    /// (open / half / filled circle), life (leaf), resource richness (a variable
    /// gauge), and stored inventory (package). Life/resources/inventory are only
    /// reported once the system has been surveyed — an unexplored system shows just
    /// the open circle. A stand-in symbol vocabulary.
    var statusSymbols: [StatusSymbol] {
        var syms: [StatusSymbol] = []
        switch scan {
        case .unexplored: syms.append(.init(name: "circle", value: nil))
        case .partial:    syms.append(.init(name: "circle.lefthalf.filled", value: nil))
        case .full:       syms.append(.init(name: "circle.fill", value: nil))
        }
        if scan != .unexplored {
            if life != .none { syms.append(.init(name: "leaf.fill", value: nil)) }
            syms.append(.init(name: "dollarsign.gauge.chart.leftthird.topthird.rightthird",
                              value: resources.richness))     // 0…1 → variable fill
            if hasInventory { syms.append(.init(name: "shippingbox.fill", value: nil)) }
        }
        return syms
    }
}

/// Morgan–Keenan spectral classes, hottest → coolest.
enum StellarClass: String, CaseIterable {
    case O, B, A, F, G, K, M

    /// Relative abundance. Skewed cool like the real IMF, but not to the true
    /// extreme — genuine fractions would make O/B stars statistically invisible
    /// across 10k stars, and the blue accents are worth keeping for legibility.
    var weight: Float {
        switch self {
        case .O: 0.5
        case .B: 2.5
        case .A: 4
        case .F: 8
        case .G: 13
        case .K: 22
        case .M: 50
        }
    }

    /// Surface-temperature band (Kelvin) for this class.
    var temperatureRange: ClosedRange<Float> {
        switch self {
        case .O: 30_000...45_000
        case .B: 10_000...30_000
        case .A: 7_500...10_000
        case .F: 6_000...7_500
        case .G: 5_300...6_000
        case .K: 3_900...5_300
        case .M: 2_400...3_900
        }
    }

    /// Rough main-sequence lifetime cap in millions of years, already clamped to
    /// the galaxy's age. Hot massive stars die young; cool dwarfs outlive the
    /// galaxy, so their age is bounded by how long stars have existed, not by
    /// their (far longer) lifetime.
    var maxAgeMyr: Float {
        switch self {
        case .O: 10
        case .B: 300
        case .A: 2_000
        case .F: 5_000
        case .G: 12_000
        case .K: 13_000
        case .M: 13_000
        }
    }

    /// Abundance-weighted random class.
    static func weightedRandom(_ rng: inout SplitMix64) -> StellarClass {
        let total = allCases.reduce(Float(0)) { $0 + $1.weight }
        var pick = rng.unit() * total
        for c in allCases {
            pick -= c.weight
            if pick <= 0 { return c }
        }
        return .M
    }

    func randomTemperature(_ rng: inout SplitMix64) -> Float {
        temperatureRange.lowerBound
            + rng.unit() * (temperatureRange.upperBound - temperatureRange.lowerBound)
    }

    func randomAge(_ rng: inout SplitMix64) -> Float {
        max(1, rng.unit() * maxAgeMyr)   // at least ~1 Myr; nothing is truly age 0
    }
}

// MARK: Rendering projection

extension Star {

    /// The GPU instance for this star. Color comes from temperature (real data);
    /// the physical radius is a small, deterministic size jitter — a DEPTH cue
    /// only. Size never encodes importance (HANDOFF §5.5): a hot star is not drawn
    /// bigger, or perspective would fight the map's visual hierarchy.
    var renderInstance: StarInstance {
        StarInstance(
            positionRadius: SIMD4<Float>(position, worldRadius),
            color: SIMD4<Float>(Star.color(forTemperature: temperature), 1)
        )
    }

    /// Physical (world-space) render radius — a small, deterministic depth-jitter,
    /// stable per star. Overlays that ring a star match this so their marker sits
    /// around the star at every zoom.
    var worldRadius: Float {
        0.05 + 0.12 * Star.hashUnit(position)
    }

    /// Blackbody-flavored temperature → linear RGB (Tanner Helland's fit),
    /// normalized to 0..1. Ties the on-screen color to the star's real
    /// temperature rather than an arbitrary palette.
    static func color(forTemperature kelvin: Float) -> SIMD3<Float> {
        let t = min(max(kelvin, 1_000), 40_000) / 100
        var r: Float, g: Float, b: Float

        if t <= 66 {
            r = 255
            g = 99.4708025861 * log(t) - 161.1195681661
        } else {
            r = 329.698727446 * powf(t - 60, -0.1332047592)
            g = 288.1221695283 * powf(t - 60, -0.0755148492)
        }
        if t >= 66 {
            b = 255
        } else if t <= 19 {
            b = 0
        } else {
            b = 138.5177312231 * log(t - 10) - 305.0447927307
        }

        let rgb = SIMD3<Float>(r, g, b) / 255
        return SIMD3<Float>(min(max(rgb.x, 0), 1),
                            min(max(rgb.y, 0), 1),
                            min(max(rgb.z, 0), 1))
    }

    /// Deterministic 0..1 hash of a position — stable per star, no RNG state.
    private static func hashUnit(_ p: SIMD3<Float>) -> Float {
        let h = sin(dot(p, SIMD3<Float>(12.9898, 78.233, 37.719))) * 43758.5453
        return h - floor(h)
    }
}
