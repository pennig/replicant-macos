//
//  GalaxyData.swift
//  StarMapFeature
//
//  Static seed for the Galaxy Explorer, adapted from the prototype's
//  `galaxy-data.jsx` (GAL_SYSTEMS / GAL_LINKS) into the API-shaped models.
//
//  The prototype placed systems on a tilted 2D disc via (bearing, radius,
//  height). Here those drive a real 3D `Position` — the SceneKit camera does
//  the projection — so the disc reads naturally when the camera is tilted.
//
//  Fields the stars-list schema does not carry (distance, travel time, planet
//  estimate, per-system color) are derived here with simple, commented
//  heuristics and will be replaced by real values once the map is API-backed.
//

import Foundation

public enum GalaxyData {

    /// 1.0 "radius from core" maps to this many scene units.
    static let scale: Double = 100

    /// The 16 charted systems. Home is Chamakuy (CHK).
    public static let systems: [GalaxySystem] = build()

    /// FTL relay mesh: 3 active mine + 1 planned mine + 1 npc.
    public static let relays: [RelayLink] = [
        RelayLink(a: "CHK", b: "TRZ", owner: .mine),
        RelayLink(a: "CHK", b: "VLZ", owner: .mine),
        RelayLink(a: "VLZ", b: "NRK", owner: .mine),
        RelayLink(a: "CHK", b: "COR", owner: .mine, planned: true),
        RelayLink(a: "OBR", b: "TYR", owner: .npc),
    ]

    /// Look up a seeded system by designation.
    public static func system(_ id: String) -> GalaxySystem? {
        systems.first { $0.id == id }
    }

    // MARK: - Seed rows (verbatim from the prototype)

    /// (designation, name, bearing°, radius, height, recon, life, resource,
    ///  devices, vessels, presence, relay, home, spectral)
    private struct Row {
        let id: String, name: String
        let a: Double, r: Double, h: Double
        let recon: Recon
        let life: LifeTier?
        let resource: Double
        let devices: Int, vessels: Int
        let presence: Presence?
        let relay: Bool
        let home: Bool
        let cls: String
    }

    private static let rows: [Row] = [
        Row(id: "CHK", name: "Chamakuy",  a: 202, r: 0.12, h:  0.00, recon: .scanned, life: .flora,     resource: 0.72, devices: 6,  vessels: 1, presence: .mine, relay: true,  home: true,  cls: "K2 V"),
        Row(id: "TRZ", name: "Tarazedar", a: 150, r: 0.33, h:  0.06, recon: .scanned, life: nil,        resource: 0.86, devices: 4,  vessels: 1, presence: .mine, relay: true,  home: false, cls: "G8 V"),
        Row(id: "VLZ", name: "Velzan",    a: 256, r: 0.31, h: -0.09, recon: .scanned, life: .fauna,     resource: 0.50, devices: 14, vessels: 0, presence: .mine, relay: true,  home: false, cls: "M1 V"),
        Row(id: "SEL", name: "Selay",     a: 108, r: 0.53, h:  0.13, recon: .visited, life: .microbial, resource: 0.40, devices: 3,  vessels: 1, presence: .mine, relay: false, home: false, cls: "K5 V"),
        Row(id: "NRK", name: "Narak",     a: 302, r: 0.50, h: -0.16, recon: .visited, life: nil,        resource: 0.30, devices: 2,  vessels: 0, presence: .mine, relay: true,  home: false, cls: "M3 V"),
        Row(id: "COR", name: "Corvan",    a: 238, r: 0.42, h:  0.17, recon: .scanned, life: nil,        resource: 0.55, devices: 1,  vessels: 0, presence: .mine, relay: false, home: false, cls: "F9 V"),
        Row(id: "OBR", name: "Obros",     a:  32, r: 0.46, h:  0.05, recon: .scanned, life: .flora,     resource: 0.62, devices: 0,  vessels: 0, presence: .npc,  relay: true,  home: false, cls: "G2 V"),
        Row(id: "PEN", name: "Penh",      a:  94, r: 0.27, h: -0.12, recon: .scanned, life: .fauna,     resource: 0.45, devices: 0,  vessels: 0, presence: .npc,  relay: false, home: false, cls: "K0 V"),
        Row(id: "TYR", name: "Tyrrho",    a: 272, r: 0.74, h: -0.20, recon: .aware,   life: nil,        resource: 0.60, devices: 0,  vessels: 0, presence: .npc,  relay: true,  home: false, cls: "B7 V"),
        Row(id: "KET", name: "Kethra",    a:  68, r: 0.70, h: -0.10, recon: .aware,   life: nil,        resource: 0.92, devices: 0,  vessels: 0, presence: nil,   relay: false, home: false, cls: "M0 V"),
        Row(id: "SIL", name: "Silane",    a: 344, r: 0.66, h:  0.19, recon: .aware,   life: .microbial, resource: 0.50, devices: 0,  vessels: 0, presence: nil,   relay: false, home: false, cls: "A3 V"),
        Row(id: "DRO", name: "Drost",     a: 220, r: 0.62, h:  0.21, recon: .visited, life: nil,        resource: 0.38, devices: 0,  vessels: 0, presence: nil,   relay: false, home: false, cls: "G0 V"),
        Row(id: "VEY", name: "Veyln",     a: 178, r: 0.82, h: -0.05, recon: .aware,   life: nil,        resource: 0.78, devices: 0,  vessels: 0, presence: nil,   relay: false, home: false, cls: "K3 V"),
        Row(id: "MOR", name: "Morrow",    a:  18, r: 0.86, h:  0.11, recon: .aware,   life: nil,        resource: 0.42, devices: 0,  vessels: 0, presence: nil,   relay: false, home: false, cls: "M4 V"),
        Row(id: "ACH", name: "Achen",     a: 128, r: 0.90, h:  0.16, recon: .aware,   life: .flora,     resource: 0.50, devices: 0,  vessels: 0, presence: nil,   relay: false, home: false, cls: "F2 V"),
        Row(id: "ULX", name: "Ulix",      a: 320, r: 0.90, h:  0.04, recon: .aware,   life: nil,        resource: 0.66, devices: 0,  vessels: 0, presence: nil,   relay: false, home: false, cls: "O9 V"),
    ]

