//
//  PrintRailTests.swift
//  Replicould — DirectiveEngine
//
//  The reserve rail's own bounds, its census gate and its per-type veto,
//  driven directly rather than through a mission — the staleness boundary in
//  particular, which no mission suite reaches on its own value.
//

import Foundation
import Testing
import UniverseModels

@testable import DirectiveEngine

private let fixtureNow = Date(timeIntervalSince1970: 100_000)

private func snapshot(inventories: [String: LocationStock] = [:]) -> WorldSnapshot {
    WorldSnapshot(
        devices: [:], openOperations: [:], log: [], dispatchedOperations: [:],
        systems: [:], siteAssays: [:], inventories: inventories, now: fixtureNow
    )
}

/// Ten floors deep in every type — a reading the rail permits.
private func rich(fetchedAt: Date) -> LocationStock {
    LocationStock(quantities: BrainCeiling.reserveFloors.mapValues { $0 * 10 }, fetchedAt: fetchedAt)
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

    /// `stockCensusIsStale` on its own value, at the boundary. The bound is
    /// `>`, so a reading exactly `pollInterval` old is still believed; one
    /// second past it buys a refresh at all six print sites.
    @Test("the census gate turns over one second past the poll interval")
    func theCensusGateTurnsOverAtItsBound() {
        let rail = PrintRail()
        func stale(ageSeconds: TimeInterval) -> Bool {
            rail.stockCensusIsStale(snapshot(inventories: [
                "SOL-3": rich(fetchedAt: fixtureNow.addingTimeInterval(-ageSeconds)),
            ]))
        }
        #expect(!stale(ageSeconds: 59))
        #expect(!stale(ageSeconds: 60))
        #expect(stale(ageSeconds: 61))
    }

    /// No reading anywhere is not "fresh enough" — the table has never been
    /// read, and a print may not be ordered against evidence that does not exist.
    @Test("an empty census table reads as stale")
    func anEmptyCensusIsStale() {
        #expect(PrintRail().stockCensusIsStale(snapshot()))
    }

    /// The gate is TABLE-WIDE: a fresh row for ANOTHER location clears it,
    /// since one depot sweep writes every depot it is given.
    @Test("a fresh row elsewhere clears the table-wide gate")
    func theGateIsTableWide() {
        let world = snapshot(inventories: [
            "VEGA-1": rich(fetchedAt: fixtureNow),
            "SOL-3": rich(fetchedAt: fixtureNow.addingTimeInterval(-3_600)),
        ])
        #expect(!PrintRail().stockCensusIsStale(world))
    }

    // MARK: - The per-type veto

    /// The change this rail exists in its current form for. `TIANEFU-9-L4`'s
    /// live reading holds 7,123 units TOTAL and clears every per-type floor,
    /// so it prints — where a total-only rail calibrated against a richer hub
    /// refused it and starved the second theatre.
    @Test("a small depot that clears every per-type floor prints")
    func aSmallButBalancedDepotPrints() {
        let tianefu = LocationStock(
            quantities: [
                "carbon": 684, "conductive": 1391, "rares": 542,
                "silicates": 1538, "structural": 2603, "volatiles": 365,
            ],
            fetchedAt: fixtureNow
        )
        #expect(tianefu.quantities.values.reduce(0, +) == 7123)
        #expect(!PrintRail().printStockIsShort(at: "TIANEFU-9-L4", snapshot(inventories: [
            "TIANEFU-9-L4": tianefu,
        ])))
    }

    /// And the other half of the same decision: a depot under any type's floor
    /// is refused, and the diagnosis names every type that is short rather
    /// than only the first. `OMEROPE-BELT-1`'s live reading is the fixture.
    @Test("a depot short on some types is refused and every one is named")
    func aDepotShortOnSomeTypesIsRefused() {
        let omerope = LocationStock(
            quantities: [
                "carbon": 197, "conductive": 226, "rares": 33,
                "silicates": 348, "structural": 1094, "volatiles": 96,
            ],
            fetchedAt: fixtureNow
        )
        let world = snapshot(inventories: ["OMEROPE-BELT-1": omerope])
        #expect(PrintRail().printStockIsShort(at: "OMEROPE-BELT-1", world))
        // Carbon, structural and volatiles clear their own floors and are
        // absent — the line reports the shortage, not the whole reading.
        #expect(
            PrintRail().printStockShortDiagnosis(at: "OMEROPE-BELT-1", world)
                == "conductive 226 below floor 600, rares 33 below floor 200, silicates 348 below floor 500"
        )
    }

    /// Fails CLOSED on a location with no reading at all — silence is never
    /// permission to spend.
    @Test("a location with no reading is refused")
    func anUnreadLocationIsRefused() {
        let world = snapshot(inventories: ["ELSEWHERE-1": rich(fetchedAt: fixtureNow)])
        #expect(PrintRail().printStockIsShort(at: "SOL-3", world))
        #expect(
            PrintRail().printStockShortDiagnosis(at: "SOL-3", world)
                == "no per-type stock reading for it at all"
        )
    }

    /// A reading past `hubFreshness` vetoes however abundant it is, and the
    /// diagnosis names the AGE rather than a figure nobody should act on.
    @Test("an abundant but stale reading is refused on its age")
    func aStaleReadingIsRefusedOnItsAge() {
        let world = snapshot(inventories: [
            "SOL-3": LocationStock(
                quantities: BrainCeiling.reserveFloors.mapValues { $0 * 1000 },
                fetchedAt: fixtureNow.addingTimeInterval(-PrintRail.hubFreshness - 1)
            ),
        ])
        #expect(PrintRail().printStockIsShort(at: "SOL-3", world))
        #expect(PrintRail().printStockShortDiagnosis(at: "SOL-3", world).contains("freshness bound"))
    }

    /// An unarmed rail never vetoes, even on stock it cannot read — the seam a
    /// test isolating a different code path relies on.
    @Test("an unarmed rail never vetoes even on unknown stock")
    func anUnarmedRailNeverVetoes() {
        #expect(!PrintRail(reserveFloors: nil).printStockIsShort(at: "SOL-3", snapshot()))
        #expect(
            PrintRail(reserveFloors: nil).printStockShortDiagnosis(at: "SOL-3", snapshot())
                == "the rail is unarmed"
        )
    }

    /// The rail arms with `BrainCeiling`'s own floors by default, so no print
    /// site can quietly hold a second, staler copy of them.
    @Test("the default arming is BrainCeiling's own floors")
    func theDefaultArmingIsTheCeilingsOwn() {
        #expect(PrintRail().reserveFloors == BrainCeiling.reserveFloors)
    }
}
