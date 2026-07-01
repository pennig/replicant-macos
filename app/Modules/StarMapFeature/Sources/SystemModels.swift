//
//  SystemModels.swift
//  StarMapFeature
//
//  The Star System (orrery) data model. The core types mirror the backend
//  `SystemScanResponseSchema` family so seed and (later) live scan data share
//  one shape:
//    - `StarDetail`        ← app_schemas_scanning_StarDetailSchema
//    - `HabitableZone`     ← app_schemas_scanning_HabitableZoneSchema
//    - `PlanetSummary`     ← app_schemas_scanning_PlanetSummarySchema
//    - `AsteroidBeltDetail`← app_schemas_scanning_AsteroidBeltDetailSchema
//
//  (`InventoryItem` moved to `UniverseModels` — shared with the locations catalog.)
//
//  `SystemModel` (and its `OrreryPlanet`/`OrreryMoon`/`LagrangePoint`/`Vessel`)
//  is the presentation model the orrery renders. It carries render-tuned fields
//  the scan schema does not (eccentricity, period, phase, display radius/color,
//  rings, scene-unit orbits) — authored for now, pending a real bodies source.
//
//  Orbits/radii are in *orrery scene units* (≈ prototype pixels ÷ 10) so the
//  whole system spans ~±41 units around the star and frames cleanly when the
//  camera flies in.
//

import Foundation
import UniverseModels

// MARK: - API-shaped scan core

public struct HabitableZone: Equatable, Sendable, Codable {
    public var innerAu: Double
    public var outerAu: Double
    public init(innerAu: Double, outerAu: Double) {
        self.innerAu = innerAu
        self.outerAu = outerAu
    }
}

public struct StarDetail: Equatable, Sendable, Codable {
    public var designation: String
    public var name: String
    public var spectralType: String
    public var color: String
    public var temperatureK: Int
    public var massSolar: Double
    public var luminositySolar: Double
    public var ageMy: Double
    public var habitableZone: HabitableZone
    public var position: Position

    public init(
        designation: String, name: String, spectralType: String, color: String,
        temperatureK: Int, massSolar: Double, luminositySolar: Double, ageMy: Double,
        habitableZone: HabitableZone, position: Position
    ) {
        self.designation = designation
        self.name = name
        self.spectralType = spectralType
        self.color = color
        self.temperatureK = temperatureK
        self.massSolar = massSolar
        self.luminositySolar = luminositySolar
        self.ageMy = ageMy
        self.habitableZone = habitableZone
        self.position = position
    }
}

public struct PlanetSummary: Equatable, Sendable, Codable {
    public var designation: String
    public var name: String
    public var type: String
    public var orbitalDistanceAu: Double
    public var inHabitableZone: Bool
    public var moonCount: Int
    public var scanned: Bool
    public var inventory: [InventoryItem]

    public init(
        designation: String, name: String, type: String, orbitalDistanceAu: Double,
        inHabitableZone: Bool, moonCount: Int, scanned: Bool, inventory: [InventoryItem]
    ) {
        self.designation = designation
        self.name = name
        self.type = type
        self.orbitalDistanceAu = orbitalDistanceAu
        self.inHabitableZone = inHabitableZone
        self.moonCount = moonCount
        self.scanned = scanned
        self.inventory = inventory
    }
}

public struct AsteroidBeltDetail: Equatable, Sendable, Codable {
    public var designation: String
    public var innerRadiusAu: Double
    public var outerRadiusAu: Double
    public var density: String
    public var resources: [String: String]

    public init(
        designation: String, innerRadiusAu: Double, outerRadiusAu: Double,
        density: String, resources: [String: String]
    ) {
        self.designation = designation
        self.innerRadiusAu = innerRadiusAu
        self.outerRadiusAu = outerRadiusAu
        self.density = density
        self.resources = resources
    }
}

// MARK: - Presentation overlays

public struct OrreryMoon: Equatable, Sendable {
    public var orbitScene: Double
    public var periodDays: Double
    public var phase0Deg: Double
    public var displayRadius: Double
    public var colorHex: String
    public init(orbitScene: Double, periodDays: Double, phase0Deg: Double, displayRadius: Double, colorHex: String) {
        self.orbitScene = orbitScene
        self.periodDays = periodDays
        self.phase0Deg = phase0Deg
        self.displayRadius = displayRadius
        self.colorHex = colorHex
    }
}

public struct OrreryPlanet: Identifiable, Equatable, Sendable {
    public var summary: PlanetSummary       // mirrors PlanetSummarySchema
    public var semiMajorScene: Double        // orbit radius (scene units)
    public var eccentricity: Double
    public var periodDays: Double
    public var phase0Deg: Double
    public var displayRadius: Double
    public var colorHex: String
    public var hasRing: Bool
    public var deviceCount: Int
    public var lifeTier: LifeTier?
    public var moons: [OrreryMoon]

    public var id: String { summary.designation }

