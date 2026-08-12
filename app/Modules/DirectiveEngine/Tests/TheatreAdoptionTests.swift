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
        let view = singleTheatreView()
        let row = directiveFixture(id: "D1", kind: .haulRun, originDesignation: "AINALRAM", theatreDepot: nil)

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
