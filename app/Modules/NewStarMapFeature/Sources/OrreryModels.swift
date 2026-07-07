//
//  OrreryModels.swift
//  NewStarMapFeature
//
//  The Star System (orrery) presentation model, ported from the SceneKit
//  `StarMapFeature` (SystemModels.swift) so the Metal map stands alone. The core
//  types mirror the backend `SystemScanResponseSchema` family; `SystemModel` and
//  its `OrreryPlanet`/`OrreryMoon`/… add render-tuned fields (eccentricity,
//  period, phase, display radius/color, scene-unit orbits) authored for now,
//  pending a real bodies source.
//
//  Orbits/radii are in *orrery scene units* (≈ prototype pixels ÷ 10); the whole
//  system spans ~±45 units around the star and frames cleanly on fly-in. Here
//  those units map ≈ 1:1 to the map's light-year world around the focused star.
//
//  Internal to the module — only the renderer and HUD consume these.
//

import Foundation
import UniverseModels
import simd

// MARK: - API-shaped scan core

struct HabitableZone: Equatable, Sendable, Codable {
    var innerAu: Double
    var outerAu: Double
}

struct StarDetail: Equatable, Sendable, Codable {
    var designation: String
    var name: String
    var spectralType: String
    var color: String
    var temperatureK: Int
    var massSolar: Double
    var luminositySolar: Double
    var ageMy: Double
    var habitableZone: HabitableZone
    var position: Position
}

struct PlanetSummary: Equatable, Sendable, Codable {
    var designation: String
    var name: String
    var type: String
    var orbitalDistanceAu: Double
    var inHabitableZone: Bool
    var moonCount: Int
    var scanned: Bool
    var inventory: [InventoryItem]
}

struct AsteroidBeltDetail: Equatable, Sendable, Codable {
    var designation: String
    var innerRadiusAu: Double
    var outerRadiusAu: Double
    var density: String
    var resources: [String: String]
}

// MARK: - Presentation overlays

struct OrreryMoon: Equatable, Sendable {
    var orbitScene: Double
    var periodDays: Double
    var phase0Deg: Double
    var displayRadius: Double
    var colorHex: String
}

struct OrreryPlanet: Identifiable, Equatable, Sendable {
    var summary: PlanetSummary
    var semiMajorScene: Double        // orbit radius (scene units)
    var eccentricity: Double
    var periodDays: Double
    var phase0Deg: Double
    var displayRadius: Double
    var colorHex: String
    var hasRing: Bool
    var deviceCount: Int
    var lifeTier: LifeTier?
    var moons: [OrreryMoon]

    var id: String { summary.designation }
}

enum LagrangeKind: String, Equatable, Sendable {
    case inner, outer, trojan
}

struct LagrangePoint: Identifiable, Equatable, Sendable {
    var id: String
    var hostPlanetID: String
    var kind: LagrangeKind
    var deviceType: String?
    var label: String
    var t: Double? = nil
    var leadDeg: Double? = nil
}

struct StationedDevice: Identifiable, Equatable, Sendable {
    var code: String
    var type: String
    var at: String       // body designation or "belt"
    var status: String
    var label: String
    var id: String { code }
}

struct OrreryVessel: Identifiable, Equatable, Sendable {
    var code: String
    var name: String
    var kind: String
    var fromID: String   // body designation or "belt"
    var toID: String
    var t: Double        // 0…1 along the course
    var status: String
    var id: String { code }
}

/// Asteroid belt in scene units, plus the API detail for the HUD.
struct BeltModel: Equatable, Sendable {
    var innerScene: Double
    var outerScene: Double
    var mined: Bool
    var detail: AsteroidBeltDetail
}

/// The full orrery presentation aggregate for one system.
struct SystemModel: Equatable, Sendable {
    var star: StarDetail
    var sunRadiusScene: Double
    var sunColorHex: String
    var hzInnerScene: Double
    var hzOuterScene: Double
    var planets: [OrreryPlanet]
    var belt: BeltModel
    var lagrange: [LagrangePoint]
    var devices: [StationedDevice]
    var vessels: [OrreryVessel]
    var kuiperScene: Double      // compressed outer-system ring radius

    /// Scene-unit position of a body designation (or the belt mid-ring) at its
    /// phase0 — used to anchor vessel courses. Star is the origin.
    func anchorPosition(for id: String) -> SIMD3<Float> {
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
