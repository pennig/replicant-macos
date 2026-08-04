//
//  DirectivesClearAndBrainTests.swift
//  Replicould — Directives feature
//
//  Two housekeeping surfaces on the Directives list:
//
//    • clearing finished runs — the only place this app deletes directive rows,
//      so what it must NOT delete is the interesting half;
//    • the brain selection — the header strip is now a doorway into the detail
//      pane rather than the report itself, and it shares one `selectedRowID`
//      with the rows so the two can never both be showing.
//

import ComposableArchitecture
import DirectiveEngine
import Foundation
import GameDatabase
import GameModels
import SQLiteData
import Testing
import Utils
@testable import DirectivesFeature

@Suite("Directives — clearing finished runs")
@MainActor
struct DirectivesClearFinishedTests {
    nonisolated private static func run(_ id: String, _ status: DirectiveStatus) -> Directive {
        Directive(
            id: id, kind: .surveyRun, status: status, deviceCode: "V-\(id)",
            targets: ["TAU"], targetIndex: 0, step: "surveying",
            stepStartedAt: Date(timeIntervalSince1970: 0),
            returnToOrigin: false, originDesignation: "SOL", attentionReason: nil,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0)
        )
    }

    nonisolated private static func entry(_ id: String, directiveID: String) -> DirectiveLogEntry {
        DirectiveLogEntry(
            id: id, directiveID: directiveID, deviceCode: nil, kind: .resolved,
            summary: "something happened", step: "surveying", operationID: nil,
            eventID: nil, occurredAt: Date(timeIntervalSince1970: 0)
        )
    }

    /// `liveValue` resolves `@Dependency(\.defaultDatabase)` at call time, so a
    /// bare call would write to the ambient database rather than this test's.
    nonisolated private static func clearFinished(in database: any DatabaseWriter) async -> Int {
        await withDependencies {
            $0.defaultDatabase = database
        } operation: {
            await DirectiveResolutionClient.liveValue.clearFinished()
        }
    }

    /// One run of every status, so the verb's boundary is proved in both
    /// directions at once: the two terminal ones go, the three that still OWN
    /// devices stay. Deleting an owning row would hand its carrier back to the
    /// brain mid-flight.
    @Test func clearsOnlyTheTerminalRuns() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            for status in DirectiveStatus.allCases {
                try Directive.insert { Self.run(status.rawValue, status) }.execute(db)
            }
        }

        await Self.clearFinished(in: database)

        let left = try await database.read { db in try Directive.all.fetchAll(db) }
        #expect(Set(left.map(\.status)) == [.running, .needsAttention, .paused])
    }

    /// The timelines go with them. A finished run's entries are reachable only
    /// through its id, so leaving them behind would strand rows nothing can
    /// read or ever prune.
    @Test func clearsTheTimelinesToo() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Directive.insert { Self.run("GONE", .completed) }.execute(db)
            try Directive.insert { Self.run("STAYS", .running) }.execute(db)
            try DirectiveLogEntry.insert { Self.entry("E1", directiveID: "GONE") }.execute(db)
            try DirectiveLogEntry.insert { Self.entry("E2", directiveID: "STAYS") }.execute(db)
        }

        await Self.clearFinished(in: database)

        let entries = try await database.read { db in try DirectiveLogEntry.all.fetchAll(db) }
        #expect(entries.map(\.directiveID) == ["STAYS"])
    }

    @Test func reportsHowManyItCleared() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Directive.insert { Self.run("A", .completed) }.execute(db)
            try Directive.insert { Self.run("B", .cancelled) }.execute(db)
            try Directive.insert { Self.run("C", .running) }.execute(db)
        }

        let cleared = await Self.clearFinished(in: database)

        #expect(cleared == 2)
    }

    /// Nothing to clear is a no-op, not an error — the toolbar disables the
    /// button, but a stale click must not misbehave.
    @Test func clearingNothingIsANoOp() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Directive.insert { Self.run("A", .running) }.execute(db)
        }

        let cleared = await Self.clearFinished(in: database)

        #expect(cleared == 0)
        let left = try await database.read { db in try Directive.all.fetchAll(db) }
        #expect(left.count == 1)
    }

    /// The count the toolbar shows is the count the verb would delete — read
    /// through the same `finishedStatuses` set, so the label cannot drift from
    /// the behaviour.
    @Test func theOfferedCountMatchesWhatWouldGo() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Directive.insert { Self.run("A", .completed) }.execute(db)
            try Directive.insert { Self.run("B", .cancelled) }.execute(db)
            try Directive.insert { Self.run("C", .running) }.execute(db)
        }
        let store = TestStore(initialState: DirectivesFeature.State()) {
            DirectivesFeature()
        } withDependencies: {
            $0.defaultDatabase = database
        }
        store.exhaustivity = .off

        #expect(store.state.finishedCount == 2)
    }

    /// A selection pointing at a run that is about to be deleted must not
    /// survive the clear — the detail pane would be left rendering a row that
    /// no longer exists.
    @Test func clearingDropsASelectionThatIsAboutToVanish() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Directive.insert { Self.run("DONE", .completed) }.execute(db)
        }
        let store = TestStore(initialState: DirectivesFeature.State(selectedRowID: "custom:DONE")) {
            DirectivesFeature()
        } withDependencies: {
            $0.defaultDatabase = database
            $0.directiveResolution.clearFinished = { 1 }
        }
        store.exhaustivity = .off

        await store.send(.clearFinishedTapped) { $0.selectedRowID = nil }
    }

    /// …but a selection on a run that SURVIVES the clear is left alone.
    @Test func clearingKeepsASelectionThatSurvives() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Directive.insert { Self.run("LIVE", .running) }.execute(db)
        }
        let store = TestStore(initialState: DirectivesFeature.State(selectedRowID: "custom:LIVE")) {
            DirectivesFeature()
        } withDependencies: {
            $0.defaultDatabase = database
            $0.directiveResolution.clearFinished = { 0 }
        }
        store.exhaustivity = .off

        await store.send(.clearFinishedTapped)
        #expect(store.state.selectedRowID == "custom:LIVE")
    }
}

