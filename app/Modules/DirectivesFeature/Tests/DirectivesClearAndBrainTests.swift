//
//  DirectivesClearAndBrainTests.swift
//  Replicould — Directives feature
//
//  Two housekeeping surfaces on the Directives list:
//
//    • clearing finished runs — a mark, not a deletion, so what it must NOT
//      hide is the interesting half;
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
    nonisolated private static func run(
        _ id: String,
        _ status: DirectiveStatus,
        updatedAt: Date = Date(timeIntervalSince1970: 0),
        deletedAt: Date? = nil
    ) -> Directive {
        Directive(
            id: id, kind: .surveyRun, status: status, deviceCode: "V-\(id)",
            targets: ["TAU"], targetIndex: 0, step: "surveying",
            stepStartedAt: Date(timeIntervalSince1970: 0),
            returnToOrigin: false, originDesignation: "SOL", attentionReason: nil,
            deletedAt: deletedAt,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: updatedAt
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
    nonisolated private static func clearFinished(
        in database: any DatabaseWriter,
        now: Date = Date(timeIntervalSince1970: 5_000)
    ) async -> Int {
        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(now)
        } operation: {
            await DirectiveResolutionClient.liveValue.clearFinished()
        }
    }

    /// One run of every status, so the verb's boundary is proved in both
    /// directions at once: the two terminal ones are marked, the three that
    /// still OWN devices are not. Marking an owning row would hide a carrier
    /// the operator still needs to see.
    @Test func marksOnlyTheTerminalRuns() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            for status in DirectiveStatus.allCases {
                try Directive.insert { Self.run(status.rawValue, status) }.execute(db)
            }
        }

        await Self.clearFinished(in: database)

        let rows = try await database.read { db in try Directive.all.fetchAll(db) }
        #expect(rows.count == DirectiveStatus.allCases.count, "nothing is destroyed")
        let marked = Set(rows.filter { $0.deletedAt != nil }.map(\.status))
        #expect(marked == [.completed, .cancelled])
    }

    /// The timelines stay. They are the whole reason the row is kept — a marked
    /// run's steps are the diagnostics the operator comes back for.
    @Test func keepsTheTimelines() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Directive.insert { Self.run("HIDDEN", .completed) }.execute(db)
            try Directive.insert { Self.run("STAYS", .running) }.execute(db)
            try DirectiveLogEntry.insert { Self.entry("E1", directiveID: "HIDDEN") }.execute(db)
            try DirectiveLogEntry.insert { Self.entry("E2", directiveID: "STAYS") }.execute(db)
        }

        await Self.clearFinished(in: database)

        let entries = try await database.read { db in try DirectiveLogEntry.all.fetchAll(db) }
        #expect(Set(entries.compactMap(\.directiveID)) == ["HIDDEN", "STAYS"])
    }

    /// `updatedAt` is the purge clock. Stamping it on the mark would restart
    /// that clock, turning "finished over a month ago" into "deleted over a
    /// month ago" — a different retention policy than the one chosen.
    @Test func markingLeavesUpdatedAtAlone() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Directive.insert { Self.run("A", .completed) }.execute(db)
        }

        await Self.clearFinished(in: database)

        let row = try await database.read { db in
            try Directive.where { $0.id.eq("A") }.fetchOne(db)
        }
        #expect(row?.updatedAt == Date(timeIntervalSince1970: 0))
        #expect(row?.deletedAt != nil)
    }

    /// A second click must not move an already-marked row's `deletedAt`, and
    /// must not count it again — the toolbar's number is what leaves the list.
    @Test func aSecondClearNeitherRestampsNorRecounts() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Directive.insert { Self.run("A", .completed) }.execute(db)
        }

        let first = await Self.clearFinished(in: database)
        let stamped = try await database.read { db in
            try Directive.where { $0.id.eq("A") }.fetchOne(db)?.deletedAt
        }
        let second = await Self.clearFinished(in: database, now: Date(timeIntervalSince1970: 9_000))
        let restamped = try await database.read { db in
            try Directive.where { $0.id.eq("A") }.fetchOne(db)?.deletedAt
        }

        #expect(first == 1)
        #expect(second == 0)
        #expect(stamped == restamped)
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

    /// The purge is what makes the mark affordable. A terminal run finished
    /// more than `purgeWindow` ago goes for good, and its timeline with it.
    @Test func purgesTerminalRunsPastTheWindow() async throws {
        let now = Date(timeIntervalSince1970: 10_000_000)
        let stale = now.addingTimeInterval(-DirectiveResolutionClient.purgeWindow - 60)
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Directive.insert { Self.run("OLD", .completed, updatedAt: stale) }.execute(db)
            try DirectiveLogEntry.insert { Self.entry("E1", directiveID: "OLD") }.execute(db)
        }

        await Self.clearFinished(in: database, now: now)

        let rows = try await database.read { db in try Directive.all.fetchAll(db) }
        let entries = try await database.read { db in try DirectiveLogEntry.all.fetchAll(db) }
        #expect(rows.isEmpty)
        #expect(entries.isEmpty)
    }

    /// An open run is never purged however old. It still owns its devices, and
    /// a mission whose row vanished mid-flight would strand every one of them.
    @Test func neverPurgesAnOpenRunHoweverOld() async throws {
        let now = Date(timeIntervalSince1970: 10_000_000)
        let ancient = now.addingTimeInterval(-DirectiveResolutionClient.purgeWindow * 12)
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            for status in DirectiveStatus.openCases {
                try Directive.insert {
                    Self.run(status.rawValue, status, updatedAt: ancient)
                }
                .execute(db)
            }
        }

        await Self.clearFinished(in: database, now: now)

        let rows = try await database.read { db in try Directive.all.fetchAll(db) }
        #expect(rows.count == DirectiveStatus.openCases.count)
    }

    /// Inside the window a terminal run is marked, not purged — that is the
    /// month of diagnostics the whole change exists to keep.
    @Test func keepsTerminalRunsInsideTheWindow() async throws {
        let now = Date(timeIntervalSince1970: 10_000_000)
        let recent = now.addingTimeInterval(-DirectiveResolutionClient.purgeWindow + 60)
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Directive.insert { Self.run("YOUNG", .completed, updatedAt: recent) }.execute(db)
            try DirectiveLogEntry.insert { Self.entry("E1", directiveID: "YOUNG") }.execute(db)
        }

        await Self.clearFinished(in: database, now: now)

        let row = try await database.read { db in
            try Directive.where { $0.id.eq("YOUNG") }.fetchOne(db)
        }
        let entries = try await database.read { db in try DirectiveLogEntry.all.fetchAll(db) }
        #expect(row?.deletedAt != nil)
        #expect(entries.count == 1)
    }

    /// The purge runs even when there is nothing new to mark, so a click on a
    /// quiet list still does the housekeeping.
    @Test func purgesEvenWithNothingToMark() async throws {
        let now = Date(timeIntervalSince1970: 10_000_000)
        let stale = now.addingTimeInterval(-DirectiveResolutionClient.purgeWindow - 60)
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Directive.insert {
                Self.run("OLD", .completed, updatedAt: stale, deletedAt: stale)
            }
            .execute(db)
        }

        let marked = await Self.clearFinished(in: database, now: now)

        let rows = try await database.read { db in try Directive.all.fetchAll(db) }
        #expect(marked == 0)
        #expect(rows.isEmpty)
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
