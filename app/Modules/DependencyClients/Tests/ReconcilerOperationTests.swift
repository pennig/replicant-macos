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

    /// A survey drone mid-`searching`, with the `scan` activity block the backend
    /// attaches: a `target`, a `started_at`, and an `eta_seconds` countdown (no
    /// absolute `completes_at`).
    private func searchingDevice(_ code: String) -> Device {
        Device(
            deviceCode: code, deviceType: "survey_drone", replicantCode: "R1",
            status: "searching",
            location: "ATIANFU-BELT-1", locationName: nil, operationalCapacity: 100,
            queueSize: 0, stowedInDeviceCode: nil, controllerDeviceCode: nil,
            attachedToDeviceCode: nil, createdAt: Date(timeIntervalSince1970: 0),
            availableCommands: [], features: [], tags: [],
            detail: .object([
                "scan": .object([
                    "target": .string("ATIANFU-BELT-1"),
                    "started_at": .string("1970-01-01T00:10:00Z"),
                    "progress_percent": .number(29.5),
                    "eta_seconds": .number(200),
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
                    status: OperationStatus.enqueued, source: OperationSource.poll,
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
        #expect(stored?.status == OperationStatus.completed)
        #expect(stored?.source == OperationSource.event)
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
        #expect(op?.status == OperationStatus.active)
        #expect(op?.source == OperationSource.poll)
        #expect(op?.completesAt != nil)
        // The bar needs a positive span: completes_at is 25 min after started_at.
        if let op, let completesAt = op.completesAt {
            #expect(completesAt > op.startedAt)
        }
    }

    /// A queued print op (no deadline) is promoted to active — not duplicated —
    /// once the snapshot shows it has actually started, so its progress bar can
    /// draw. Same row (id preserved), now carrying the snapshot's deadline/start.
    @Test func queuedOpPromotedToActiveWhenPrintingStarts() async throws {
        let database = try makeDatabase()
        try await database.write { db in
            try Operation.insert {
                Operation(
                    id: "existing", entityCode: "965AC2C3", kind: OperationKind.print.rawValue,
                    status: OperationStatus.enqueued, source: OperationSource.optimistic,
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

        let ops = try await database.read { db in
            try Operation.where { $0.entityCode.eq("965AC2C3") }.fetchAll(db)
        }
        #expect(ops.count == 1)
        let op = ops.first
        #expect(op?.id == "existing")
        #expect(op?.status == OperationStatus.active)
        #expect(op?.completesAt != nil)
        if let op, let completesAt = op.completesAt {
            #expect(completesAt > op.startedAt)
        }
    }

    /// An `optimistic` op (dispatch still in flight) is left untouched — dispatch
    /// owns its confirmation; reconcile must not race it.
    @Test func optimisticOpLeftForDispatchToConfirm() async throws {
        let database = try makeDatabase()
        try await database.write { db in
            try Operation.insert {
                Operation(
                    id: "staging", entityCode: "965AC2C3", kind: OperationKind.print.rawValue,
                    status: OperationStatus.optimistic, source: OperationSource.optimistic,
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

        let ops = try await database.read { db in
            try Operation.where { $0.entityCode.eq("965AC2C3") }.fetchAll(db)
        }
        #expect(ops.count == 1)
        #expect(ops.first?.status == OperationStatus.optimistic)
    }

    /// Meeting a survey drone mid-search (a `scan` block with an `eta_seconds`
    /// countdown and no `completes_at`) adopts an active `search` op whose
    /// deadline is the fetch event-time plus the remaining ETA — so a cold-load
    /// surfaces the search and its progress bar.
    @Test func searchingSnapshotAdoptsActiveSearchOpWithDeadline() async throws {
        let database = try makeDatabase()

        await withDependencies {
            $0.defaultDatabase = database
            $0.uuid = .incrementing
        } operation: {
            await Reconciler().ingest(searchingDevice("2586E328"))
        }

        let op = try await database.read { db in
            try Operation.where { $0.entityCode.eq("2586E328") }.fetchOne(db)
        }
        #expect(op?.kind == OperationKind.search.rawValue)
        #expect(op?.status == OperationStatus.active)
        #expect(op?.source == OperationSource.poll)
        // updatedAt (1_000) + eta_seconds (200): eta is *remaining* time, so the
        // deadline anchors on the fetch time, not started_at.
        #expect(op?.completesAt == Date(timeIntervalSince1970: 1_200))
    }

    /// A `scan_complete` event closes the drone's open search op — the search
    /// found a site and the drone now *tracks* it (it never settles to idle), so
    /// the event, not a settled status, is the completion signal.
    @Test func scanCompleteClosesOpenSearchOp() async throws {
        let database = try makeDatabase()
        try await database.write { db in
            try Operation.insert {
                Operation(
                    id: "s1", entityCode: "2586E328", kind: OperationKind.search.rawValue,
                    status: OperationStatus.active, source: OperationSource.poll,
                    startedAt: Date(timeIntervalSince1970: 0), completesAt: Date(timeIntervalSince1970: 1_200),
                    lastConfirmedAt: Date(timeIntervalSince1970: 0), detail: .object([:])
                )
            }.execute(db)
        }

        let raw = #"{"type":"event","event_type":"scan_complete","device_code":"2586E328","payload":null,"timestamp":"2026-06-29T00:16:14Z"}"#
        let event = try UnifiedEvent(relayEvent: RelayEvent(id: "1-0", raw: Data(raw.utf8)))

        await withDependencies {
            $0.defaultDatabase = database
        } operation: {
            await Reconciler().applyOperationEvent(event)
        }

        let stored = try await database.read { db in
            try Operation.where { $0.id.eq("s1") }.fetchOne(db)
        }
        #expect(stored?.status == OperationStatus.completed)
        #expect(stored?.source == OperationSource.event)
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
