//
//  DepletedSalvageTests.swift
//  LocationsFeature
//
//  A drained salvage site keeps its row so the engines can tell "drained" from
//  "never seen", but nothing the catalog shows a player counts or lists one.
//

import Foundation
import Testing
import UniverseModels

@testable import LocationsFeature

@Suite("Depleted salvage") struct DepletedSalvageTests {

    private func site(_ designation: String, depleted: Bool) -> SalvageSite {
        SalvageSite(designation: designation, name: nil, depleted: depleted)
    }

    private func system(planets: [Planet]) -> StarSystem {
        StarSystem(
            designation: "SOL", systemScanned: true, planetsScanned: 1, planetsTotal: 1,
            belts: [], planets: planets
        )
    }

    @Test func theSystemSummaryCountsOnlyUndepletedSalvage() {
        let planet = Planet(
            designation: "SOL-3", recon: .scanned,
            salvage: [site("SOL-3-SAL-1", depleted: false), site("SOL-3-SAL-2", depleted: true)]
        )
        let summary = SystemSummary(system(planets: [planet]))

        #expect(summary.salvageCount == 1)
    }

    @Test func aSystemWhoseSalvageIsAllDrainedCountsNone() {
        let planet = Planet(
            designation: "SOL-3", recon: .scanned,
            salvage: [site("SOL-3-SAL-1", depleted: true)]
        )
        #expect(SystemSummary(system(planets: [planet])).salvageCount == 0)
        #expect(system(planets: [planet]).remainingSalvageSites.isEmpty)
        // The row survives for anything that needs to know it was drained.
        #expect(system(planets: [planet]).allSalvageSites.count == 1)
    }

    @Test func aMoonsDrainedSalvageDropsOutOfItsPlanetsRollUp() {
        let moon = Moon(
            designation: "SOL-3-1", recon: .scanned,
            salvage: [site("SOL-3-1-SAL-1", depleted: true)]
        )
        let planet = Planet(
            designation: "SOL-3", recon: .scanned, moons: [moon],
            salvage: [site("SOL-3-SAL-1", depleted: false)]
        )

        #expect(planet.remainingSalvageSites.map(\.designation) == ["SOL-3-SAL-1"])
        #expect(planet.remainingSalvage.map(\.designation) == ["SOL-3-SAL-1"])
        #expect(moon.remainingSalvage.isEmpty)
        #expect(planet.allSalvageSites.count == 2)
    }

    /// The badge the list draws on a planet row.
    @Test func thePlanetRowBadgeExcludesDrainedSalvage() {
        let planet = Planet(
            designation: "SOL-3", recon: .scanned,
            salvage: [site("SOL-3-SAL-1", depleted: false), site("SOL-3-SAL-2", depleted: true)]
        )
        let node = LocationTree.planetNode(planet, LocationInventoryIndex(footprints: [:]))
        let salvageBadge = node.badges.first { $0.symbol == "wrench.and.screwdriver" }

        #expect(salvageBadge?.count == 1)
    }

    /// …and a planet with nothing left drops the badge entirely.
    @Test func thePlanetRowDropsTheBadgeWhenEverythingIsDrained() {
        let planet = Planet(
            designation: "SOL-3", recon: .scanned,
            salvage: [site("SOL-3-SAL-1", depleted: true)]
        )
        let node = LocationTree.planetNode(planet, LocationInventoryIndex(footprints: [:]))

        #expect(!node.badges.contains { $0.symbol == "wrench.and.screwdriver" })
    }
}
