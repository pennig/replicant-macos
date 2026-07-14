//
//  OrreryModels.swift
//  NewStarMapFeature
//
//  The Star System (orrery) presentation model. Built from the real
//  `UniverseModels.StarSystem` (see `OrreryMapping.swift`) — orbits/radii are in
//  *orrery scene units* derived from real AU via a compressed radial map, so the
//  system frames cleanly on fly-in. Scan-only star facts are optional (nil until
//  the system is scanned). Internal to the module — renderer + HUD consume these.
//

import Foundation
import UniverseModels
import simd

// MARK: - Star / planet detail

struct HabitableZone: Equatable, Sendable {
    var innerAu: Double
    var outerAu: Double
}

struct StarDetail: Equatable, Sendable {
    var designation: String
    var name: String?
    var spectralType: String?
    var color: String?
    var position: Position
    // Scan-only (nil until the system is scanned).
    var temperatureK: Double?
    var massSolar: Double?
    var luminositySolar: Double?
    var ageMy: Double?
    var habitableZone: HabitableZone?
    var miningBonusPct: Double?
}

/// Which notable features a body carries — drives the small indicator pips.
struct BodyIndicators: OptionSet, Equatable, Sendable {
    let rawValue: Int
    static let device     = BodyIndicators(rawValue: 1 << 0)
    static let salvage    = BodyIndicators(rawValue: 1 << 1)
    static let miningSite = BodyIndicators(rawValue: 1 << 2)
    static let inventory  = BodyIndicators(rawValue: 1 << 3)
    static let life       = BodyIndicators(rawValue: 1 << 4)
}

/// A Lagrange point of a planet (`SYSTEM-n-L[1-5]`), positioned relative to that
/// planet's live orbit position and the system star. Schematic, not physically exact.
struct LagrangePoint: Identifiable, Equatable, Sendable {
    var designation: String   // e.g. SOL-5-L4
    var point: Int            // 1…5 (the L-number)
    var id: String { designation }
}

/// A positioned system object that isn't a planet/moon/belt — a megastructure, an
/// incoming asteroid, or an outer-system region (kuiper/oort). Carried so devices,
/// pips, and picking can anchor to it. `orbitScene` is its distance from the star in
/// scene units (0 = unknown / at the star). Distinct from `OrreryHazard`, which drives
/// the animated impact markers; a hazard and a structure may describe the same object.
struct OrreryStructure: Identifiable, Equatable, Sendable {
    var designation: String
    var kind: String          // "megastructure" / "object" / "incoming_asteroid" / "kuiper" / "oort"
    var orbitScene: Double
    var id: String { designation }
}

struct OrreryMoon: Equatable, Sendable {
    var designation: String
    var name: String?
    var type: String?
    var orbitScene: Double
    var periodDays: Double
    var phase0Deg: Double
    var displayRadius: Double
    var colorHex: String
    var indicators: BodyIndicators = []
}

struct OrreryPlanet: Identifiable, Equatable, Sendable {
    var designation: String
    var name: String?
    var type: String?
    /// Classified kind — drives surface texturing.
    var planetType: PlanetType
    /// The body's `typeEstimated` flag: its type is a guess, not confirmed intel.
    /// Renders duller + staticky.
    var estimated: Bool
    /// Scan `tags` (empty until scanned) — texture-intensity hints (cratered, frozen, …).
    var tags: [String]
    /// Scanned surface temperature (°C, nil until scanned) — shifts lava hue/amount on
    /// volcanic worlds and grows polar ice caps on cold desert/terran worlds.
    var surfaceTempC: Double?
    /// Scanned atmospheric thickness (`.unknown` until scanned) — drives the atmosphere
    /// halo on terrestrial bodies. Decoupled from type/temperature; read from the scan.
    var atmosphere: Atmosphere
    /// Stable per-body surface-variability seed (hash of designation + rotation period).
    var appearanceSeed: Float
    var orbitalDistanceAu: Double
    var inHabitableZone: Bool
    var scanned: Bool
    var moonCount: Int
    var lifeStage: String?
    var inventory: [InventoryItem]

