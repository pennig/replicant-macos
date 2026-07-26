//
//  SalvageBodyUnitsTests.swift
//  UniverseModels
//
//  The gather_salvage picker offers bodies, so a body's worth is the sum of
//  every live site on it.
//

import Foundation
import Testing
@testable import UniverseModels

@Suite struct SalvageBodyUnitsTests {
    private func system() -> StarSystem {
        var system = StarSystem(designation: "TAANSI", recon: .visited)
        var planet = Planet(designation: "TAANSI-6")
        planet.salvage = [
            SalvageSite(
                designation: "TAANSI-6-SAL-1", location: "TAANSI-6",
                resourcesAvailable: ["conductive"], remainingPct: ["conductive": 50]
            ),
            SalvageSite(
                designation: "TAANSI-6-SAL-2", location: "TAANSI-6",
                resourcesAvailable: ["rares"], remainingPct: ["rares": 100]
            ),
        ]
        system.planets = [planet]
        return system
    }

    @Test func bodyUnitsSumEveryLiveSiteOnIt() {
        let bodies = system().salvageBodies(
            totals: ["TAANSI-6-SAL-1": ["conductive": 400], "TAANSI-6-SAL-2": ["rares": 100]]
        )
        #expect(bodies.count == 1)
        #expect(bodies[0].designation == "TAANSI-6")
        #expect(bodies[0].siteCount == 2)
        #expect(bodies[0].unitsRemaining == 300)   // 400×50% + 100×100%
    }

    @Test func bodyUnitsAreNilWithoutAnyAssay() {
        let bodies = system().salvageBodies(totals: [:])
        #expect(bodies[0].unitsRemaining == nil)
    }

    /// A partial assay still yields a figure — a floor, which the UI marks `~`.
    @Test func bodyUnitsCountOnlyTheAssayedSites() {
        let bodies = system().salvageBodies(totals: ["TAANSI-6-SAL-1": ["conductive": 400]])
        #expect(bodies[0].unitsRemaining == 200)
    }

    /// The no-argument form keeps working for callers that don't have assays.
    @Test func theArgumentlessFormStillWorks() {
        #expect(system().salvageBodies.first?.unitsRemaining == nil)
    }
}
