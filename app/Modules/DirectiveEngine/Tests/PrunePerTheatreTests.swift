//
//  PrunePerTheatreTests.swift
//  Replicould — DirectiveEngine
//
//  Each component is judged against its own theatre. A relay must never be
//  offered up because a DIFFERENT component's anchor cannot reach it.
//

import Foundation
import GameModels
import Testing
import UniverseModels
@testable import DirectiveEngine

private let ainalram = Position(x: -11.25, y: -37.09, z: -7.68)
private let omerope = Position(x: -291.87, y: -125.98, z: 106.32)
private let denebed = Position(x: -292.55, y: -125.42, z: 113.41)

@Suite("Prune per theatre")
struct PrunePerTheatreTests {
    @Test("A disconnected component's relays are never reclaimable from the home anchor")
    func otherComponentIsNotReclaimable() {
        let view = twoComponentWorld()
        let graph = MeshGraph(positions: view.starPositions)
        let analysis = PrunePredicate.analyse(view: view, graph: graph)

        let pocketRelays = ["REL-OMEROPE", "REL-DENEBED"]
        #expect(analysis.reclaimable.allSatisfy { !pocketRelays.contains($0.deviceCode) })
    }

    @Test("A component holding no operational theatre pins all its relays")
    func unanchoredComponentDeclines() {
        let view = pocketWithoutTheatre()
        let graph = MeshGraph(positions: view.starPositions)
        let analysis = PrunePredicate.analyse(view: view, graph: graph)

        #expect(analysis.pinned.contains("REL-OMEROPE"))
        #expect(analysis.reclaimable.isEmpty)
    }

    @Test("Within an anchored component a genuinely useless relay is still reclaimable")
    func usefulnessStillJudgedLocally() {
        let view = homeWithSpurRelay()
        let graph = MeshGraph(positions: view.starPositions)
        let analysis = PrunePredicate.analyse(view: view, graph: graph)

        #expect(analysis.reclaimable.map(\.deviceCode) == ["REL-SPUR"])
    }

    @Test("Two theatres in ONE component judge against the union of both roots' paths")
    func sharedComponentUsesBothAnchors() {
        let view = twoTheatresOneComponent()
        let graph = MeshGraph(positions: view.starPositions)
        let analysis = PrunePredicate.analyse(view: view, graph: graph)

        // A relay on the path from either theatre to live value stays pinned.
        #expect(analysis.pinned.contains("REL-BETWEEN"))
    }

    @Test("A component holding no theatre and no value judges normally — a useless relay there is reclaimable")
    func unanchoredComponentWithNoValueIsReclaimable() {
        let view = emptyPocketWorld()
        let graph = MeshGraph(positions: view.starPositions)
        let analysis = PrunePredicate.analyse(view: view, graph: graph)

        #expect(analysis.reclaimable.map(\.deviceCode) == ["REL-OMEROPE"])
    }
}

// MARK: - Fixtures

/// AINALRAM (home, operational, anchors the print hub) and OMEROPE/DENEBED
/// (a second operational theatre, 316 ly away — no hop range joins them).
/// `OMEROPE` holds the pocket's live value, so its own theatre's union must
/// pin both pocket relays without ever touching the home anchor's search.
private func twoComponentWorld() -> WorldView {
    let positions = ["AINALRAM": ainalram, "OMEROPE": omerope, "DENEBED": denebed]
    let devices = [
        relayFixture("REL-AINALRAM", at: "AINALRAM"),
        relayFixture("REL-DENEBED", at: "DENEBED"),
        relayFixture("REL-OMEROPE", at: "OMEROPE"),
    ]
    return WorldView(
        devices: Dictionary(uniqueKeysWithValues: devices.map { ($0.deviceCode, $0) }),
        starPositions: positions,
        meshSystems: ["AINALRAM", "DENEBED", "OMEROPE"],
        salvageUnits: ["OMEROPE": 500],
        eventSystems: [],
        hubLocation: "AINALRAM-BELT-1",
        theatres: [
            Theatre(depot: "AINALRAM-BELT-1", system: "AINALRAM", origin: .derived,
                    readiness: .operational, stock: 40_000),
            Theatre(depot: "DENEBED-BELT-1", system: "DENEBED", origin: .pinned,
                    readiness: .operational, stock: 900),
        ],
        components: ["AINALRAM": "AINALRAM", "DENEBED": "DENEBED", "OMEROPE": "DENEBED"],
        surveyedSystems: ["AINALRAM", "DENEBED", "OMEROPE"],
        now: Date(timeIntervalSince1970: 5_000)
    )
}

/// AINALRAM's component is anchored; OMEROPE's is not — no theatre lives
/// there, but its own salvage IS something to protect, so its relay must pin
/// by construction rather than by judgement.
private func pocketWithoutTheatre() -> WorldView {
    let positions = ["AINALRAM": ainalram, "OMEROPE": omerope]
    let devices = [
        relayFixture("REL-AINALRAM", at: "AINALRAM"),
        relayFixture("REL-OMEROPE", at: "OMEROPE"),
    ]
    return WorldView(
        devices: Dictionary(uniqueKeysWithValues: devices.map { ($0.deviceCode, $0) }),
        starPositions: positions,
        meshSystems: ["AINALRAM", "OMEROPE"],
        salvageUnits: ["OMEROPE": 500],
        eventSystems: [],
        hubLocation: "AINALRAM-BELT-1",
        theatres: [
            Theatre(depot: "AINALRAM-BELT-1", system: "AINALRAM", origin: .derived,
                    readiness: .operational, stock: 40_000),
        ],
        components: ["AINALRAM": "AINALRAM", "OMEROPE": "OMEROPE"],
        surveyedSystems: ["AINALRAM", "OMEROPE"],
        now: Date(timeIntervalSince1970: 5_000)
    )
}

