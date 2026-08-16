//
//  CommandDedupTests.swift
//  Replicould — GameServices
//
//  The `ab36b7d` class: a mission dispatching an immediate verb into its own
//  step re-POSTs every tick forever. `CommandGovernor.dispatch` now refuses an
//  identical repeat inside the same step entry — a deferral, not a failure, so
//  no write and no re-stamp.
//

import API
import ComposableArchitecture
import Foundation
import GameDatabase
import GameModels
import GameSession
import SQLiteData
import Testing
@testable import GameServices

private func budgetGameClient(actionsRemaining: Int = 40) -> GameClient {
    GameClient(
        make: { ReplicantSpace.client(apiKey: "") },
        budget: { _ in RateLimitGovernor.Snapshot(limit: 60, remaining: actionsRemaining, resetAt: nil) }
    )
}

@Suite("CommandGovernor de-dup")
struct CommandDedupTests {
    private static let t0 = Date(timeIntervalSince1970: 0)

    private func seedRow(
        _ database: any DatabaseWriter,
        step: String = "activating",
        entityCode: String = "R1",
        kind: String = "activate",
        paramsDigest: String,
        startedAt: Date
    ) async throws {
        try await database.write { db in
            try Operation.insert {
                Operation(
                    id: "SEED", entityCode: entityCode, kind: kind,
                    status: .completed, source: .optimistic,
                    startedAt: startedAt, completesAt: nil, lastConfirmedAt: startedAt,
                    detail: .object([:]), directiveID: "D1", step: step, paramsDigest: paramsDigest
                )
            }.execute(db)
        }
    }

    /// An identical command already recorded in this step entry is refused —
    /// no write, and the stubbed client is never reached.
    @Test func identicalDispatchInsideOneStepEntryIsDeferred() async throws {
        let database = try GameDatabase.bootstrap()
        try await seedRow(database, paramsDigest: CommandParams().dedupKey, startedAt: Self.t0.addingTimeInterval(1))
        let governor = CommandGovernor()
        let owner = CommandOwner(directiveID: "D1", step: "activating", since: Self.t0)

        let result = await withDependencies {
            $0.defaultDatabase = database
            $0.gameClient = budgetGameClient()
            $0.commandClient.dispatchOwned = unimplemented(
                "commandClient.dispatchOwned", placeholder: .accepted(operationID: nil)
            )
        } operation: {
            await governor.dispatch(.simple("activate"), on: "R1", params: CommandParams(), owner: owner)
        }
        #expect(result == .deferred(.duplicate))
    }

    /// A step re-entry (`owner.since` moves past the seeded row's `startedAt`)
    /// is a fresh entry, not a repeat — the dispatch reaches the client.
    @Test func sameDispatchAfterStepRestartIsAllowed() async throws {
        let database = try GameDatabase.bootstrap()
        try await seedRow(database, paramsDigest: CommandParams().dedupKey, startedAt: Self.t0.addingTimeInterval(1))
        let governor = CommandGovernor()
        let owner = CommandOwner(directiveID: "D1", step: "activating", since: Self.t0.addingTimeInterval(2))
        let called = LockIsolated(false)

        let result = await withDependencies {
            $0.defaultDatabase = database
            $0.gameClient = budgetGameClient()
            $0.commandClient.dispatchOwned = { _, _, _, _ in
                called.setValue(true)
                return .accepted(operationID: nil)
            }
        } operation: {
            await governor.dispatch(.simple("activate"), on: "R1", params: CommandParams(), owner: owner)
        }
        #expect(result == .dispatched(.accepted(operationID: nil)))
        #expect(called.value)
    }

