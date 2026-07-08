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

/// The full orrery presentation aggregate for one system.
struct SystemModel: Equatable, Sendable {
    var star: StarDetail
    var hzInnerScene: Double?
    var hzOuterScene: Double?
    var planets: [OrreryPlanet]
    var belts: [BeltModel]
    var hazards: [OrreryHazard]
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
