//
//  TheatreSiteRankingTests.swift
//  Replicould — DirectiveEngine
//
//  Candidate ranking for a new theatre: value an existing theatre already
//  reaches counts for nothing, and the order is total.
//

import Foundation
import GameModels
import Testing
import UniverseModels
@testable import DirectiveEngine

@Suite("Theatre site ranking")
struct TheatreSiteRankingTests {
    @Test("Value an existing theatre already services does not count")
    func servicedValueIsWorthless() {
        let ranked = TheatreSiteRanking.rank(view: valueBesideHomeTheatre())
        #expect(ranked.first?.system != "GRAZ")
    }

    @Test("A rich unserviced cluster outranks a poor one")
    func richerUnservicedWins() {
        let ranked = TheatreSiteRanking.rank(view: twoUnservicedClusters())
        #expect(ranked.first?.system == "OMEROPE")
    }

    @Test("A system holding a replicant outranks an equal one without")
    func authorityBreaksTies() {
        let ranked = TheatreSiteRanking.rank(view: equalClustersOneWithReplicant())
        #expect(ranked.first?.hasAuthority == true)
    }

    @Test("A candidate beside an existing theatre is discounted as redundant")
    func redundancyDiscounted() {
        let ranked = TheatreSiteRanking.rank(view: candidateBesideExistingTheatre())
        let neighbour = ranked.first { $0.system == "GRAZ" }
        #expect(neighbour?.reasons.contains { $0.contains("redundant") } == true)
    }

    @Test("The order is total and repeatable")
    func orderIsTotal() {
        let view = twoUnservicedClusters()
        #expect(TheatreSiteRanking.rank(view: view) == TheatreSiteRanking.rank(view: view))
    }

    @Test("An unsurveyed candidate is offered, flagged, and discounted rather than dropped")
    func unsurveyedStillOffered() {
        let ranked = TheatreSiteRanking.rank(view: unsurveyedRichCluster())
        #expect(ranked.contains { $0.system == "OMEROPE" && !$0.isSurveyed })
    }
}

// MARK: - Fixtures

private let ainalram = Position(x: 0, y: 0, z: 0)

/// GRAZ sits 5 ly from home — inside its reach, so an operational theatre
/// already services its value. OMEROPE is 200 ly out holding less raw value,
/// but none of it is already spoken for.
private func valueBesideHomeTheatre() -> WorldView {
    WorldView(
        devices: [:],
        starPositions: [
            "AINALRAM": ainalram,
            "GRAZ": Position(x: 5, y: 0, z: 0),
            "OMEROPE": Position(x: 200, y: 0, z: 0),
        ],
        meshSystems: ["AINALRAM"],
        salvageUnits: ["GRAZ": 5_000, "OMEROPE": 500],
        eventSystems: [],
        theatres: [
            Theatre(depot: "AINALRAM-1", system: "AINALRAM", origin: .derived,
                    readiness: .operational, stock: 40_000),
        ],
        now: Date(timeIntervalSince1970: 0)
    )
}

/// Two systems 100 ly apart — far enough that neither's catchment reaches the
/// other's value — with no theatre at all, so both are wholly unserviced.
private func twoUnservicedClusters() -> WorldView {
    WorldView(
        devices: [:],
        starPositions: [
            "OMEROPE": Position(x: 0, y: 0, z: 0),
            "DENEBED": Position(x: 100, y: 0, z: 0),
        ],
        meshSystems: [],
        salvageUnits: ["OMEROPE": 5_000, "DENEBED": 300],
        eventSystems: [],
        theatres: [],
        now: Date(timeIntervalSince1970: 0)
    )
}

/// Same unserviced value at both systems; only VESTA holds a replicant.
private func equalClustersOneWithReplicant() -> WorldView {
    WorldView(
        devices: [:],
        starPositions: [
            "VESTA": Position(x: 0, y: 0, z: 0),
            "KRONOS": Position(x: 100, y: 0, z: 0),
        ],
        meshSystems: [],
        salvageUnits: ["VESTA": 1_000, "KRONOS": 1_000],
        eventSystems: [],
        theatres: [],
        replicantSystems: ["VESTA"],
        now: Date(timeIntervalSince1970: 0)
    )
}

/// GRAZ sits 10 ly from the home theatre — inside its reach, the ticket's own
/// "duplicates it" example.
private func candidateBesideExistingTheatre() -> WorldView {
    WorldView(
        devices: [:],
        starPositions: [
            "AINALRAM": ainalram,
            "GRAZ": Position(x: 10, y: 0, z: 0),
        ],
        meshSystems: ["AINALRAM"],
        salvageUnits: [:],
        eventSystems: [],
        theatres: [
            Theatre(depot: "AINALRAM-1", system: "AINALRAM", origin: .derived,
                    readiness: .operational, stock: 40_000),
        ],
        now: Date(timeIntervalSince1970: 0)
    )
}

/// OMEROPE holds real salvage value but has never been surveyed, so its
/// belts are unknown rather than absent.
private func unsurveyedRichCluster() -> WorldView {
    WorldView(
        devices: [:],
        starPositions: ["OMEROPE": Position(x: 0, y: 0, z: 0)],
        meshSystems: [],
        salvageUnits: ["OMEROPE": 5_000],
        eventSystems: [],
        theatres: [],
        now: Date(timeIntervalSince1970: 0)
    )
}
