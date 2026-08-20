//
//  ReconcilerCargoEventTests.swift
//  Replicould — GameServices
//
//  `applyDeviceEvent` folds a transport event's `cargo_after` into the device
//  row, in the same write as the location/stow patch. These two events are the
//  only ones reporting a hold's contents, and `detail.cargo_used` is what the
//  outbound load guard reads. See memory: transport-events-carry-the-hold.md.
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

@Suite struct ReconcilerCargoEventTests {

    private func seedFreighter(
        _ database: any DatabaseWriter,
        code: String = "F1",
        detail: JSONValue,
        updatedAt: Date
    ) async throws {
        let device = Device(
            deviceCode: code, deviceType: "cargo_freighter", replicantCode: "R1",
            status: "idle", location: "SOL-1", locationName: nil, operationalCapacity: 100,
            queueSize: 0, stowedInDeviceCode: nil, controllerDeviceCode: nil,
            attachedToDeviceCode: nil, createdAt: Date(timeIntervalSince1970: 0),
            availableCommands: [], features: [], tags: [],
            detail: detail, updatedAt: updatedAt, firstSeenAt: updatedAt
        )
        try await database.write { db in try Device.upsert { device }.execute(db) }
    }

    private func row(_ database: any DatabaseWriter, _ code: String = "F1") async throws -> Device? {
        try await database.read { db in try Device.where { $0.deviceCode.eq(code) }.fetchOne(db) }
    }

    private func transportEvent(
        _ name: String, cargoAfter: Double, capacity: Double? = 500, createdAt: Date
    ) -> GameEventEnvelope {
        var payload: [String: JSONValue] = ["cargo_after": .number(cargoAfter)]
        if let capacity { payload["cargo_capacity"] = .number(capacity) }
        return GameEventEnvelope(
            id: "1-0", category: "transport", event: name,
            deviceCode: "F1", location: "SOL-1",
            payload: payload, createdAt: createdAt.ISO8601Format()
        )
    }

    /// A collect's report is the row's only evidence the units are aboard —
    /// `collect_resources` opens no operation for the load guard to wait on.
    @Test func collectedEventWritesWhatIsAboard() async throws {
        let database = try GameDatabase.bootstrap()
        let t0 = Date(timeIntervalSince1970: 1_782_000_000)
        try await seedFreighter(
            database,
            detail: .object(["cargo_used": .number(0), "cargo_capacity": .number(500)]),
            updatedAt: t0
        )

        let collected = t0.addingTimeInterval(60)
        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(collected)
        } operation: {
            await Reconciler().applyDeviceEvent(
                deviceCode: "F1",
                event: transportEvent("transport.collected", cargoAfter: 350, createdAt: collected),
                location: "SOL-1", stow: nil, eventTime: collected
            )
        }

        let device = try await row(database)
        #expect(device?.cargoUsed == 350)
        #expect(device?.cargoRemaining == 150)
    }

    /// The homeward mirror: `confirmDeposit` requires every hull empty and
    /// judges that by `cargoUsed`, so both legs need the same patch.
    @Test func deliveredEventEmptiesTheHold() async throws {
        let database = try GameDatabase.bootstrap()
        let t0 = Date(timeIntervalSince1970: 1_782_000_000)
        try await seedFreighter(
            database,
            detail: .object(["cargo_used": .number(500), "cargo_capacity": .number(500)]),
            updatedAt: t0
        )

        let delivered = t0.addingTimeInterval(60)
        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(delivered)
        } operation: {
            await Reconciler().applyDeviceEvent(
                deviceCode: "F1",
                event: transportEvent("transport.delivered", cargoAfter: 0, createdAt: delivered),
                location: "SOL-1", stow: nil, eventTime: delivered
            )
        }

        #expect(try await row(database)?.cargoUsed == 0)
    }

    /// The report carries the hold's size too, and a row that never learned its
    /// capacity reads `cargoRemaining` as 0 — a hull that can take nothing.
    @Test func reportTeachesTheRowItsCapacity() async throws {
        let database = try GameDatabase.bootstrap()
        let t0 = Date(timeIntervalSince1970: 1_782_000_000)
        try await seedFreighter(database, detail: .object([:]), updatedAt: t0)

        let collected = t0.addingTimeInterval(60)
        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(collected)
        } operation: {
            await Reconciler().applyDeviceEvent(
                deviceCode: "F1",
                event: transportEvent("transport.collected", cargoAfter: 350, createdAt: collected),
                location: "SOL-1", stow: nil, eventTime: collected
            )
        }

        let device = try await row(database)
        #expect(device?.cargoCapacity == 500)
        #expect(device?.cargoRemaining == 150)
    }

    /// Only a cargo report may write the hold. Every other device event reaches
    /// this same call (`deviceRoute` matches `.all`), and one that says nothing
    /// about cargo must leave the field to the reader that does.
    @Test func unrelatedEventLeavesTheHoldAlone() async throws {
        let database = try GameDatabase.bootstrap()
        let t0 = Date(timeIntervalSince1970: 1_782_000_000)
        try await seedFreighter(
            database,
            detail: .object(["cargo_used": .number(350), "cargo_capacity": .number(500)]),
            updatedAt: t0
        )

        let moved = t0.addingTimeInterval(60)
        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(moved)
        } operation: {
            await Reconciler().applyDeviceEvent(
                deviceCode: "F1",
                event: GameEventEnvelope(
                    id: "1-0", category: "travel", event: "travel.departed",
                    deviceCode: "F1", location: "SOL-1",
                    payload: ["cargo_after": .number(0)], createdAt: moved.ISO8601Format()
                ),
                location: "SOL-1", stow: nil, eventTime: moved
            )
        }

        #expect(
            try await row(database)?.cargoUsed == 350,
            "travel.departed is not a cargo report, even carrying the key"
        )
    }

    /// The patch sits BELOW the tolerance guard: a replayed report arriving
    /// after a full read must not walk the hold backwards.
    @Test func replayedReportCannotOverwriteANewerRead() async throws {
        let database = try GameDatabase.bootstrap()
        let t0 = Date(timeIntervalSince1970: 1_782_000_000)
        // A full device read landed well after the event's second.
        try await seedFreighter(
            database,
            detail: .object(["cargo_used": .number(500), "cargo_capacity": .number(500)]),
            updatedAt: t0.addingTimeInterval(120)
        )

        let staleReport = t0.addingTimeInterval(60)
        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(t0.addingTimeInterval(180))
        } operation: {
            await Reconciler().applyDeviceEvent(
                deviceCode: "F1",
                event: transportEvent("transport.collected", cargoAfter: 350, createdAt: staleReport),
                location: "SOL-1", stow: nil, eventTime: staleReport
            )
        }

        #expect(try await row(database)?.cargoUsed == 500, "the newer read is authoritative")
    }
}
