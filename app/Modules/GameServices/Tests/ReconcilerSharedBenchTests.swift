//
//  ReconcilerSharedBenchTests.swift
//  Replicould — GameServices
//
//  A print completion may only close a job that asked for the device type it
//  reports.
//

import API
import ComposableArchitecture
import Foundation
import GameDatabase
import GameModels
import SQLiteData
import Testing
import Utils
@testable import GameServices

private typealias Operation = GameModels.Operation

/// One autofactory runs a queue the server sizes at ten, while
/// `operation_one_open_per_device` lets the client hold a single open op for
/// that bench. So a completion arriving there is often some other run's job,
/// and closing the open op on device code alone stamped a contradicting result
/// into it — 23 of the live ledger's 235 resolved print ops.
@Suite struct ReconcilerSharedBenchTests {
    private let bench = "43C9B54A"
    private let start = Date(timeIntervalSince1970: 1_782_000_000)

    private func printOp(wanting deviceType: String?) -> Operation {
        Operation(
            id: "op-print", entityCode: bench, kind: OperationKind.print.rawValue,
            status: OperationStatus.active, source: OperationSource.poll,
            startedAt: start, completesAt: start.addingTimeInterval(2_400),
            lastConfirmedAt: start,
            detail: deviceType.map {
                .object(["params": .object(["device_type": .string($0)])])
            } ?? .object([:])
        )
    }

    private func completion(_ deviceType: String, newCode: String) -> GameEventEnvelope {
        GameEventEnvelope(
            id: "1-0", category: "print", event: "print.completed", deviceCode: bench,
            payload: ["new_device_code": .string(newCode), "device_type": .string(deviceType)],
            createdAt: start.addingTimeInterval(600).ISO8601Format()
        )
    }

    private func seed(_ op: Operation) async throws -> any DatabaseWriter {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in try Operation.insert { op }.execute(db) }
        return database
    }

    private func stored(_ database: any DatabaseWriter) async throws -> Operation? {
        try await database.read { db in try Operation.where { $0.id.eq("op-print") }.fetchOne(db) }
    }

    /// The live incident: a relay run's print op was closed by a `defence_grid`
    /// completion off the same bench, so the run stopped believing its print was
    /// in flight and waited out its deadline for a relay still in the queue.
    @Test func aForeignTypeCompletionClosesNothing() async throws {
        let database = try await seed(printOp(wanting: "ftl_relay"))

        let closed = await withDependencies { $0.defaultDatabase = database } operation: {
            await Reconciler().applyOperationEvent(completion("defence_grid", newCode: "79A4FD5C"))
        }

        let op = try await stored(database)
        #expect(closed == false)
        #expect(op?.status == OperationStatus.active)
        #expect(op?.detail["result"] == nil)
    }

    /// The job's own completion still closes it and still records the code the
    /// dispatch response withheld.
    @Test func theRequestedTypeStillCloses() async throws {
        let database = try await seed(printOp(wanting: "ftl_relay"))

        let closed = await withDependencies { $0.defaultDatabase = database } operation: {
            await Reconciler().applyOperationEvent(completion("ftl_relay", newCode: "9161CE8B"))
        }

        let op = try await stored(database)
        #expect(closed)
        #expect(op?.status == OperationStatus.completed)
        #expect(op?.detail["result"]?["new_device_code"]?.stringValue == "9161CE8B")
    }

    /// An op that never recorded what it asked for cannot be contradicted, so
    /// it keeps closing on the device code alone.
    @Test func anUntypedJobIsUnaffected() async throws {
        let database = try await seed(printOp(wanting: nil))

        let closed = await withDependencies { $0.defaultDatabase = database } operation: {
            await Reconciler().applyOperationEvent(completion("defence_grid", newCode: "79A4FD5C"))
        }

        #expect(closed)
        #expect(try await stored(database)?.status == OperationStatus.completed)
    }

    /// The poll path names no device type — its settled-device read is its own
    /// proof — so it remains the backstop that clears a job whose completion
    /// event the guard above declined.
    @Test func thePollPathStillCloses() async throws {
        let database = try await seed(printOp(wanting: "ftl_relay"))

        let closed = await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(start.addingTimeInterval(3_000))
        } operation: {
            await Reconciler().completeOpenOperation(
                on: bench, source: .poll, eventTime: nil, result: nil
            )
        }

        #expect(closed)
        #expect(try await stored(database)?.status == OperationStatus.completed)
    }
}