    // MARK: - Build

    private static func build() -> [GalaxySystem] {
        // Resolve the home position first so distances are measured from it.
        let homeRow = rows.first { $0.home } ?? rows[0]
        let homePos = position(for: homeRow)

        return rows.map { row in
            let pos = position(for: row)
            // ~0.25 light-years per scene unit (approximate, pending real data).
            let distanceLY = pos.distance(to: homePos) * 0.25
            let star = StarItem(
                designation: row.id,
                spectralType: row.cls,
                color: spectralColorHex(row.cls),
                distanceFromReplicant: (distanceLY * 10).rounded() / 10,
                estimatedTravelTime: Int(distanceLY * 3600),  // ~1h per LY (placeholder)
                position: pos,
                estimatedPlanets: estimatedPlanets(for: row),
                explored: row.recon != .aware,
                hasLife: row.life != nil,
                entryPoint: row.relay ? "\(row.id)-GATE" : nil
            )
            return GalaxySystem(
                star: star,
                name: row.name,
                recon: row.recon,
                lifeTier: row.life,
                resourceRichness: row.resource,
                deviceCount: row.devices,
                vesselCount: row.vessels,
                presence: row.presence,
                hasRelay: row.relay,
                isCurrentLocation: row.home
            )
        }
    }

    /// (bearing, radius, height) → 3D position on the galactic disc.
    private static func position(for row: Row) -> Position {
        let ang = row.a * .pi / 180
        return Position(
            x: cos(ang) * row.r * scale,
            y: row.h * scale,
            z: sin(ang) * row.r * scale
        )
    }

    /// Deterministic planet estimate; Chamakuy's real count (4) is known.
    private static func estimatedPlanets(for row: Row) -> Int {
        if row.id == "CHK" { return 4 }
        let charSum = row.id.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return 2 + (charSum % 6)   // 2…7
    }

    /// Approximate sRGB color for a spectral class (O→M = blue→red). Domain
    /// data, not UI chrome — the home star is recolored to the accent in-scene.
    static func spectralColorHex(_ spectral: String) -> String {
        switch spectral.first {
        case "O": "#9bb0ff"
        case "B": "#aabfff"
        case "A": "#cad7ff"
        case "F": "#f8f7ff"
        case "G": "#fff4ea"
        case "K": "#ffd2a1"
        case "M": "#ffb56c"
        default:  "#ffe6b0"
        }
    }
}
