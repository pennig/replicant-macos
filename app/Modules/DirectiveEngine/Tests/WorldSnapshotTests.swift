//
//  WorldSnapshotTests.swift
//  Replicould — DirectiveEngine
//
//  The read-only view of reconciled state a step machine reasons over. Built
//  from SQLite, never from raw events — that invariant is what makes missions
//  replay-immune and loop-proof.
//

import Foundation
import GameDatabase
import GameModels
import SQLiteData
import Testing
import Utils
@testable import DirectiveEngine

private typealias Operation = GameModels.Operation

private func device(_ code: String) -> Device {
    Device(
        deviceCode: code, deviceType: "transport_hauler", replicantCode: "R1",
        status: "idle", location: "SOL-3", locationName: nil, operationalCapacity: 100,
        queueSize: 0, stowedInDeviceCode: nil, controllerDeviceCode: nil,
        attachedToDeviceCode: nil, createdAt: Date(timeIntervalSince1970: 0),
        availableCommands: [], features: [], tags: [], detail: .object([:]),
        updatedAt: Date(timeIntervalSince1970: 0), firstSeenAt: Date(timeIntervalSince1970: 0)
    )
}

private func op(_ id: String, device: String, status: OperationStatus) -> Operation {
    Operation(
        id: id, entityCode: device, kind: OperationKind.travel.rawValue,
        status: status, source: OperationSource.optimistic,
        startedAt: Date(timeIntervalSince1970: 0), completesAt: nil,
        lastConfirmedAt: Date(timeIntervalSince1970: 0), detail: .object([:])
    )
}

@Suite("WorldSnapshot")
struct WorldSnapshotTests {
    /// Devices and the one open op per device are keyed for O(1) lookup, and a
    /// CLOSED op is absent — a step machine asking "is this device busy?" must
    /// never see a completed op as in progress.
    @Test func readsDevicesAndOnlyOpenOperations() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Device.insert { device("VES1") }.execute(db)
            try Device.insert { device("AMI1") }.execute(db)
            try Operation.insert { op("OP1", device: "VES1", status: .active) }.execute(db)
            try Operation.insert { op("OP2", device: "AMI1", status: .completed) }.execute(db)
        }
        let now = Date(timeIntervalSince1970: 5_000)
        let world = try await WorldSnapshot.read(from: database, now: now)

        #expect(world.devices.keys.sorted() == ["AMI1", "VES1"])
        #expect(world.device("VES1")?.deviceCode == "VES1")
        #expect(world.openOperation(for: "VES1")?.id == "OP1")
        #expect(world.openOperation(for: "AMI1") == nil)
        #expect(world.now == now)
    }

    /// An optimistic op counts as open: it is a command the app has staged but
    /// the server has not confirmed, and re-issuing that step would double-post.
    @Test func optimisticOpsCountAsOpen() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Device.insert { device("VES1") }.execute(db)
            try Operation.insert { op("OP1", device: "VES1", status: .optimistic) }.execute(db)
        }
        let world = try await WorldSnapshot.read(from: database, now: Date(timeIntervalSince1970: 0))
        #expect(world.openOperation(for: "VES1")?.id == "OP1")
    }

    /// An empty database is a valid snapshot, not an error — the engine starts
    /// before the fleet has cold-loaded.
    @Test func emptyDatabaseYieldsAnEmptySnapshot() async throws {
        let database = try GameDatabase.bootstrap()
        let world = try await WorldSnapshot.read(from: database, now: Date(timeIntervalSince1970: 1))
        #expect(world.devices.isEmpty)
        #expect(world.openOperations.isEmpty)
    }
}
