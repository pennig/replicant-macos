//
//  ReconcilerOperationTests.swift
//  Replicould — DependencyClients
//
//  A completion event (`print_complete`) closes the device's open operation and
//  folds its result (the `new_device_code` the dispatch response withheld) into
//  the op's detail — §4.4 "the event is closer to truth than to a hint."
//

import API
import ComposableArchitecture
import Foundation
import SQLiteData
import Testing
import Utils
@testable import DependencyClients

/// Disambiguate from `Foundation.Operation`.
private typealias Operation = DependencyClients.Operation

@Suite struct ReconcilerOperationTests {

    private func makeDatabase() throws -> any DatabaseWriter {
        let database = try SQLiteData.defaultDatabase()
        var migrator = DatabaseMigrator()
        Operation.registerMigrations(&migrator)
        try migrator.migrate(database)
        return database
    }

    @Test func printCompleteClosesOpenOpAndRecordsResult() async throws {
        let database = try makeDatabase()
        try await database.write { db in
            try Operation.insert {
                Operation(
                    id: "op1", entityCode: "965AC2C3", kind: OperationKind.print.rawValue,
                    status: OperationStatus.enqueued.rawValue, source: OperationSource.poll.rawValue,
                    startedAt: Date(timeIntervalSince1970: 0), completesAt: nil,
                    lastConfirmedAt: Date(timeIntervalSince1970: 0), detail: .object([:])
                )
            }.execute(db)
        }

        let raw = #"""
        {"type":"event","event_type":"print_complete","device_code":"965AC2C3","payload":{"new_device_code":"1F63E913","device_type":"ftl_beacon"},"timestamp":"2026-06-26T01:00:00Z"}
        """#
        let event = try UnifiedEvent(relayEvent: RelayEvent(id: "1-0", raw: Data(raw.utf8)))

        await withDependencies {
            $0.defaultDatabase = database
        } operation: {
            await Reconciler().applyOperationEvent(event)
        }

        let stored = try await database.read { db in
            try Operation.where { $0.id.eq("op1") }.fetchOne(db)
        }
        #expect(stored?.status == OperationStatus.completed.rawValue)
        #expect(stored?.source == OperationSource.event.rawValue)
        #expect(stored?.detail["result"]?["new_device_code"]?.stringValue == "1F63E913")
    }

    /// No open op on the device → the event is a harmless no-op.
    @Test func printCompleteWithNoOpenOpIsNoOp() async throws {
        let database = try makeDatabase()
        let raw = #"{"type":"event","event_type":"print_complete","device_code":"NOPE","payload":{},"timestamp":"2026-06-26T01:00:00Z"}"#
        let event = try UnifiedEvent(relayEvent: RelayEvent(id: "1-0", raw: Data(raw.utf8)))

        await withDependencies {
            $0.defaultDatabase = database
        } operation: {
            await Reconciler().applyOperationEvent(event)
        }

        let count = try await database.read { db in try Operation.fetchCount(db) }
        #expect(count == 0)
    }
}