/// Same shape as `pocketWithoutTheatre`, but OMEROPE holds nothing at all —
/// no theatre AND no value, so there is nothing for the unanchored branch to
/// be conservative about and its relay judges normally.
private func emptyPocketWorld() -> WorldView {
    let positions = ["AINALRAM": ainalram, "OMEROPE": omerope]
    let devices = [
        relayFixture("REL-AINALRAM", at: "AINALRAM"),
        relayFixture("REL-OMEROPE", at: "OMEROPE"),
    ]
    return WorldView(
        devices: Dictionary(uniqueKeysWithValues: devices.map { ($0.deviceCode, $0) }),
        starPositions: positions,
        meshSystems: ["AINALRAM", "OMEROPE"],
        salvageUnits: [:],
        eventSystems: [],
        hubLocation: "AINALRAM-BELT-1",
        theatres: [
            Theatre(depot: "AINALRAM-BELT-1", system: "AINALRAM", origin: .derived,
                    readiness: .operational, stock: 40_000),
        ],
        components: ["AINALRAM": "AINALRAM", "OMEROPE": "OMEROPE"],
        surveyedSystems: ["AINALRAM", "OMEROPE"],
        now: Date(timeIntervalSince1970: 5_000)
    )
}

/// One component, one theatre: `VALUE` bridges through `SPUR`'s NEIGHBOUR,
/// while `SPUR` itself sits off every anchor→value road — the ordinary
/// per-relay judgement the old code already did, now scoped to a component.
private func homeWithSpurRelay() -> WorldView {
    let positions: [String: Position] = [
        "HOME": .init(x: 0, y: 0, z: 0),
        "VALUE": .init(x: 0, y: -7, z: 0),
        "SPUR": .init(x: 7, y: 0, z: 0),
    ]
    let devices = [
        relayFixture("REL-HOME", at: "HOME"),
        relayFixture("REL-VALUE", at: "VALUE"),
        relayFixture("REL-SPUR", at: "SPUR"),
    ]
    return WorldView(
        devices: Dictionary(uniqueKeysWithValues: devices.map { ($0.deviceCode, $0) }),
        starPositions: positions,
        meshSystems: ["HOME", "VALUE", "SPUR"],
        salvageUnits: ["VALUE": 500],
        eventSystems: [],
        hubLocation: "HOME-BELT-1",
        theatres: [
            Theatre(depot: "HOME-BELT-1", system: "HOME", origin: .derived,
                    readiness: .operational, stock: 40_000),
        ],
        components: ["HOME": "HOME", "VALUE": "HOME", "SPUR": "HOME"],
        surveyedSystems: ["HOME", "VALUE", "SPUR"],
        now: Date(timeIntervalSince1970: 5_000)
    )
}

/// One component, TWO theatres. `THEATRE-A` needs `BETWEEN` to bridge the 14
/// ly to `VALUE`; `THEATRE-B` sits 7 ly from `VALUE` directly. A single
/// combined-source search would route through `THEATRE-B` alone and drop
/// `BETWEEN`; separate per-anchor searches, unioned, cannot.
private func twoTheatresOneComponent() -> WorldView {
    let positions: [String: Position] = [
        "THEATRE-A": .init(x: 0, y: 0, z: 0),
        "BETWEEN": .init(x: 0, y: 7, z: 0),
        "VALUE": .init(x: 0, y: 14, z: 0),
        "THEATRE-B": .init(x: 7, y: 14, z: 0),
    ]
    let devices = [
        relayFixture("REL-THEATRE-A", at: "THEATRE-A"),
        relayFixture("REL-BETWEEN", at: "BETWEEN"),
        relayFixture("REL-THEATRE-B", at: "THEATRE-B"),
    ]
    let component = "THEATRE-A"
    return WorldView(
        devices: Dictionary(uniqueKeysWithValues: devices.map { ($0.deviceCode, $0) }),
        starPositions: positions,
        meshSystems: ["THEATRE-A", "BETWEEN", "VALUE", "THEATRE-B"],
        salvageUnits: ["VALUE": 500],
        eventSystems: [],
        hubLocation: "THEATRE-A-BELT-1",
        theatres: [
            Theatre(depot: "THEATRE-A-BELT-1", system: "THEATRE-A", origin: .derived,
                    readiness: .operational, stock: 40_000),
            Theatre(depot: "THEATRE-B-BELT-1", system: "THEATRE-B", origin: .pinned,
                    readiness: .operational, stock: 900),
        ],
        components: [
            "THEATRE-A": component, "BETWEEN": component,
            "VALUE": component, "THEATRE-B": component,
        ],
        surveyedSystems: ["THEATRE-A", "BETWEEN", "VALUE", "THEATRE-B"],
        now: Date(timeIntervalSince1970: 5_000)
    )
}

private func relayFixture(_ code: String, at system: String) -> Device {
    deviceFixture(code: code, type: "ftl_relay", location: "\(system)-1", status: "relaying", features: ["relay"])
}
