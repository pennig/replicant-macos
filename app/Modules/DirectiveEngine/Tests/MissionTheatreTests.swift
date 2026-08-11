//
//  MissionTheatreTests.swift
//  Replicould — DirectiveEngine
//
//  Each mission resolves the theatre named on its OWN row. Two rows in two
//  theatres must not resolve to the same depot.
//

import Foundation
import GameModels
import Testing
import UniverseModels
@testable import DirectiveEngine

/// Mirrors `twoTheatreView()`'s two theatres and components, as the
/// directive-scoped read — two theatre lists built off the same shape.
private func twoTheatreSnapshot() -> WorldSnapshot {
    WorldSnapshot(
        devices: [:],
        openOperations: [:],
        components: [
            "AINALRAM": "AINALRAM", "GRAZ": "AINALRAM",
            "OMEROPE": "DENEBED", "DENEBED": "DENEBED",
        ],
        theatres: [
            Theatre(depot: "AINALRAM-BELT-1", system: "AINALRAM", origin: .derived,
                    readiness: .operational, stock: 40_000),
            Theatre(depot: "DENEBED-BELT-1", system: "DENEBED", origin: .pinned,
                    readiness: .operational, stock: 900),
        ],
        now: Date(timeIntervalSince1970: 5_000)
    )
}

@Suite("Mission theatre resolution")
struct MissionTheatreTests {
    @Test("Two relay runs in two theatres return to their own depots")
    func relayReturnsToOwnDepot() {
        let snapshot = twoTheatreSnapshot()
        let home = directiveFixture(id: "D1", kind: .relayRun, theatreDepot: "AINALRAM-BELT-1")
        let pocket = directiveFixture(id: "D2", kind: .relayRun, theatreDepot: "DENEBED-BELT-1")

        #expect(RelayRun.theatreDepot(in: snapshot, for: home) == "AINALRAM-BELT-1")
        #expect(RelayRun.theatreDepot(in: snapshot, for: pocket) == "DENEBED-BELT-1")
    }

    @Test("A salvage run's hub system comes from its own row")
    func salvageSystemFromOwnRow() {
        let snapshot = twoTheatreSnapshot()
        let pocket = directiveFixture(id: "D2", kind: .salvageRun, theatreDepot: "DENEBED-BELT-1")

        #expect(SalvageRun.hubSystem(in: snapshot, for: pocket) == "DENEBED")
    }

    @Test("An unstamped row resolves to nothing rather than to the first theatre")
    func unstampedResolvesNil() {
        let snapshot = twoTheatreSnapshot()
        let orphan = directiveFixture(id: "D3", kind: .relayRun, theatreDepot: nil)

        #expect(RelayRun.theatreDepot(in: snapshot, for: orphan) == nil)
    }

    @Test("A row naming a depot that no longer exists resolves to nothing")
    func staleDepotResolvesNil() {
        let snapshot = twoTheatreSnapshot()
        let stale = directiveFixture(id: "D4", kind: .relayRun, theatreDepot: "GONE-BELT-1")

        #expect(RelayRun.theatreDepot(in: snapshot, for: stale) == nil)
    }

    /// `MineSitePlanner` has no directive row to read a depot from, so it must
    /// rank OUTWARD from the nearest theatre — never `theatre(servicing:)`,
    /// which is component-scoped and would refuse a belt on the frontier
    /// before any relay chain has linked its system into an existing theatre's
    /// own mesh component.
    @Test("Mine site ranking uses the NEAREST theatre, even off its own mesh component")
    func mineRankingIsOutward() {
        let view = WorldView(
            devices: [:],
            starPositions: ["HOME": .init(x: 0, y: 0, z: 0), "FRONTIER": .init(x: 5, y: 0, z: 0)],
            meshSystems: ["HOME", "FRONTIER"],
            salvageUnits: [:], eventSystems: [], hubLocation: nil,
            theatres: [Theatre(
                depot: "HOME-BELT-1", system: "HOME", origin: .derived,
                readiness: .operational, stock: 1_000
            )],
            components: ["HOME": "HOME", "FRONTIER": "FRONTIER"],
            beltsBySystem: ["FRONTIER": [
                BeltInfo(designation: "FRONTIER-BELT-1", beltClass: .moderate, richness: [:]),
            ]],
            now: Date(timeIntervalSince1970: 5_000)
        )

        // The inward resolver would refuse this candidate outright.
        #expect(view.theatre(servicing: "FRONTIER") == nil)

        let site = MineSitePlanner.site(view: view, occupiedBelts: [])
        #expect(site?.belt == "FRONTIER-BELT-1")
    }
}