    /// Different params hash to a different digest, so they never collide with
    /// the seeded row even inside the same step entry.
    @Test func differentParamsAreNotDuplicates() async throws {
        let database = try GameDatabase.bootstrap()
        try await seedRow(
            database, kind: OperationKind.travel.rawValue,
            paramsDigest: CommandParams(destination: "A").dedupKey, startedAt: Self.t0.addingTimeInterval(1)
        )
        let governor = CommandGovernor()
        let owner = CommandOwner(directiveID: "D1", step: "activating", since: Self.t0)
        let called = LockIsolated(false)

        let result = await withDependencies {
            $0.defaultDatabase = database
            $0.gameClient = budgetGameClient()
            $0.commandClient.dispatchOwned = { _, _, _, _ in
                called.setValue(true)
                return .accepted(operationID: nil)
            }
        } operation: {
            await governor.dispatch(.travel, on: "R1", params: CommandParams(destination: "B"), owner: owner)
        }
        #expect(result == .dispatched(.accepted(operationID: nil)))
        #expect(called.value)
    }

    /// The ticket 06 seam: a `.failed` row from a prior attempt in this step
    /// entry does NOT suppress a retry, while a `.completed` row still does —
    /// pinned side by side so the two can't silently drift apart again.
    @Test func aFailedRowDoesNotSuppressARetryButACompletedRowStillDoes() async throws {
        let database = try GameDatabase.bootstrap()
        let digest = CommandParams().dedupKey
        try await database.write { db in
            try Operation.insert {
                Operation(
                    id: "FAILED", entityCode: "R1", kind: "activate",
                    status: .failed, source: .optimistic,
                    startedAt: Self.t0.addingTimeInterval(1), completesAt: nil,
                    lastConfirmedAt: Self.t0.addingTimeInterval(1),
                    detail: .object([:]), directiveID: "D1", step: "activating", paramsDigest: digest
                )
            }.execute(db)
        }
        let owner = CommandOwner(directiveID: "D1", step: "activating", since: Self.t0)
        let called = LockIsolated(false)

        let result = await withDependencies {
            $0.defaultDatabase = database
            $0.gameClient = budgetGameClient()
            $0.commandClient.dispatchOwned = { _, _, _, _ in
                called.setValue(true)
                return .accepted(operationID: nil)
            }
        } operation: {
            await CommandGovernor().dispatch(.simple("activate"), on: "R1", params: CommandParams(), owner: owner)
        }
        #expect(result == .dispatched(.accepted(operationID: nil)), "a failed attempt must not read as a duplicate")
        #expect(called.value)

        // The same row, `.completed` instead, still refuses the repeat.
        try await database.write { db in
            try Operation.where { $0.id.eq("FAILED") }
                .update { $0.status = #bind(OperationStatus.completed) }
                .execute(db)
        }
        let secondResult = await withDependencies {
            $0.defaultDatabase = database
            $0.gameClient = budgetGameClient()
            $0.commandClient.dispatchOwned = unimplemented(
                "commandClient.dispatchOwned", placeholder: .accepted(operationID: nil)
            )
        } operation: {
            await CommandGovernor().dispatch(.simple("activate"), on: "R1", params: CommandParams(), owner: owner)
        }
        #expect(secondResult == .deferred(.duplicate), "a completed attempt must still read as a duplicate")
    }

    /// A `nil` owner (a manually-issued command) is never de-duped — the query
    /// only runs when a directive owns the dispatch.
    @Test func unownedDispatchIsNeverDeduped() async throws {
        let database = try GameDatabase.bootstrap()
        try await seedRow(database, paramsDigest: CommandParams().dedupKey, startedAt: Self.t0.addingTimeInterval(1))
        let governor = CommandGovernor()
        let called = LockIsolated(false)

        let result = await withDependencies {
            $0.defaultDatabase = database
            $0.gameClient = budgetGameClient()
            $0.commandClient.dispatchOwned = { _, _, _, _ in
                called.setValue(true)
                return .accepted(operationID: nil)
            }
        } operation: {
            await governor.dispatch(.simple("activate"), on: "R1", params: CommandParams(), owner: nil)
        }
        #expect(result == .dispatched(.accepted(operationID: nil)))
        #expect(called.value)
    }
}
