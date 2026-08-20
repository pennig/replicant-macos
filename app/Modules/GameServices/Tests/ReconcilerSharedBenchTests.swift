//
//  ReconcilerSharedBenchTests.swift
//  Replicould — GameServices
//
//  A print completion selects among a bench's live jobs by matching the
//  device type it names, falling back to the oldest.
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

/// A completion selects among a bench's live print jobs by matching the
/// device type it names, falling back to the oldest live job when no live
/// op names a type or none matches.
@Suite struct ReconcilerSharedBenchTests {
    private let bench = "43C9B54A"
    private let start = Date(timeIntervalSince1970: 1_782_000_000)

    private func printOp(
        _ id: String, wanting deviceType: String?, status: OperationStatus, startedAt: Date
    ) -> Operation {
        Operation(
            id: id, entityCode: bench, kind: OperationKind.print.rawValue,
            status: status, source: OperationSource.poll,
            startedAt: startedAt, completesAt: startedAt.addingTimeInterval(2_400),
            lastConfirmedAt: startedAt,
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

    /// Seeds ops in the given (always answer-defeating) order.
    private func seed(_ ops: [Operation]) async throws -> any DatabaseWriter {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in for op in ops { try Operation.insert { op }.execute(db) } }
        return database
    }

    private func status(_ database: any DatabaseWriter, _ id: String) async throws -> OperationStatus? {
        try await database.read { db in try Operation.where { $0.id.eq(id) }.fetchOne(db) }?.status
    }

    /// The live incident: a `defence_grid` completion belongs to a live sibling
    /// job, not the older `ftl_relay` print — selection must find it rather
    /// than falling back to age.
    @Test func aMatchingTypeClosesItsOwnJobEvenWhenYounger() async throws {
        let older = printOp("op-relay", wanting: "ftl_relay", status: .active, startedAt: start)
        let younger = printOp("op-grid", wanting: "defence_grid", status: .enqueued, startedAt: start.addingTimeInterval(60))
        let database = try await seed([older, younger])

        let closed = await withDependencies { $0.defaultDatabase = database } operation: {
            await Reconciler().applyOperationEvent(completion("defence_grid", newCode: "79A4FD5C"))
        }

        #expect(closed)
        #expect(try await status(database, "op-grid") == .completed)
        #expect(try await status(database, "op-relay") == .active)
    }

    /// The job's own completion closes it and records the code the dispatch
    /// response withheld, even with an older untyped sibling on the bench.
    @Test func theRequestedTypeStillClosesOverAnOlderSibling() async throws {
        let older = printOp("op-other", wanting: nil, status: .active, startedAt: start)
        let younger = printOp("op-relay", wanting: "ftl_relay", status: .enqueued, startedAt: start.addingTimeInterval(60))
        let database = try await seed([older, younger])

        let closed = await withDependencies { $0.defaultDatabase = database } operation: {
            await Reconciler().applyOperationEvent(completion("ftl_relay", newCode: "9161CE8B"))
        }

        let op = try await database.read { db in try Operation.where { $0.id.eq("op-relay") }.fetchOne(db) }
        #expect(closed)
        #expect(op?.status == OperationStatus.completed)
        #expect(op?.detail["result"]?["new_device_code"]?.stringValue == "9161CE8B")
        #expect(try await status(database, "op-other") == .active)
    }

    /// Neither live op names what arrived, so selection falls back to age —
    /// the older job closes, not the younger, merely-mismatched one.
    @Test func noMatchFallsBackToTheOlderJob() async throws {
        let older = printOp("op-old", wanting: nil, status: .active, startedAt: start)
        let younger = printOp("op-mismatched", wanting: "mining_drone", status: .enqueued, startedAt: start.addingTimeInterval(60))
        let database = try await seed([younger, older])

        let closed = await withDependencies { $0.defaultDatabase = database } operation: {
            await Reconciler().applyOperationEvent(completion("defence_grid", newCode: "79A4FD5C"))
        }

        #expect(closed)
        #expect(try await status(database, "op-old") == .completed)
        #expect(try await status(database, "op-mismatched") == .enqueued)
    }

    /// **The path production takes.** `GameSync.deviceRoute` routes every event
    /// carrying a parseable `createdAt` through `applyDeviceEvent`; both copies
    /// must select the same op.
    @Test func theEventPathSelectsTheMatchingJob() async throws {
        let older = printOp("op-relay", wanting: "ftl_relay", status: .active, startedAt: start)
        let younger = printOp("op-grid", wanting: "defence_grid", status: .enqueued, startedAt: start.addingTimeInterval(60))
        let database = try await seed([older, younger])

        let closed = await withDependencies { $0.defaultDatabase = database } operation: {
            await Reconciler().applyDeviceEvent(
                deviceCode: bench, event: completion("defence_grid", newCode: "2ADECE40"),
                location: nil, stow: nil, eventTime: start.addingTimeInterval(600)
            )
        }

        #expect(closed)
        #expect(try await status(database, "op-grid") == .completed)
        #expect(try await status(database, "op-relay") == .active)
    }

    /// The poll path names no device type — its settled-device read is its own
    /// proof — so it remains the backstop that closes the oldest live job.
    @Test func thePollPathClosesTheOldestLiveJob() async throws {
        let older = printOp("op-old", wanting: "ftl_relay", status: .active, startedAt: start)
        let younger = printOp("op-new", wanting: "ftl_relay", status: .enqueued, startedAt: start.addingTimeInterval(60))
        let database = try await seed([younger, older])

        let closed = await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(start.addingTimeInterval(3_000))
        } operation: {
            await Reconciler().completeOpenOperation(on: bench, source: .poll, eventTime: nil, result: nil)
        }

        #expect(closed)
        #expect(try await status(database, "op-old") == .completed)
        #expect(try await status(database, "op-new") == .enqueued)
    }
}
