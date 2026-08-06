//
//  DirectiveLogRetentionTests.swift
//  Replicould — GameSync
//
//  Retention over `directiveLogEntries`, which nothing pruned before while
//  `WorldSnapshot.read` re-fetches a directive's whole log every tick.
//

import Foundation
import GameDatabase
import GameModels
import SQLiteData
import Testing
import Utils
@testable import GameSync

private let now = Date(timeIntervalSince1970: 10_000_000)

private func directive(_ id: String, status: DirectiveStatus, deviceCode: String = "DEV1") -> Directive {
    Directive(
        id: id, kind: .surveyRun, status: status, deviceCode: deviceCode,
        targets: [], targetIndex: 0, step: "preflight", stepStartedAt: now,
        returnToOrigin: false, originDesignation: nil, attentionReason: nil,
        createdAt: now, updatedAt: now
    )
}

private func entry(_ id: String, directiveID: String?, occurredAt: Date, deviceCode: String? = nil) -> DirectiveLogEntry {
    DirectiveLogEntry(
        id: id, directiveID: directiveID, deviceCode: deviceCode,
        kind: .stepStarted, summary: "step", step: "preflight",
        operationID: nil, eventID: nil, occurredAt: occurredAt
    )
}

private func seed(_ directives: [Directive], _ entries: [DirectiveLogEntry]) async throws -> any DatabaseWriter {
    let database = try GameDatabase.bootstrap()
    try await database.write { db in
        for d in directives { try Directive.insert { d }.execute(db) }
        for e in entries { try DirectiveLogEntry.insert { e }.execute(db) }
    }
    return database
}

private func remainingIDs(_ database: any DatabaseReader) async throws -> Set<String> {
    try await database.read { db in Set(try DirectiveLogEntry.all.fetchAll(db).map(\.id)) }
}

@Suite("Directive log retention")
struct DirectiveLogRetentionTests {
    @Test func dropsTheLogOfAFinishedRunPastTheWindow() async throws {
        let stale = now.addingTimeInterval(-DirectiveLogRetention.window - 60)
        let done = directive("D1", status: .completed)
        let database = try await seed([done], [entry("old", directiveID: "D1", occurredAt: stale)])

        let deleted = await DirectiveLogRetention.sweep(database, now: now)

        #expect(deleted == 1)
        #expect(try await remainingIDs(database).isEmpty)
    }

    @Test func keepsAFinishedRunsRecentLog() async throws {
        let recent = now.addingTimeInterval(-60)
        let done = directive("D1", status: .completed)
        let database = try await seed([done], [entry("new", directiveID: "D1", occurredAt: recent)])

        #expect(await DirectiveLogRetention.sweep(database, now: now) == 0)
        #expect(try await remainingIDs(database) == ["new"])
    }

    @Test func neverPrunesAnOpenRunsLog() async throws {
        let ancient = now.addingTimeInterval(-DirectiveLogRetention.window * 4)
        let live = directive("D1", status: .running)
        let database = try await seed([live], [entry("ancient", directiveID: "D1", occurredAt: ancient)])

        #expect(await DirectiveLogRetention.sweep(database, now: now) == 0)
        #expect(try await remainingIDs(database) == ["ancient"])
    }

    @Test func agesOutBuiltInAMIEntriesThatOwnNoDirective() async throws {
        let stale = now.addingTimeInterval(-DirectiveLogRetention.window - 60)
        let database = try await seed([], [entry("ami", directiveID: nil, occurredAt: stale, deviceCode: "CTRL1")])

        #expect(await DirectiveLogRetention.sweep(database, now: now) == 1)
        #expect(try await remainingIDs(database).isEmpty)
    }
}
