//
//  ReconcilerDeviceEventTests.swift
//  Replicould — GameServices
//
//  `applyDeviceEvent` closes the op the event completes (if any) and patches
//  the device's location/stow in ONE transaction, so no reader can
//  observe "op closed, old location" between them. See memory:
//  arrival-single-transaction.md.
//

import API
import ComposableArchitecture
import Foundation
import GameDatabase
import GameModels
import SQLiteData
import Testing
@testable import GameServices

/// Disambiguate from `Foundation.Operation`.
private typealias Operation = GameModels.Operation

@Suite struct ReconcilerDeviceEventTests {

    private func seedDevice(
        _ database: any DatabaseWriter,
        code: String = "V1",
        location: String?,
        updatedAt: Date
    ) async throws {
        let device = Device(
            deviceCode: code, deviceType: "heaven_vessel", replicantCode: "R1", status: "travelling",
            location: location, locationName: nil, operationalCapacity: 100, queueSize: 0,
            stowedInDeviceCode: nil, controllerDeviceCode: nil, attachedToDeviceCode: nil,
            createdAt: Date(timeIntervalSince1970: 0), availableCommands: [], features: [], tags: [],
            detail: .object([:]), updatedAt: updatedAt, firstSeenAt: updatedAt
        )
        try await database.write { db in try Device.upsert { device }.execute(db) }
    }

    private func seedOpenOp(
        _ database: any DatabaseWriter,
        id: String = "op1",
        entityCode: String = "V1",
        kind: String = OperationKind.travel.rawValue,
        startedAt: Date
    ) async throws {
        try await database.write { db in
            try Operation.insert {
                Operation(
                    id: id, entityCode: entityCode, kind: kind,
                    status: .active, source: OperationSource.poll,
                    startedAt: startedAt, completesAt: startedAt.addingTimeInterval(60),
                    lastConfirmedAt: startedAt, detail: .object([:])
                )
            }.execute(db)
        }
    }

    private func row(_ database: any DatabaseWriter, _ code: String = "V1") async throws -> Device? {
        try await database.read { db in try Device.where { $0.deviceCode.eq(code) }.fetchOne(db) }
    }

    private func op(_ database: any DatabaseWriter, _ id: String = "op1") async throws -> Operation? {
        try await database.read { db in try Operation.where { $0.id.eq(id) }.fetchOne(db) }
    }

    private func arrivalEvent(location: String = "TAU-2", createdAt: Date) -> GameEventEnvelope {
        GameEventEnvelope(
            id: "1-0", category: "travel", event: "travel.arrived",
            deviceCode: "V1", location: location,
            createdAt: createdAt.ISO8601Format()
        )
    }

    /// The whole point: reading op status and device location back in ONE read
    /// must never observe "closed, old location" — they land in the same write.
    @Test func arrivalClosesOpAndWritesLocationAtomically() async throws {
        let database = try GameDatabase.bootstrap()
        let t0 = Date(timeIntervalSince1970: 1_782_000_000)
        try await seedDevice(database, location: "SOL-1", updatedAt: t0)
        try await seedOpenOp(database, startedAt: t0)

        let arrival = t0.addingTimeInterval(60)
        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(arrival)
        } operation: {
            let closed = await Reconciler().applyDeviceEvent(
                deviceCode: "V1", event: arrivalEvent(createdAt: arrival),
                location: "TAU-2", stow: nil, eventTime: arrival
            )
            #expect(closed)
        }

