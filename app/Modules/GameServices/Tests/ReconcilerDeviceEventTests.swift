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
}
