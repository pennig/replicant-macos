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
        Device.registerMigrations(&migrator)
        try migrator.migrate(database)
        return database
    }

    /// A device snapshot mid-`printing`, with the `started_at`/`completes_at`
    /// block the backend attaches to an in-progress device.
    private func printingDevice(_ code: String) -> Device {
        Device(
            deviceCode: code, deviceType: "heaven_vessel", replicantCode: "R1",
            status: "printing (ami_survey_controller)",
            location: "ATIANFU-BELT-1", locationName: nil, operationalCapacity: 100,
            queueSize: 0, stowedInDeviceCode: nil, controllerDeviceCode: nil,
            attachedToDeviceCode: nil, createdAt: Date(timeIntervalSince1970: 0),
            availableCommands: [], features: [], tags: [],
            detail: .object([
                "printing": .object([
                    "started_at": .string("2026-06-28T23:52:27-05:00"),
                    "completes_at": .string("2026-06-29T00:17:27-05:00"),
                    "device_type": .string("ami_survey_controller"),
                ])
            ]),
            updatedAt: Date(timeIntervalSince1970: 1_000),
            firstSeenAt: Date(timeIntervalSince1970: 1_000)
        )
    }

    private func idleDevice(_ code: String) -> Device {
        Device(
            deviceCode: code, deviceType: "mining_drone", replicantCode: "R1", status: "idle",
            location: nil, locationName: nil, operationalCapacity: 100, queueSize: 0,
            stowedInDeviceCode: nil, controllerDeviceCode: nil, attachedToDeviceCode: nil,
            createdAt: Date(timeIntervalSince1970: 0), availableCommands: [], features: [], tags: [],
            detail: .object([:]), updatedAt: Date(timeIntervalSince1970: 1_000),
            firstSeenAt: Date(timeIntervalSince1970: 1_000)
        )
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

    /// Ingesting a device that is already in-progress, with no operation of its
    /// own, adopts an active op carrying the snapshot's start/completion — so a
    /// cold-load or relaunch surfaces the running task and its progress bar.
    @Test func inProgressSnapshotAdoptsActiveOp() async throws {
        let database = try makeDatabase()

        await withDependencies {
            $0.defaultDatabase = database
            $0.uuid = .incrementing
        } operation: {
            await Reconciler().ingest(printingDevice("965AC2C3"))
        }

        let op = try await database.read { db in
            try Operation.where { $0.entityCode.eq("965AC2C3") }.fetchOne(db)
        }
        #expect(op?.kind == OperationKind.print.rawValue)
        #expect(op?.status == OperationStatus.active.rawValue)
        #expect(op?.source == OperationSource.poll.rawValue)
        #expect(op?.completesAt != nil)
        // The bar needs a positive span: completes_at is 25 min after started_at.
        if let op, let completesAt = op.completesAt {
            #expect(completesAt > op.startedAt)
        }
    }

    /// When the device already has an open op (e.g. a dispatched print), ingest
    /// does not adopt a second one.
    @Test func adoptionSkippedWhenOpenOpExists() async throws {
        let database = try makeDatabase()
        try await database.write { db in
            try Operation.insert {
                Operation(
                    id: "existing", entityCode: "965AC2C3", kind: OperationKind.print.rawValue,
                    status: OperationStatus.enqueued.rawValue, source: OperationSource.optimistic.rawValue,
                    startedAt: Date(timeIntervalSince1970: 0), completesAt: nil,
                    lastConfirmedAt: Date(timeIntervalSince1970: 0), detail: .object([:])
                )
            }.execute(db)
        }

        await withDependencies {
            $0.defaultDatabase = database
            $0.uuid = .incrementing
        } operation: {
            await Reconciler().ingest(printingDevice("965AC2C3"))
        }

        let count = try await database.read { db in
            try Operation.where { $0.entityCode.eq("965AC2C3") }.fetchCount(db)
        }
        #expect(count == 1)
    }

    /// A settled (idle) device carries no activity block, so nothing is adopted.
    @Test func settledDeviceAdoptsNothing() async throws {
        let database = try makeDatabase()

        await withDependencies {
            $0.defaultDatabase = database
            $0.uuid = .incrementing
        } operation: {
            await Reconciler().ingest(idleDevice("304F6EC1"))
        }

        let count = try await database.read { db in try Operation.fetchCount(db) }
        #expect(count == 0)
    }
}
