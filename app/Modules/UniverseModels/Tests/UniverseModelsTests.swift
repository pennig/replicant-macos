//
//  UniverseModelsTests.swift
//  UniverseModels
//
//  Decodes captured live `locations/{designation}` payloads through the catalog
//  DTO layer to lock the snake_case field mapping (convertFromSnakeCase) and the
//  DTO → domain assembly against the real server shapes.
//

import Foundation
import Testing
@testable import UniverseModels

@Suite struct UniverseModelsTests {
    @Test func positionDistanceIsEuclidean() {
        let a = Position(x: 0, y: 0, z: 0)
        let b = Position(x: 3, y: 4, z: 0)
        #expect(a.distance(to: b) == 5)
    }

    // MARK: - Location decode (captured live payloads)

    private func decode(_ json: String) throws -> RawLocation {
        try LocationDecoding.decoder.decode(RawLocation.self, from: Data(json.utf8))
    }

    @Test func starLevelDecodesRosterBeltsAndCounts() throws {
        let raw = try decode(Self.solStarJSON)
        let system = try #require(raw.starSystem())

        #expect(system.designation == "SOL")
        #expect(system.star?.stellarClass == "G2")
        #expect(system.star?.miningBonusPct == 20)
        #expect(system.systemScanned == true)
        #expect(system.planetsTotal == 8)
        // `asteroid_belt` (star-level key) must map, not fall on the floor.
        #expect(system.belts.count == 1)
        #expect(system.belts.first?.designation == "SOL-BELT-1")
        #expect(system.belts.first?.richness["silicates"] == "high")
        // Roster planet: scanned SOL-3 in the habitable zone with one moon.
        let earth = try #require(system.planets.first { $0.designation == "SOL-3" })
        #expect(earth.type == "Terrestrial")
        #expect(earth.recon == .scanned)
        #expect(earth.moonCount == 1)
        // All planets scanned + systemScanned ⇒ system reads as fully scanned.
        #expect(system.recon == .scanned)
    }

    @Test func beltLevelDecodesSitesRemainingAndInventory() throws {
        let raw = try decode(Self.beltJSON)
        let detail = try #require(raw.bodyDetail())
        guard case .belt(let belt) = detail else { Issue.record("expected belt"); return }

        #expect(belt.designation == "SOL-BELT-1")
        #expect(belt.sites.count == 2)
        // `resources_remaining_pct` map must survive snake→camel.
        #expect(belt.sites.first?.remaining["carbon"] == 100)
        #expect(belt.sites.first?.siteIndex == 0)
        // Accumulated stock is distinct from sites.
        #expect(belt.inventory.contains { $0.resourceType == "rares" && $0.quantity == 153 })
    }

    @Test func planetSalvageDecodesAsOwnType() throws {
        // BETSU-3 roster entry carries a salvage site (research station).
        let raw = try decode(Self.betsuStarJSON)
        let system = try #require(raw.starSystem())
        let b3 = try #require(system.planets.first { $0.designation == "BETSU-3" })
        let salvage = try #require(b3.salvage.first)
        #expect(salvage.designation == "BETSU-3-SAL-1")
        #expect(salvage.salvageType == "research_station")
        #expect(salvage.resourcesAvailable.contains("conductive"))
        #expect(salvage.depleted == false)
        // Salvage bubbles up to the system roll-up.
        #expect(system.allSalvageSites.contains { $0.designation == "BETSU-3-SAL-1" })
    }

    @Test func applyingMoonDetailPreservesSiblingMoons() {
        // A planet already hydrated with two moons; scanning one must not drop
        // the other (regression: the reducer used to rebuild from the moonless
        // star roster and clobber the sibling).
        let system = StarSystem(
            designation: "SOL",
            planets: [
                Planet(
                    designation: "SOL-3", recon: .scanned,
                    moons: [Moon(designation: "SOL-3-1"), Moon(designation: "SOL-3-2")]
                )
            ]
        )
        let detailed = BodyDetail.moon(
            Moon(designation: "SOL-3-1", type: "Rocky", recon: .scanned,
                 physical: BodyPhysical(massEarth: 0.0123))
        )
        let merged = system.applying(detailed)
        let planet = merged.planets.first { $0.designation == "SOL-3" }
        #expect(planet?.moons.map(\.designation) == ["SOL-3-1", "SOL-3-2"])
        #expect(planet?.moons.first { $0.designation == "SOL-3-1" }?.physical?.massEarth == 0.0123)
    }

