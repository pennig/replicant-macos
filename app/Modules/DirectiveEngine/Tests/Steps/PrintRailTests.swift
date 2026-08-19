//
//  PrintRailTests.swift
//  Replicould — DirectiveEngine
//
//  The reserve rail's own bounds and its census gate, driven directly rather
//  than through a mission — the staleness boundary in particular, which no
//  mission suite reaches on its own value.
//

import Foundation
import Testing
import UniverseModels

@testable import DirectiveEngine

private let fixtureNow = Date(timeIntervalSince1970: 100_000)

private func snapshot(footprints: [String: LocationFootprint] = [:]) -> WorldSnapshot {
    WorldSnapshot(
        devices: [:], openOperations: [:], log: [], dispatchedOperations: [:],
        systems: [:], siteAssays: [:], footprints: footprints, now: fixtureNow
    )
}

private func footprint(
    _ location: String, resources: Int = 999_999, fetchedAt: Date
) -> LocationFootprint {
    LocationFootprint(
        location: location, devices: 1, resources: resources, resourceSites: 0,
        locationEvents: 0, replicants: 0, fetchedAt: fetchedAt
    )
}

@Suite("Print rail")
struct PrintRailTests {
    // MARK: - The two bounds

    /// The rail's own roots. Every other reader — the six print sites and
    /// `RelayRun`'s two aliases — writes its fixture RELATIVE to these, so
    /// without this nothing in the engine notices either value change.
    @Test("the rail's two bounds are the roots every print site gates on")
    func theBoundsAreTheRoots() {
        #expect(PrintRail.pollInterval == 60)
        #expect(PrintRail.hubFreshness == 5 * 60)
    }

    // MARK: - The census gate

    /// `footprintCensusIsStale` on its own value, at the boundary. The bound is
    /// `>`, so a census exactly `pollInterval` old is still believed; one second
    /// past it buys a refresh at all six print sites.
    @Test("the census gate turns over one second past the poll interval")
    func theCensusGateTurnsOverAtItsBound() {
        let rail = PrintRail(reserveFloor: 500)
        func stale(ageSeconds: TimeInterval) -> Bool {
            rail.footprintCensusIsStale(snapshot(footprints: [
                "SOL-3": footprint("SOL-3", fetchedAt: fixtureNow.addingTimeInterval(-ageSeconds)),
            ]))
        }
        #expect(!stale(ageSeconds: 59))
        #expect(!stale(ageSeconds: 60))
        #expect(stale(ageSeconds: 61))
    }

    /// No census row anywhere is not "fresh enough" — the table has never been
    /// read, and a print may not be ordered against evidence that does not exist.
    @Test("an empty census table reads as stale")
    func anEmptyCensusIsStale() {
        #expect(PrintRail(reserveFloor: 500).footprintCensusIsStale(snapshot()))
    }

    /// The gate is TABLE-WIDE: a fresh row for ANOTHER location clears it, since
    /// one `refreshFootprint` upserts every location the API returns.
    @Test("a fresh row elsewhere clears the table-wide gate")
    func theGateIsTableWide() {
        let world = snapshot(footprints: [
            "VEGA-1": footprint("VEGA-1", fetchedAt: fixtureNow),
            "SOL-3": footprint("SOL-3", fetchedAt: fixtureNow.addingTimeInterval(-3_600)),
        ])
        #expect(!PrintRail(reserveFloor: 500).footprintCensusIsStale(world))
    }
}