        // One read, both facts.
        async let storedOp = op(database)
        async let storedDevice = row(database)
        let (o, d) = try await (storedOp, storedDevice)
        #expect(o?.status == OperationStatus.completed)
        #expect(d?.location == "TAU-2")
    }

    /// The op-closing patch is UNCONDITIONAL: the envelope's location is
    /// authoritative regardless of `updatedAt` ordering, because the closing
    /// event carries the truth a stale intervening read cannot override.
    @Test func opClosingEventPatchesEvenWhenRowLooksNewer() async throws {
        let database = try GameDatabase.bootstrap()
        let t0 = Date(timeIntervalSince1970: 1_782_000_000)
        // A read issued AFTER the arrival second landed and stamped the row.
        try await seedDevice(database, location: "SOL-1", updatedAt: t0.addingTimeInterval(61.5))
        try await seedOpenOp(database, startedAt: t0)

        let arrivalSecond = t0.addingTimeInterval(61)
        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(arrivalSecond)
        } operation: {
            let closed = await Reconciler().applyDeviceEvent(
                deviceCode: "V1", event: arrivalEvent(createdAt: arrivalSecond),
                location: "TAU-2", stow: nil, eventTime: arrivalSecond
            )
            #expect(closed)
        }

        let device = try await row(database)
        #expect(device?.location == "TAU-2", "the op closed, so the patch applies unconditionally")
    }

    /// A non-closing event only applies within 1s of `device.updatedAt` — the
    /// tolerance absorbs a second-granular server stamp racing a sub-second
    /// local read; an event that misses the window is still dropped.
    @Test func nonClosingEventUsesOneSecondTolerance() async throws {
        let database = try GameDatabase.bootstrap()
        let t0 = Date(timeIntervalSince1970: 1_782_000_000)
        try await seedDevice(database, location: "SOL-1", updatedAt: t0.addingTimeInterval(61.4))
        // No open op: this is a device.moved-style non-closing event.

        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(t0.addingTimeInterval(100))
        } operation: {
            let withinTolerance = t0.addingTimeInterval(61)
            let closed = await Reconciler().applyDeviceEvent(
                deviceCode: "V1",
                event: GameEventEnvelope(
                    id: "2-0", category: "travel", event: "travel.cruising",
                    deviceCode: "V1", location: "SOL-2", createdAt: withinTolerance.ISO8601Format()
                ),
                location: "SOL-2", stow: nil, eventTime: withinTolerance
            )
            #expect(!closed)
        }
        let applied = try await row(database)
        #expect(applied?.location == "SOL-2", "61 + 1 >= 61.4")

        try await seedDevice(database, location: "SOL-1", updatedAt: t0.addingTimeInterval(61.4))
        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(t0.addingTimeInterval(100))
        } operation: {
            let outsideTolerance = t0.addingTimeInterval(59)
            _ = await Reconciler().applyDeviceEvent(
                deviceCode: "V1",
                event: GameEventEnvelope(
                    id: "3-0", category: "travel", event: "travel.cruising",
                    deviceCode: "V1", location: "SOL-2", createdAt: outsideTolerance.ISO8601Format()
                ),
                location: "SOL-2", stow: nil, eventTime: outsideTolerance
            )
        }
        let dropped = try await row(database)
        #expect(dropped?.location == "SOL-1", "59 + 1 < 61.4")
    }

    /// After a patch, `device.updatedAt` is the client clock (`date.now`), not
    /// the event's own timestamp — every mission watermark in this system is
    /// client-clock, and an event is an observation, not authoritative time.
    @Test func eventPatchStampsClientClock() async throws {
        let database = try GameDatabase.bootstrap()
        let t0 = Date(timeIntervalSince1970: 1_782_000_000)
        try await seedDevice(database, location: "SOL-1", updatedAt: t0)

        let now = t0.addingTimeInterval(500)
        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(now)
        } operation: {
            _ = await Reconciler().applyDeviceEvent(
                deviceCode: "V1",
                event: GameEventEnvelope(
                    id: "4-0", category: "travel", event: "travel.cruising",
                    deviceCode: "V1", location: "SOL-2", createdAt: t0.addingTimeInterval(10).ISO8601Format()
                ),
                location: "SOL-2", stow: nil, eventTime: t0.addingTimeInterval(10)
            )
        }

        let device = try await row(database)
        #expect(device?.updatedAt == now, "stamped with the client clock, not eventTime")
    }

    private func printOp(
        _ id: String, entityCode: String, status: OperationStatus, startedAt: Date, completesAt: Date?
    ) -> Operation {
        Operation(
            id: id, entityCode: entityCode, kind: OperationKind.print.rawValue,
            status: status, source: OperationSource.poll,
            startedAt: startedAt, completesAt: completesAt,
            lastConfirmedAt: startedAt, detail: .object([:])
        )
    }

    private func status(_ database: any DatabaseWriter, _ id: String) async throws -> OperationStatus? {
        try await database.read { db in try Operation.where { $0.id.eq(id) }.fetchOne(db) }?.status
    }

    /// A bench running three print jobs closes the oldest — not whichever row
    /// an unordered fetch happened to surface. Inserted out of the answer's
    /// order (C, A, B), so an unordered pick could not pass by luck.
    @Test func printCompletionClosesTheOldestLiveJob() async throws {
        let database = try GameDatabase.bootstrap()
        let t0 = Date(timeIntervalSince1970: 1_782_000_000)
        let opA = printOp("OP-A", entityCode: "B1", status: .active, startedAt: t0.addingTimeInterval(-120), completesAt: t0.addingTimeInterval(60))
        let opB = printOp("OP-B", entityCode: "B1", status: .enqueued, startedAt: t0.addingTimeInterval(-60), completesAt: nil)
        let opC = printOp("OP-C", entityCode: "B1", status: .enqueued, startedAt: t0.addingTimeInterval(-30), completesAt: nil)
        try await database.write { db in
            try Operation.insert { opC }.execute(db)
            try Operation.insert { opA }.execute(db)
            try Operation.insert { opB }.execute(db)
        }

        let event = GameEventEnvelope(
            id: "1-0", category: "print", event: "print.completed",
            deviceCode: "B1", payload: ["new_device_code": .string("N1")],
            createdAt: t0.ISO8601Format()
        )

        let closed = await withDependencies { $0.defaultDatabase = database } operation: {
            await Reconciler().applyDeviceEvent(
                deviceCode: "B1", event: event, location: nil, stow: nil, eventTime: t0
            )
        }

        #expect(closed)
        #expect(try await status(database, "OP-A") == .completed)
        #expect(try await status(database, "OP-B") == .enqueued)
        #expect(try await status(database, "OP-C") == .enqueued)
    }

    /// A bench running an active job plus an enqueued sibling (inserted
    /// first, defeating an unordered pick) must not promote the sibling when
    /// a poll repeats the running job's own activity — a second active row throws.
    @Test func pollDoesNotPromoteTheEnqueuedSiblingOverTheRunningJob() async throws {
        let database = try GameDatabase.bootstrap()
        let t0 = Date(timeIntervalSince1970: 1_782_000_000)
        let activeStart = t0.addingTimeInterval(-120)
        let activeCompletesAt = activeStart.addingTimeInterval(600)
        let opActive = printOp("OP-ACTIVE", entityCode: "B1", status: .active, startedAt: activeStart, completesAt: activeCompletesAt)
        let opEnqueued = printOp("OP-ENQUEUED", entityCode: "B1", status: .enqueued, startedAt: t0.addingTimeInterval(-60), completesAt: nil)
        try await database.write { db in
            try Operation.insert { opEnqueued }.execute(db)
            try Operation.insert { opActive }.execute(db)
        }

        let device = Device(
            deviceCode: "B1", deviceType: "heaven_vessel", replicantCode: "R1", status: "printing",
            location: nil, locationName: nil, operationalCapacity: 100, queueSize: 0,
            stowedInDeviceCode: nil, controllerDeviceCode: nil, attachedToDeviceCode: nil,
            createdAt: Date(timeIntervalSince1970: 0), availableCommands: [], features: [], tags: [],
            detail: .object([
                "printing": .object([
                    "started_at": .string(activeStart.ISO8601Format()),
                    "completes_at": .string(activeCompletesAt.ISO8601Format()),
                ])
            ]),
            updatedAt: activeStart, firstSeenAt: activeStart
        )

        await withDependencies {
            $0.defaultDatabase = database
            $0.uuid = .incrementing
        } operation: {
            await Reconciler().ingest(device)
        }

        #expect(try await status(database, "OP-ACTIVE") == .active)
        #expect(try await status(database, "OP-ENQUEUED") == .enqueued)
    }

    /// CRITICAL 2's inverse ordering: the enqueued sibling seeded OLDER than
    /// the running job. `live.first { kind matches }` alone would now bind to
    /// the enqueued row and try to promote it — a second `.active` row for
    /// this device, which the unique index refuses. Must not throw, and must
    /// leave both ops exactly where they were.
    @Test func pollDoesNotPromoteAnEnqueuedSiblingSeededOlderThanTheRunningJob() async throws {
        let database = try GameDatabase.bootstrap()
        let t0 = Date(timeIntervalSince1970: 1_782_000_000)
        let activeStart = t0.addingTimeInterval(-60)
        let activeCompletesAt = activeStart.addingTimeInterval(600)
        let opEnqueued = printOp("OP-ENQUEUED", entityCode: "B1", status: .enqueued, startedAt: t0.addingTimeInterval(-120), completesAt: nil)
        let opActive = printOp("OP-ACTIVE", entityCode: "B1", status: .active, startedAt: activeStart, completesAt: activeCompletesAt)
        try await database.write { db in
            try Operation.insert { opActive }.execute(db)
            try Operation.insert { opEnqueued }.execute(db)
        }

        let device = Device(
            deviceCode: "B1", deviceType: "heaven_vessel", replicantCode: "R1", status: "printing",
            location: nil, locationName: nil, operationalCapacity: 100, queueSize: 0,
            stowedInDeviceCode: nil, controllerDeviceCode: nil, attachedToDeviceCode: nil,
            createdAt: Date(timeIntervalSince1970: 0), availableCommands: [], features: [], tags: [],
            detail: .object([
                "printing": .object([
                    "started_at": .string(activeStart.ISO8601Format()),
                    "completes_at": .string(activeCompletesAt.ISO8601Format()),
                ])
            ]),
            updatedAt: activeStart, firstSeenAt: activeStart
        )

        await withDependencies {
            $0.defaultDatabase = database
            $0.uuid = .incrementing
        } operation: {
            await Reconciler().ingest(device)
        }

        #expect(try await status(database, "OP-ACTIVE") == .active)
        #expect(try await status(database, "OP-ENQUEUED") == .enqueued)
    }

    /// CRITICAL 2's other branch: an `.active` op of a DIFFERENT kind is
    /// still live (a stale row the reconciler hasn't closed yet) while an
    /// `.enqueued` op of the snapshot's OWN kind already exists. Promoting
    /// the enqueued op without first closing the stale one would also throw
    /// — two `.active` rows for one device, whatever kinds they track.
    @Test func pollDoesNotPromoteAnEnqueuedOpWhileADifferentKindIsStillActive() async throws {
        let database = try GameDatabase.bootstrap()
        let t0 = Date(timeIntervalSince1970: 1_782_000_000)
        let travelActive = Operation(
            id: "OP-TRAVEL", entityCode: "B1", kind: OperationKind.travel.rawValue,
            status: .active, source: OperationSource.poll,
            startedAt: t0.addingTimeInterval(-300), completesAt: t0.addingTimeInterval(-60),
            lastConfirmedAt: t0.addingTimeInterval(-300), detail: .object([:])
        )
        let mineEnqueued = Operation(
            id: "OP-MINE", entityCode: "B1", kind: OperationKind.mine.rawValue,
            status: .enqueued, source: OperationSource.poll,
            startedAt: t0.addingTimeInterval(-60), completesAt: nil,
            lastConfirmedAt: t0.addingTimeInterval(-60), detail: .object([:])
        )
        try await database.write { db in
            try Operation.insert { travelActive }.execute(db)
            try Operation.insert { mineEnqueued }.execute(db)
        }

        let miningStart = t0.addingTimeInterval(-50)
        let device = Device(
            deviceCode: "B1", deviceType: "heaven_vessel", replicantCode: "R1", status: "mining",
            location: "SOL-2", locationName: nil, operationalCapacity: 100, queueSize: 0,
            stowedInDeviceCode: nil, controllerDeviceCode: nil, attachedToDeviceCode: nil,
            createdAt: Date(timeIntervalSince1970: 0), availableCommands: [], features: [], tags: [],
            detail: .object([
                "mining": .object([
                    "started_at": .string(miningStart.ISO8601Format()),
                    "completes_at": .string(t0.addingTimeInterval(500).ISO8601Format()),
                ])
            ]),
            updatedAt: miningStart, firstSeenAt: miningStart
        )

        await withDependencies {
            $0.defaultDatabase = database
            $0.uuid = .incrementing
        } operation: {
            await Reconciler().ingest(device)
        }

        #expect(try await status(database, "OP-TRAVEL") == .active)
        #expect(try await status(database, "OP-MINE") == .enqueued)
    }
}
