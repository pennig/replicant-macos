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
    var indicators: BodyIndicators = []
}

/// A moon that did not earn its own orbit ring — one member of the swarm band drawn
/// around a planet with a large roster. Deliberately much lighter than `OrreryPlanet`:
/// a swarm member is never picked in 3D, never labelled, never carries indicators, and
/// never hosts a device (`MoonTiering` promotes anything interesting), so it needs only
/// enough to be positioned, typed, and listed in the HUD roster.
///
/// It is a SEPARATE collection from `SystemModel.planets` rather than a flag on
/// `OrreryPlanet` so the exclusions are structural: `OrreryGeometry.scaffoldLines`
/// iterates `planets` to emit orbit rings, and picking iterates `planets`, so a swarm
/// member gets neither by construction instead of by every consumer remembering a check.
struct SwarmMoon: Identifiable, Equatable, Sendable {
    var designation: String
    var name: String?
    var type: String?
    /// Orbit radius within the swarm band (scene units).
    var orbitScene: Double
    /// Signed offset off the orbital plane (scene units) — the inclination scatter that
    /// makes the band read as a cloud of rocks rather than a ring of dots.
    var offsetScene: Double
    /// The period the band is ANIMATED at. Always carries a number: a Kepler-ish guess
    /// off the synthesized band radius when the scan reported nothing, so the cloud
    /// shows differential rotation instead of turning rigidly.
    var periodDays: Double
    /// The orbital period the scan actually REPORTED, if it did. Distinct from
    /// `periodDays` because that one is a render value and is never nil — a dossier
    /// reading it would print an invention as a measurement.
    var reportedPeriodDays: Double? = nil
    /// Real orbital distance (km), where the scan gives one. Band placement goes through
    /// `orbitScene`, so nothing renders from this — but it is the one *measured* number
    /// a swarm member may carry, and hiding it while showing a synthesized period got
    /// the honesty exactly backwards.
    var orbitalDistanceKm: Double? = nil
    var phase0Deg: Double
    var displayRadius: Double
    var scanned: Bool
    /// An irregular satellite (`type` contains "captured"). Scatters wider (see
    /// `capturedInclinationFactor`) and drives the irregular impostor — the render reads
    /// this indirectly via the identical `type` check in `PlanetMaterial.irregularity`,
    /// the same function a promoted asteroid's irregularity/tumble go through. Retained
    /// as the model-level predicate (the swarm-placement math above reads it directly)
    /// even though the renderer re-derives the equivalent signal from `type`.
    var isCapturedAsteroid: Bool
    /// Moon-only: a subsurface ocean, which draws cryo-fracture lineae. Defaulted so
    /// existing call sites (tests) are unaffected.
    var hasSubsurfaceOcean: Bool = false
    /// Stable per-body surface-variability seed (hash of designation + rotation period),
    /// precomputed at construction like `displayRadius`'s `swarmSizeScale` — so the
    /// renderer doesn't re-hash every member's designation every frame the way a promoted
    /// moon's `OrreryPlanet.appearanceSeed` never has to.
    var appearanceSeed: Float
    var id: String { designation }
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
    /// The body's ring system, or nil when the scan reports none. Replaces the old
    /// bare `hasRing` flag, which nothing ever rendered.
    var rings: RingSystem?
    /// How the body turns — obliquity, rotation period, tidal lock. `.unknown` until
    /// scanned, which renders upright at the default rate.
    var spin: BodySpin = .unknown
    /// Moon-only: a subsurface ocean, which draws cryo-fracture lineae.
    var hasSubsurfaceOcean: Bool = false
    /// Moon-only: real orbital distance, which sets the orbit radius at body level.
    var orbitalDistanceKm: Double?
    /// The orbital period the scan actually REPORTED, if it did. `periodDays` above is
    /// the render value and is never nil (an unscanned moon gets an index ladder, a
    /// planet gets Kepler off its AU), so a dossier must read this one to keep from
    /// presenting a fallback as a measurement.
    var reportedPeriodDays: Double? = nil
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
    /// Notable-feature flags (mining sites / stored inventory) — drives a pip on the belt
    /// ring, matching the planet pips. Belts carry no devices/salvage/life in the model.
    var indicators: BodyIndicators = []
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
    /// The drilled planet's ring system, or nil when it reports none.
    var rings: RingSystem?
    /// How the drilled planet turns — see `OrreryPlanet.spin`.
    var spin: BodySpin = .unknown
    /// The pole the drilled planet's MOON ORBITS are built around — the same compressed
    /// pole its rings and surface use, so all three agree about where its equator is.
    /// `nil` means the moon plane is decoupled and stays in the orbital plane (the
    /// `decoupleMoonPlane` escape hatch), which is also what a system-level layer has.
    var orbitPole: SIMD3<Float>? = nil
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
    /// The drilled planet's own orbit around its star, carried so the body-level
    /// planet card can show the same Orbit / Year facts the system-level view had.
    /// `orbitalDistanceAu` is nil only when the parent scan gave no distance;
    /// `periodDays` is the SCAN-REPORTED year (nil until scanned).
    var orbitalDistanceAu: Double? = nil
    var periodDays: Double? = nil
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
    /// Moons that did not earn an orbit ring — drawn as an animated point band. Empty
    /// at system level and for any planet whose roster is small enough that every moon
    /// promotes. See `MoonTiering`.
    var swarm: [SwarmMoon] = []
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