    var semiMajorScene: Double        // orbit radius (scene units, from AU)
    var periodDays: Double
    var phase0Deg: Double
    var displayRadius: Double
    var colorHex: String
    var hasRing: Bool
    var indicators: BodyIndicators
    /// A moon worth a look (life / salvage / your device / inventory). Refined
    /// once the planet is hydrated; a hint (`moonCount > 0`) before that.
    var hasInterestingMoon: Bool
    var moons: [OrreryMoon]
    /// This planet's Lagrange points (`SYSTEM-n-L[1-5]`), if the scan reported any.
    var lagrange: [LagrangePoint] = []

    var id: String { designation }
}

/// Asteroid belt in scene units, plus API detail for the HUD.
struct BeltModel: Identifiable, Equatable, Sendable {
    var designation: String
    var innerScene: Double
    var outerScene: Double
    var density: String?
    var richness: [String: String]
    var hasSites: Bool
    var id: String { designation }
}

/// A system hazard/object (e.g. an incoming asteroid on an impact course).
struct OrreryHazard: Identifiable, Equatable, Sendable {
    var designation: String
    var objectType: String            // "incoming_asteroid", "megastructure", …
    var title: String?
    var orbitScene: Double            // distance from the star (scene units)
    var targetScene: SIMD3<Float>?    // impact-target position (scene units), if known
    var progressPct: Double?
    var deadline: Date?
    var id: String { designation }
}

/// The body at the centre of a *body-level* orrery — the drilled planet, drawn as
/// a lit impostor with its moons orbiting. Nil at system level, where the centre is
/// the focused field-star sun (a real star instance, not an orrery body).
struct CentralBody: Equatable, Sendable {
    var displayRadius: Double     // scene units
    var colorHex: String
    var hasRing: Bool
    /// Classified kind + biosphere, so the drilled planet is textured like it was
    /// when orbiting at system level. `estimated` = its type is an unconfirmed guess.
    var planetType: PlanetType
    var lifeStage: String?
    var estimated: Bool
    var tags: [String]
    /// Whether the drilled planet orbits within its star's habitable zone — livens the
    /// land-green saturation of a terran surface (see `PlanetMaterial.surface`).
    var inHabitableZone: Bool
    /// Scanned surface temperature (°C, nil until scanned) — see `OrreryPlanet.surfaceTempC`.
    var surfaceTempC: Double?
    /// Scanned atmospheric thickness — see `OrreryPlanet.atmosphere`.
    var atmosphere: Atmosphere
    var appearanceSeed: Float
}

/// The full orrery presentation aggregate for one focus level. At system level the
/// `planets` orbit the focused field star; at body level they are the drilled
/// planet's moons orbiting `centralBody`.
struct SystemModel: Equatable, Sendable {
    var star: StarDetail
    /// Set only at body level — the drilled planet drawn at the centre.
    var centralBody: CentralBody? = nil
    var hzInnerScene: Double?
    var hzOuterScene: Double?
    var planets: [OrreryPlanet]
    var belts: [BeltModel]
    var hazards: [OrreryHazard]
    /// Positioned system objects (megastructures, objects, outer-system regions) for
    /// device/pip/picking anchors. Additive to `hazards` (which drives impact markers).
    var structures: [OrreryStructure] = []
    var kuiperScene: Double?
    /// Radius (scene units) the camera frames on drill-in — the outermost planet
    /// / belt, so a lone inner planet still fills the view (a distant kuiper ring
    /// may extend beyond it).
    var frameScene: Double
    // System-scoped roll-ups for the HUD.
    var deviceCount: Int
    var vesselCount: Int

    /// Scene-unit position of a planet designation at its phase0. Star = origin.
    func anchorPosition(for id: String) -> SIMD3<Float> {
        guard let planet = planets.first(where: { $0.id == id }) else { return .zero }
        let a = Float(planet.phase0Deg) * .pi / 180
        let r = Float(planet.semiMajorScene)
        return SIMD3(cos(a) * r, 0, sin(a) * r)
    }
}