    public init(
        summary: PlanetSummary, semiMajorScene: Double, eccentricity: Double,
        periodDays: Double, phase0Deg: Double, displayRadius: Double, colorHex: String,
        hasRing: Bool, deviceCount: Int, lifeTier: LifeTier?, moons: [OrreryMoon]
    ) {
        self.summary = summary
        self.semiMajorScene = semiMajorScene
        self.eccentricity = eccentricity
        self.periodDays = periodDays
        self.phase0Deg = phase0Deg
        self.displayRadius = displayRadius
        self.colorHex = colorHex
        self.hasRing = hasRing
        self.deviceCount = deviceCount
        self.lifeTier = lifeTier
        self.moons = moons
    }
}

public enum LagrangeKind: String, Equatable, Sendable {
    case inner, outer, trojan
}

/// A lagrange point of a host planet. `t` (for inner/outer, fraction of the
/// host's orbit radius along the star–planet line) or `leadDeg` (for trojans,
/// ±60°) positions it relative to the host's orbit-parent.
public struct LagrangePoint: Identifiable, Equatable, Sendable {
    public var id: String
    public var hostPlanetID: String
    public var kind: LagrangeKind
    public var deviceType: String?
    public var label: String
    public var t: Double?
    public var leadDeg: Double?

    public init(
        id: String, hostPlanetID: String, kind: LagrangeKind, deviceType: String?,
        label: String, t: Double? = nil, leadDeg: Double? = nil
    ) {
        self.id = id
        self.hostPlanetID = hostPlanetID
        self.kind = kind
        self.deviceType = deviceType
        self.label = label
        self.t = t
        self.leadDeg = leadDeg
    }
}

public struct StationedDevice: Identifiable, Equatable, Sendable {
    public var code: String
    public var type: String
    public var at: String       // body designation or "belt"
    public var status: String
    public var label: String
    public var id: String { code }

    public init(code: String, type: String, at: String, status: String, label: String) {
        self.code = code
        self.type = type
        self.at = at
        self.status = status
        self.label = label
    }
}

public struct OrreryVessel: Identifiable, Equatable, Sendable {
    public var code: String
    public var name: String
    public var kind: String
    public var fromID: String   // body designation or "belt"
    public var toID: String
    public var t: Double        // 0…1 along the course
    public var status: String
    public var id: String { code }

    public init(code: String, name: String, kind: String, fromID: String, toID: String, t: Double, status: String) {
        self.code = code
        self.name = name
        self.kind = kind
        self.fromID = fromID
        self.toID = toID
        self.t = t
        self.status = status
    }
}

/// Asteroid belt in scene units, plus the API detail for the HUD.
public struct BeltModel: Equatable, Sendable {
    public var innerScene: Double
    public var outerScene: Double
    public var mined: Bool
    public var detail: AsteroidBeltDetail
    public init(innerScene: Double, outerScene: Double, mined: Bool, detail: AsteroidBeltDetail) {
        self.innerScene = innerScene
        self.outerScene = outerScene
        self.mined = mined
        self.detail = detail
    }
}

/// The full orrery presentation aggregate for one system.
public struct SystemModel: Equatable, Sendable {
    public var star: StarDetail
    public var sunRadiusScene: Double
    public var sunColorHex: String
    public var hzInnerScene: Double
    public var hzOuterScene: Double
    public var planets: [OrreryPlanet]
    public var belt: BeltModel
    public var lagrange: [LagrangePoint]
    public var devices: [StationedDevice]
    public var vessels: [OrreryVessel]
    public var kuiperScene: Double      // compressed outer-system ring radius

    public init(
        star: StarDetail, sunRadiusScene: Double, sunColorHex: String,
        hzInnerScene: Double, hzOuterScene: Double, planets: [OrreryPlanet],
        belt: BeltModel, lagrange: [LagrangePoint], devices: [StationedDevice],
        vessels: [OrreryVessel], kuiperScene: Double
    ) {
        self.star = star
        self.sunRadiusScene = sunRadiusScene
        self.sunColorHex = sunColorHex
        self.hzInnerScene = hzInnerScene
        self.hzOuterScene = hzOuterScene
        self.planets = planets
        self.belt = belt
        self.lagrange = lagrange
        self.devices = devices
        self.vessels = vessels
        self.kuiperScene = kuiperScene
    }

    /// Scene-unit position of a body designation (or the belt mid-ring) at its
    /// phase0 — used to anchor vessel courses. Star is the origin.
    public func anchorPosition(for id: String) -> SIMD3<Float> {
        if id == "belt" {
            let r = Float((belt.innerScene + belt.outerScene) / 2)
            return SIMD3(r, 0, 0)
        }
        guard let planet = planets.first(where: { $0.id == id }) else { return .zero }
        let a = Float(planet.phase0Deg) * .pi / 180
        let r = Float(planet.semiMajorScene)
        return SIMD3(cos(a) * r, 0, sin(a) * r)
    }
}
