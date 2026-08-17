//
//  TheatreAdoptionTests.swift
//  Replicould — DirectiveEngine
//
//  Rows written before `theatreDepot` existed adopt the theatre that services
//  where they are working, and a row already stamped is left alone.
//

import Foundation
import GameModels
import Testing
import UniverseModels
@testable import DirectiveEngine

@Suite("Theatre adoption")
struct TheatreAdoptionTests {
    @Test("An unstamped row adopts the theatre servicing its origin")
    func adoptsFromOrigin() {
        let view = splitOriginView()
        let row = directiveFixture(id: "D1", kind: .haulRun, originDesignation: "GRAZ", theatreDepot: nil)

        let stamps = Brain.adoptTheatres(directives: [row], view: view)

        #expect(stamps.count == 1)
        #expect(stamps[0].id == "D1")
        #expect(stamps[0].depot == "AINALRAM-BELT-1")
    }

    @Test("An already-stamped row is left alone")
    func stampedRowUntouched() {
        let view = singleTheatreView()
        let row = directiveFixture(id: "D1", kind: .haulRun, originDesignation: "AINALRAM",
                                   theatreDepot: "GRAZ-1-L4")

        #expect(Brain.adoptTheatres(directives: [row], view: view).isEmpty)
    }

    @Test("With exactly one theatre, a row with no origin still adopts it")
    func singleTheatreAdoptsWithoutOrigin() {
        let view = singleTheatreView()
        let row = directiveFixture(id: "D1", kind: .haulRun, originDesignation: nil, theatreDepot: nil)

        #expect(Brain.adoptTheatres(directives: [row], view: view).map(\.depot) == ["AINALRAM-BELT-1"])
    }

    /// The launcher rule: servicing, then nearest. A row launched outside
    /// every theatre's mesh component is still stamped, rather than waiting
    /// for the one-theatre fallback that a second theatre retires.
    @Test("A row whose origin no theatre services adopts the nearest one")
    func adoptsNearestWhenNoComponentServices() {
        let row = directiveFixture(id: "D1", kind: .haulRun, originDesignation: "REMOTE", theatreDepot: nil)

        let stamps = Brain.adoptTheatres(directives: [row], view: strandedOriginView())

        #expect(stamps.map(\.depot) == ["AINALRAM-BELT-1"])
    }

    @Test("With several theatres and no origin, the row is left for the operator")
    func ambiguousRowNotGuessed() {
        let view = twoTheatreView()
        let row = directiveFixture(id: "D1", kind: .haulRun, originDesignation: nil, theatreDepot: nil)

        #expect(Brain.adoptTheatres(directives: [row], view: view).isEmpty)
    }
}

private let ainalram = Position(x: -11.25, y: -37.09, z: -7.68)

/// One operational theatre at `AINALRAM-BELT-1`, `AINALRAM` on its own mesh
/// component.
private func singleTheatreView() -> WorldView {
    WorldView(
        devices: [:],
        starPositions: ["AINALRAM": ainalram],
        meshSystems: ["AINALRAM"],
        salvageUnits: [:],
        eventSystems: [],
        theatres: [
            Theatre(depot: "AINALRAM-BELT-1", system: "AINALRAM", origin: .derived,
                    readiness: .operational, stock: 40_000),
        ],
        components: ["AINALRAM": "AINALRAM"],
        now: Date(timeIntervalSince1970: 5_000)
    )
}

/// Two theatres, and a `GRAZ` origin sharing AINALRAM's mesh component while
/// standing nearer DENEBED — so servicing, nearest and the one-theatre
/// fallback each name a different depot.
private func splitOriginView() -> WorldView {
    WorldView(
        devices: [:],
        starPositions: [
            "AINALRAM": ainalram,
            "GRAZ": Position(x: ainalram.x + 90, y: ainalram.y, z: ainalram.z),
            "DENEBED": Position(x: ainalram.x + 100, y: ainalram.y, z: ainalram.z),
        ],
        meshSystems: ["AINALRAM", "GRAZ", "DENEBED"],
        salvageUnits: [:],
        eventSystems: [],
        theatres: [
            Theatre(depot: "AINALRAM-BELT-1", system: "AINALRAM", origin: .derived,
                    readiness: .operational, stock: 40_000),
            Theatre(depot: "DENEBED-BELT-1", system: "DENEBED", origin: .pinned,
                    readiness: .operational, stock: 900),
        ],
        components: ["AINALRAM": "AINALRAM", "GRAZ": "AINALRAM", "DENEBED": "DENEBED"],
        now: Date(timeIntervalSince1970: 5_000)
    )
}

/// Two theatres, and a `REMOTE` origin in a mesh component neither services —
/// `AINALRAM` is the nearer of the two.
private func strandedOriginView() -> WorldView {
    WorldView(
        devices: [:],
        starPositions: [
            "AINALRAM": ainalram,
            "REMOTE": Position(x: ainalram.x + 5, y: ainalram.y, z: ainalram.z),
            "DENEBED": Position(x: ainalram.x + 400, y: ainalram.y, z: ainalram.z),
        ],
        meshSystems: ["AINALRAM", "DENEBED"],
        salvageUnits: [:],
        eventSystems: [],
        theatres: [
            Theatre(depot: "AINALRAM-BELT-1", system: "AINALRAM", origin: .derived,
                    readiness: .operational, stock: 40_000),
            Theatre(depot: "DENEBED-BELT-1", system: "DENEBED", origin: .pinned,
                    readiness: .operational, stock: 900),
        ],
        components: ["AINALRAM": "AINALRAM", "DENEBED": "DENEBED", "REMOTE": "REMOTE"],
        now: Date(timeIntervalSince1970: 5_000)
    )
}

/// A directive row with only the fields theatre adoption reads set; everything
/// else takes a fixed inert default.
private func directiveFixture(
    id: String,
    kind: DirectiveKind,
    originDesignation: String?,
    theatreDepot: String?
) -> Directive {
    Directive(
        id: id, kind: kind, status: .running, deviceCode: "V1",
        controllerCode: nil, roamCentre: nil, fleetTag: nil, sourceRelayCode: nil,
        targets: [], targetIndex: 0, step: "step", stepStartedAt: Date(timeIntervalSince1970: 0),
        returnToOrigin: false, originDesignation: originDesignation, attentionReason: nil,
        createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0),
        theatreDepot: theatreDepot
    )
}
