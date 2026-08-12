//
//  TheatresTabTests.swift
//  Replicould — Logistics feature
//
//  The Theatres tab: shortfall wording, the establish sheet's write, and the
//  reducer's on-demand refresh (tab switch, Refresh, and post-establish).
//

import ComposableArchitecture
import DirectiveEngine
import Foundation
import GameDatabase
import GameModels
import SQLiteData
import Testing
import UniverseModels
@testable import LogisticsFeature

private let fixtureNow = Date(timeIntervalSince1970: 5_000)

@Suite("Theatre row model")
struct TheatreRowModelTests {
    @Test("A claimed theatre lists every shortfall it has")
    func claimedListsShortfalls() {
        let model = TheatreRowModel(theatre: Theatre(
            depot: "OMEROPE-BELT-1", system: "OMEROPE", origin: .pinned,
            readiness: .claimed(missing: [.noPrintCapableDevice, .noStock]), stock: 0
        ))
        #expect(model.shortfallLines == ["no autofactory here", "no stock"])
    }

    @Test("An operational theatre has no shortfalls")
    func operationalHasNoShortfalls() {
        let model = TheatreRowModel(theatre: Theatre(
            depot: "AINALRAM-1", system: "AINALRAM", origin: .derived,
            readiness: .operational, stock: 40_000
        ))
        #expect(model.shortfallLines.isEmpty)
    }

    @Test("Component size and directive count derive from WorldView and the directive table")
    func derivesFromWorldViewAndDirectives() {
        let theatre = Theatre(
            depot: "AINALRAM-1", system: "AINALRAM", origin: .derived,
            readiness: .operational, stock: 40_000
        )
        let view = WorldView(
            devices: [:], starPositions: [:], meshSystems: [], salvageUnits: [:], eventSystems: [],
            theatres: [theatre], components: ["AINALRAM": "c1", "GRAZ": "c1", "OMEROPE": "c2"],
            now: fixtureNow
        )
        let directives = [
            Self.directive(id: "D1", theatreDepot: "AINALRAM-1"),
            Self.directive(id: "D2", theatreDepot: "AINALRAM-1"),
            Self.directive(id: "D3", theatreDepot: "OMEROPE-1"),
            Self.directive(id: "D4", theatreDepot: nil),
        ]
        let model = TheatreRowModel(theatre: theatre, view: view, directives: directives)
        #expect(model.componentSize == 2)
        #expect(model.directiveCount == 2)
    }

    nonisolated static func directive(id: String, theatreDepot: String?) -> Directive {
        Directive(
            id: id, kind: .haulRun, status: .running, deviceCode: "C1",
            targets: [], targetIndex: 0, step: "preflight", stepStartedAt: fixtureNow,
            returnToOrigin: false, originDesignation: nil, attentionReason: nil,
            createdAt: fixtureNow, updatedAt: fixtureNow, theatreDepot: theatreDepot
        )
    }
}

@Suite("Establish theatre sheet")
@MainActor
struct EstablishTheatreSheetTests {
    @Test("Confirming writes a pin and nothing else, then delegates and dismisses")
    func confirmingWritesAPin() async throws {
        let database = try GameDatabase.bootstrap()
        var initial = EstablishTheatreSheet.State(suggestedSystem: "OMEROPE")
        initial.location = "OMEROPE-BELT-1"
        let store = TestStore(initialState: initial) {
            EstablishTheatreSheet()
        } withDependencies: {
            $0.defaultDatabase = database
            $0.date = .constant(fixtureNow)
        }
        store.exhaustivity = .off

        await store.send(.confirmTapped) { $0.isSaving = true }
        await store.receive(\.pinWritten) { $0.isSaving = false }
        await store.finish()

        let pins = try await database.read { try TheatrePin.all.fetchAll($0) }
        #expect(pins.map(\.location) == ["OMEROPE-BELT-1"])
        #expect(pins.first?.createdAt == fixtureNow)
    }

