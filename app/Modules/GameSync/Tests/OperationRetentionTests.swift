//
//  OperationRetentionTests.swift
//  Replicould — GameSync
//
//  Retention over the `operations` table. Nothing pruned it before, so a
//  misbehaving deadline source could — and did — leave hundreds of dead rows
//  that outlived every reason to keep them.
//

import Foundation
import GameDatabase
import GameModels
import SQLiteData
import Testing
import Utils
@testable import GameSync

/// Disambiguate from `Foundation.Operation`.
private typealias Operation = GameModels.Operation

private let now = Date(timeIntervalSince1970: 10_000_000)

private func op(
    _ id: String,
    status: OperationStatus,
    startedAt: Date,
    entityCode: String = "DEV1"
) -> Operation {
    Operation(
        id: id, entityCode: entityCode, kind: OperationKind.travel.rawValue,
        status: status, source: .poll, startedAt: startedAt, completesAt: nil,
        lastConfirmedAt: startedAt, detail: .object([:])
    )
}

private func seed(_ ops: [Operation]) async throws -> any DatabaseWriter {
    let database = try GameDatabase.bootstrap()
    try await database.write { db in
        for op in ops { try Operation.insert { op }.execute(db) }
    }
    return database
}

private func remainingIDs(_ database: any DatabaseReader) async throws -> Set<String> {
    try await database.read { db in Set(try Operation.all.fetchAll(db).map(\.id)) }
}

@Suite("Operation retention")
struct OperationRetentionTests {
    /// A terminal op past the window has served its purpose — it is history
    /// nobody is browsing and nothing reads.
    @Test func dropsTerminalOpsOlderThanTheWindow() async throws {
        let stale = now.addingTimeInterval(-OperationRetention.window - 60)
        let database = try await seed([op("old", status: .completed, startedAt: stale)])

        let deleted = await OperationRetention.sweep(database, now: now)

        #expect(deleted == 1)
        #expect(try await remainingIDs(database).isEmpty)
    }

    /// Inside the window everything stays — the Operations Log is a browsing
    /// surface, not just a live view.
    @Test func keepsTerminalOpsInsideTheWindow() async throws {
        let recent = now.addingTimeInterval(-OperationRetention.window + 60)
        let database = try await seed([op("recent", status: .completed, startedAt: recent)])

        let deleted = await OperationRetention.sweep(database, now: now)

        #expect(deleted == 0)
        #expect(try await remainingIDs(database) == ["recent"])
    }

    /// An OPEN op is never pruned, however old. An ancient `active` row is a
    /// bug worth seeing, and deleting it would also destroy the "one open op
    /// per device" invariant the partial unique index rests on.
    @Test func neverDropsAnOpenOpHoweverOld() async throws {
        let ancient = now.addingTimeInterval(-OperationRetention.window * 10)
        let database = try await seed([
            op("active", status: .active, startedAt: ancient, entityCode: "DEV1"),
            op("enqueued", status: .enqueued, startedAt: ancient, entityCode: "DEV2"),
            op("optimistic", status: .optimistic, startedAt: ancient, entityCode: "DEV3"),
        ])

        let deleted = await OperationRetention.sweep(database, now: now)

        #expect(deleted == 0)
        #expect(try await remainingIDs(database) == ["active", "enqueued", "optimistic"])
    }

    /// Every terminal status ages out, not just `completed` — `unknown` is the
    /// one that actually accumulated (218 rows in a day from a single bad
    /// deadline source).
    @Test func dropsEveryTerminalStatus() async throws {
        let stale = now.addingTimeInterval(-OperationRetention.window - 60)
        let database = try await seed([
            op("c", status: .completed, startedAt: stale),
            op("f", status: .failed, startedAt: stale),
            op("r", status: .rejected, startedAt: stale),
            op("s", status: .superseded, startedAt: stale),
            op("u", status: .unknown, startedAt: stale),
        ])

        let deleted = await OperationRetention.sweep(database, now: now)

        #expect(deleted == 5)
        #expect(try await remainingIDs(database).isEmpty)
    }

    /// A mixed table keeps exactly the rows it should and reports what it took.
    @Test func prunesOnlyWhatIsBothTerminalAndOld() async throws {
        let stale = now.addingTimeInterval(-OperationRetention.window - 60)
        let recent = now.addingTimeInterval(-60)
        let database = try await seed([
            op("old-done", status: .completed, startedAt: stale),
            op("old-unknown", status: .unknown, startedAt: stale),
            op("old-active", status: .active, startedAt: stale, entityCode: "DEV2"),
            op("new-done", status: .completed, startedAt: recent),
        ])

        let deleted = await OperationRetention.sweep(database, now: now)

        #expect(deleted == 2)
        #expect(try await remainingIDs(database) == ["old-active", "new-done"])
    }
}
