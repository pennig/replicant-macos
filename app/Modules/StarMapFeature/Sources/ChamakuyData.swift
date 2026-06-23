//
//  ChamakuyData.swift
//  StarMapFeature
//
//  Seed orrery for Chamakuy, adapted from the prototype's SYS_* tables in
//  `galaxy-data.jsx`. Scene units are prototype pixels ÷ 10.
//
//  Per the handoff spec's open question #1, Chamakuy is the only modeled
//  system; drilling into another scanned system reuses this orrery relabeled
//  with that star's identity. `model(for:)` does that relabeling.
//

import Foundation

public enum ChamakuyData {

    /// The orrery to show when drilling into `system`. Chamakuy is exact; other
    /// systems reuse it relabeled (pending per-system bodies).
    public static func model(for system: GalaxySystem) -> SystemModel {
        var model = chamakuy
        model.star.designation = system.id
        model.star.name = system.name
        model.star.spectralType = system.spectralType
        model.star.color = system.star.color
        model.star.position = system.position
        model.sunColorHex = system.isCurrentLocation ? "#ffb648" : system.star.color
        return model
    }

    public static let chamakuy = SystemModel(
        star: StarDetail(
            designation: "CHK",
            name: "Chamakuy",
            spectralType: "K2 V",
            color: "#ffb648",
            temperatureK: 4800,
            massSolar: 0.78,
            luminositySolar: 0.34,
            ageMy: 5400,
            habitableZone: HabitableZone(innerAu: 0.45, outerAu: 0.75),
            position: GalaxyData.system("CHK")?.position ?? Position(x: 0, y: 0, z: 0)
        ),
        sunRadiusScene: 2.6,
        sunColorHex: "#ffb648",
        hzInnerScene: 15.0,
        hzOuterScene: 23.2,
        planets: [
            OrreryPlanet(
                summary: PlanetSummary(
                    designation: "I", name: "Vash", type: "Rocky",
                    orbitalDistanceAu: 0.22, inHabitableZone: false, moonCount: 0,
                    scanned: true, inventory: [InventoryItem(resourceType: "Silicates", quantity: 320)]
                ),
                semiMajorScene: 9.6, eccentricity: 0.97, periodDays: 22, phase0Deg: 35,
                displayRadius: 0.55, colorHex: "#b08868", hasRing: false,
                deviceCount: 0, lifeTier: nil, moons: []
            ),
            OrreryPlanet(
                summary: PlanetSummary(
                    designation: "II", name: "Orrun", type: "Terran",
                    orbitalDistanceAu: 0.58, inHabitableZone: true, moonCount: 1,
                    scanned: true, inventory: [
                        InventoryItem(resourceType: "Carbon", quantity: 880),
                        InventoryItem(resourceType: "Ice", quantity: 1240),
                    ]
                ),
                semiMajorScene: 18.8, eccentricity: 0.95, periodDays: 48, phase0Deg: 205,
                displayRadius: 0.9, colorHex: "#5fa3b0", hasRing: false,
                deviceCount: 2, lifeTier: .flora,
                moons: [OrreryMoon(orbitScene: 1.8, periodDays: 7, phase0Deg: 80, displayRadius: 0.22, colorHex: "#9aa6bc")]
            ),
            OrreryPlanet(
                summary: PlanetSummary(
                    designation: "III", name: "Cael", type: "Arid",
                    orbitalDistanceAu: 1.1, inHabitableZone: false, moonCount: 0,
                    scanned: true, inventory: [InventoryItem(resourceType: "Iron", quantity: 540)]
                ),
                semiMajorScene: 30.0, eccentricity: 0.93, periodDays: 96, phase0Deg: 320,
                displayRadius: 0.7, colorHex: "#c98b5a", hasRing: false,
                deviceCount: 1, lifeTier: nil, moons: []
            ),
            OrreryPlanet(
                summary: PlanetSummary(
                    designation: "IV", name: "Thessaly", type: "Gas giant",
                    orbitalDistanceAu: 3.1, inHabitableZone: false, moonCount: 2,
                    scanned: true, inventory: []
                ),
                semiMajorScene: 40.8, eccentricity: 0.9, periodDays: 168, phase0Deg: 122,
                displayRadius: 1.7, colorHex: "#caa06a", hasRing: true,
                deviceCount: 0, lifeTier: nil,
                moons: [
                    OrreryMoon(orbitScene: 3.0, periodDays: 9, phase0Deg: 20, displayRadius: 0.26, colorHex: "#cdd6e6"),
                    OrreryMoon(orbitScene: 4.4, periodDays: 15, phase0Deg: 200, displayRadius: 0.3, colorHex: "#a89a86"),
                ]
            ),
        ],
        belt: BeltModel(
            innerScene: 33.2, outerScene: 37.2, mined: true,
            detail: AsteroidBeltDetail(
                designation: "CHK-BELT-1", innerRadiusAu: 2.2, outerRadiusAu: 2.5,
                density: "Moderate", resources: ["Iron": "Abundant", "Rares": "Trace", "Silicates": "Common"]
            )
        ),
        lagrange: [
            LagrangePoint(id: "L1", hostPlanetID: "IV", kind: .inner, deviceType: "surge_plate",
                          label: "Surge corridor anchor", t: 0.86),
            LagrangePoint(id: "L2", hostPlanetID: "IV", kind: .outer, deviceType: nil,
                          label: "Shadow station candidate", t: 1.14),
            LagrangePoint(id: "L4", hostPlanetID: "IV", kind: .trojan, deviceType: nil,
                          label: "Trojan cluster · stable", leadDeg: 60),
            LagrangePoint(id: "L5", hostPlanetID: "IV", kind: .trojan, deviceType: "ftl_relay",
                          label: "Relay node · Chamakuy-Gate", leadDeg: -60),
        ],
        devices: [
            StationedDevice(code: "B58FCC78", type: "mining_drone", at: "belt", status: "mining", label: "Mining Drone"),
            StationedDevice(code: "1A9C77E2", type: "mining_drone", at: "belt", status: "idle", label: "Mining Drone"),
            StationedDevice(code: "22D7E5A9", type: "forge", at: "II", status: "printing", label: "Forge"),
            StationedDevice(code: "A1F00C2D", type: "survey_probe", at: "III", status: "prospecting", label: "Survey Probe"),
            StationedDevice(code: "7C0E9B41", type: "ftl_relay", at: "L5", status: "relaying", label: "FTL Relay"),
            StationedDevice(code: "E70D4491", type: "surge_plate", at: "L1", status: "inactive", label: "Surge Plate"),
        ],
        vessels: [
            OrreryVessel(code: "C1D9F0A2", name: "HEAVEN", kind: "vessel", fromID: "II", toID: "IV", t: 0.42, status: "cruising"),
            OrreryVessel(code: "9E33B70F", name: "Hauler", kind: "hauler", fromID: "belt", toID: "II", t: 0.66, status: "cruising"),
            OrreryVessel(code: "D4A2110B", name: "Drone", kind: "mining_drone", fromID: "belt", toID: "III", t: 0.2, status: "travelling"),
        ],
        kuiperScene: 45.0
    )
}