@Suite("Directives — the brain selection")
@MainActor
struct DirectivesBrainSelectionTests {
    @Test func tappingTheHeaderSelectsTheBrain() async throws {
        let database = try GameDatabase.bootstrap()
        let store = TestStore(initialState: DirectivesFeature.State()) {
            DirectivesFeature()
        } withDependencies: {
            $0.defaultDatabase = database
        }
        store.exhaustivity = .off

        await store.send(.brainTapped) {
            $0.selectedRowID = DirectivesFeature.brainSelectionID
        }
        #expect(store.state.isBrainSelected)
    }

    /// The reserved id resolves to NO row. That is what lets one selection
    /// serve both: the detail pane checks `isBrainSelected` first, and
    /// `selectedRow` stays honest about there being no run selected.
    @Test func theBrainSelectionResolvesToNoRow() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Directive.insert {
                Directive(
                    id: "D1", kind: .surveyRun, status: .running, deviceCode: "V1",
                    targets: ["TAU"], targetIndex: 0, step: "surveying",
                    stepStartedAt: Date(timeIntervalSince1970: 0),
                    returnToOrigin: false, originDesignation: "SOL", attentionReason: nil,
                    createdAt: Date(timeIntervalSince1970: 0),
                    updatedAt: Date(timeIntervalSince1970: 0)
                )
            }
            .execute(db)
        }
        let store = TestStore(
            initialState: DirectivesFeature.State(selectedRowID: DirectivesFeature.brainSelectionID)
        ) {
            DirectivesFeature()
        } withDependencies: {
            $0.defaultDatabase = database
        }
        store.exhaustivity = .off

        #expect(store.state.isBrainSelected)
        #expect(store.state.selectedRow == nil)
        #expect(store.state.selectedDevice == nil)
    }

    /// Selecting a run takes the brain's place — no second flag to fall out of
    /// step, and the detail pane can only ever be showing one of them.
    @Test func selectingARunReplacesTheBrain() async throws {
        let database = try GameDatabase.bootstrap()
        let store = TestStore(
            initialState: DirectivesFeature.State(selectedRowID: DirectivesFeature.brainSelectionID)
        ) {
            DirectivesFeature()
        } withDependencies: {
            $0.defaultDatabase = database
        }
        store.exhaustivity = .off

        await store.send(.binding(.set(\.selectedRowID, "custom:D1")))

        #expect(!store.state.isBrainSelected)
    }
}
