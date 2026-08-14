//
//  EventLogRetentionTests.swift
//  Replicould — GameSync
//
//  Retention over the `eventLogs` ledger, which nothing pruned. It reached
//  91,408 rows — 78 MB of payload, about half the whole database.
//

import Foundation
import GameDatabase
import GameModels
import SQLiteData
import Testing
import Utils

@testable import GameSync

private let now = Date(timeIntervalSince1970: 10_000_000)

private func entry(_ id: String, receivedAt: Date) -> EventLog {
    EventLog(
        id: id,
        event: "ami.mining.digest",
        category: "ami",
        receivedAt: receivedAt,
        provenance: "stream",
        isHandled: true
    )
}

private func seed(_ entries: [EventLog]) async throws -> any DatabaseWriter {
    let database = try GameDatabase.bootstrap()
    try await database.write { db in
        for entry in entries { try EventLog.insert { entry }.execute(db) }
    }
    return database
}

private func remainingIDs(_ database: any DatabaseReader) async throws -> Set<String> {
    try await database.read { db in Set(try EventLog.all.fetchAll(db).map(\.id)) }
}

@Suite("Event log retention")
struct EventLogRetentionTests {
    @Test func dropsEntriesOlderThanTheWindow() async throws {
        let stale = now.addingTimeInterval(-EventLogRetention.window - 60)
        let database = try await seed([entry("old", receivedAt: stale)])

        let deleted = await EventLogRetention.sweep(database, now: now)

        #expect(deleted == 1)
        #expect(try await remainingIDs(database).isEmpty)
    }

    /// The window is the browsable range — the Event Log exists to be read.
    @Test func keepsEntriesInsideTheWindow() async throws {
        let recent = now.addingTimeInterval(-EventLogRetention.window + 60)
        let database = try await seed([entry("recent", receivedAt: recent)])

        let deleted = await EventLogRetention.sweep(database, now: now)

        #expect(deleted == 0)
        #expect(try await remainingIDs(database) == ["recent"])
    }

    @Test func sweepsOnlyThePartOfTheLedgerThatHasAgedOut() async throws {
        let database = try await seed([
            entry("ancient", receivedAt: now.addingTimeInterval(-EventLogRetention.window * 3)),
            entry("stale", receivedAt: now.addingTimeInterval(-EventLogRetention.window - 1)),
            entry("fresh", receivedAt: now.addingTimeInterval(-60)),
        ])

        let deleted = await EventLogRetention.sweep(database, now: now)

        #expect(deleted == 2)
        #expect(try await remainingIDs(database) == ["fresh"])
    }

    @Test func anEmptyLedgerSweepsToZero() async throws {
        let database = try await seed([])
        #expect(await EventLogRetention.sweep(database, now: now) == 0)
    }
}
