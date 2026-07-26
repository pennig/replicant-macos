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

    // MARK: - Assayed but not hydrated

    /// A body whose salvage arrived from the star-level fetch, a scan event, or
    /// a discovery event has names and totals but no percentages — the common
    /// case, since only `GET locations/{body}` supplies percentages. The picker
    /// must still say something: what was discovered there, kept apart from the
    /// live figure it isn't.
    private func unhydratedSystem() -> StarSystem {
        var system = StarSystem(designation: "TAANSI", recon: .visited)
        var planet = Planet(designation: "TAANSI-6")
        planet.salvage = [
            SalvageSite(
                designation: "TAANSI-6-SAL-1", location: "TAANSI-6",
                resourcesAvailable: ["conductive", "rares"]
            )
        ]
        system.planets = [planet]
        return system
    }

    @Test func anUnhydratedBodyReportsWhatWasDiscoveredOnIt() {
        let bodies = unhydratedSystem().salvageBodies(
            totals: ["TAANSI-6-SAL-1": ["conductive": 331, "rares": 99]]
        )
        #expect(bodies.count == 1)
        #expect(bodies[0].discoveredTotal == 430)
        // Not a live figure, and never conflated with one.
        #expect(bodies[0].unitsRemaining == nil)
    }

    /// No assay at all is still unknown, not zero — the picker stays silent.
    @Test func anUnassayedBodyReportsNeitherFigure() {
        let bodies = unhydratedSystem().salvageBodies(totals: [:])
        #expect(bodies[0].discoveredTotal == nil)
        #expect(bodies[0].unitsRemaining == nil)
    }

    /// Once percentages arrive the live figure takes over and the discovered
    /// one falls away, so the two can never be summed or shown together.
    @Test func aHydratedBodyReportsLiveUnitsAndNoDiscoveredTotal() {
        let bodies = system().salvageBodies(
            totals: ["TAANSI-6-SAL-1": ["conductive": 400], "TAANSI-6-SAL-2": ["rares": 100]]
        )
        #expect(bodies[0].unitsRemaining == 300)
        #expect(bodies[0].discoveredTotal == nil)
    }
}