    @Test func footprintDecodesCounts() throws {
        let raw = try LocationDecoding.decoder.decode(RawFootprint.self, from: Data(Self.footprintJSON.utf8))
        let counts = (raw.locations ?? [:]).mapValues(\.domain)
        #expect(counts["SOL-3"]?.devices == 1)
        #expect(counts["ATIANFU-BELT-1"]?.resources == 1577)
    }
}

// MARK: - Captured fixtures (trimmed from live `replicant raw GET`)

extension UniverseModelsTests {
    static let solStarJSON = """
    {
      "planets_scanned": 8, "moons_scanned": 28, "system_scanned": true,
      "location": "SOL", "location_type": "star", "planets_total": 8, "moons_total": 28,
      "moons_total_estimated": false, "entry_point": "SOL-5-L4",
      "star": { "age_my": 4600, "color": "yellow-white", "stellar_class": "G2",
                "distance_from_sol": 0, "mining_bonus_pct": 20, "designation": "SOL",
                "position": { "x": 0, "y": 0, "z": 0 } },
      "planets": [
        { "scanned": true, "type": "Barren", "type_estimated": false, "moon_count": 0,
          "designation": "SOL-1", "orbital_distance_au": 0.387, "inventory": [] },
        { "scanned": true, "type": "Terrestrial", "type_estimated": false, "moon_count": 1,
          "designation": "SOL-3", "orbital_distance_au": 1, "in_habitable_zone": true, "inventory": [] }
      ],
      "asteroid_belt": { "present": true, "belts": [
        { "density": "moderate", "inner_radius_au": 2.1, "outer_radius_au": 3.3,
          "designation": "SOL-BELT-1",
          "resources": { "carbon": "moderate", "silicates": "high", "structural": "moderate" } }
      ] }
    }
    """

    static let beltJSON = """
    {
      "location": "SOL-BELT-1", "location_type": "belt",
      "resource_sites": [
        { "site_index": 0, "designation": "SOL-BELT-1-SITE-0", "name": "SOL-BELT-1 Primary Site",
          "resources_remaining_pct": { "carbon": 100, "silicates": 100, "rares": 100 } },
        { "site_index": 3, "designation": "SOL-BELT-1-SITE-3", "name": "SOL-BELT-1 Site 3",
          "resources_remaining_pct": { "carbon": 100 } }
      ],
      "devices": [], "inventory": [ { "quantity": 153, "resource_type": "rares" } ],
      "belt": { "density": "moderate", "inner_radius_au": 2.1, "outer_radius_au": 3.3,
                "designation": "SOL-BELT-1", "resources": { "carbon": "moderate" } }
    }
    """

    static let betsuStarJSON = """
    {
      "location": "BETSU", "location_type": "star", "system_scanned": true,
      "planets_scanned": 10, "planets_total": 10,
      "star": { "stellar_class": "K2", "color": "Orange", "designation": "BETSU",
                "distance_from_sol": 37.47, "position": { "x": -8.7, "y": -36.4, "z": -1.5 } },
      "planets": [
        { "scanned": true, "type": "Desert World", "type_estimated": false, "moon_count": 1,
          "designation": "BETSU-3", "orbital_distance_au": 0.37, "inventory": [],
          "salvage": [ { "resources_available": ["conductive", "silicates", "rares"],
                         "depleted": false, "salvage_type": "research_station",
                         "designation": "BETSU-3-SAL-1", "location": "BETSU-3",
                         "name": "Abandoned Research Station" } ] }
      ]
    }
    """

    static let footprintJSON = """
    {
      "locations": {
        "SOL-3": { "location_events": 1, "devices": 1, "resource_sites": 0, "resources": 0, "replicants": 1 },
        "ATIANFU-BELT-1": { "location_events": 0, "devices": 1, "resource_sites": 0, "resources": 1577, "replicants": 0 }
      }
    }
    """
}