    @Test("A blank location cannot be established")
    func blankLocationRefused() {
        var state = EstablishTheatreSheet.State()
        state.location = "   "
        #expect(!state.canEstablish)
    }

    @Test("A candidate's bare system is never pre-filled and cannot itself be confirmed")
    func bareSystemNeverEstablishable() {
        var state = EstablishTheatreSheet.State(suggestedSystem: "OMEROPE")
        #expect(state.location.isEmpty)
        state.location = "OMEROPE"
        #expect(!state.canEstablish)
        state.location = "omerope"
        #expect(!state.canEstablish)
        state.location = "OMEROPE-BELT-1"
        #expect(state.canEstablish)
    }
}

@Suite("Logistics theatres tab")
@MainActor
struct TheatresTabFeatureTests {
    @Test("Switching to the Theatres tab loads from the current WorldView")
    func switchingTabsLoads() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try TheatrePin.insert { TheatrePin(location: "OMEROPE-BELT-1", createdAt: fixtureNow) }.execute(db)
        }
        let store = TestStore(initialState: LogisticsFeature.State()) {
            LogisticsFeature()
        } withDependencies: {
            $0.defaultDatabase = database
            $0.date = .constant(fixtureNow)
        }

        await store.send(\.binding.tab, .theatres) { $0.tab = .theatres }
        await store.receive(\.theatresLoaded) {
            $0.theatres = [TheatreRowModel(
                theatre: Theatre(
                    depot: "OMEROPE-BELT-1", system: "OMEROPE", origin: .pinned,
                    readiness: .claimed(missing: [.noPrintCapableDevice, .noStock, .offMesh]), stock: 0
                )
            )]
        }
    }

    @Test("Switching away from Theatres does not reload")
    func switchingAwayDoesNotReload() async throws {
        let database = try GameDatabase.bootstrap()
        let store = withDependencies {
            $0.defaultDatabase = database
        } operation: {
            var initial = LogisticsFeature.State()
            initial.tab = .theatres
            return TestStore(initialState: initial) {
                LogisticsFeature()
            } withDependencies: {
                $0.defaultDatabase = database
                $0.date = .constant(fixtureNow)
            }
        }

        await store.send(\.binding.tab, .yields) { $0.tab = .yields }
    }

    @Test("Establish opens the sheet with the candidate's system as read-only context, unfilled")
    func establishTappedPresentsSheet() async throws {
        let database = try GameDatabase.bootstrap()
        let store = TestStore(initialState: LogisticsFeature.State()) {
            LogisticsFeature()
        } withDependencies: {
            $0.defaultDatabase = database
        }

        await store.send(.establishTapped(system: "OMEROPE")) {
            $0.establishTheatre = EstablishTheatreSheet.State(suggestedSystem: "OMEROPE")
        }
    }

    @Test("Establishing writes a pin, dismisses the sheet, and refreshes the list")
    func establishingRefreshesTheList() async throws {
        let database = try GameDatabase.bootstrap()
        let store = TestStore(initialState: LogisticsFeature.State()) {
            LogisticsFeature()
        } withDependencies: {
            $0.defaultDatabase = database
            $0.date = .constant(fixtureNow)
        }
        store.exhaustivity = .off

        await store.send(.establishTapped(system: "OMEROPE"))
        await store.send(.establishTheatre(.presented(.binding(.set(\.location, "OMEROPE-BELT-1")))))
        await store.send(.establishTheatre(.presented(.confirmTapped)))
        await store.receive(\.establishTheatre.presented.pinWritten)
        await store.receive(\.establishTheatre.presented.delegate)
        await store.receive(\.theatresLoaded)
        await store.finish()

        let pins = try await database.read { try TheatrePin.all.fetchAll($0) }
        #expect(pins.map(\.location) == ["OMEROPE-BELT-1"])
        #expect(store.state.establishTheatre == nil)
        #expect(store.state.theatres.map(\.theatre.depot) == ["OMEROPE-BELT-1"])
    }
}
