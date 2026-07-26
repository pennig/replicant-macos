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
import UniverseModels
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

private func directive(targets: [String] = ["SOL"]) -> Directive {
    Directive(
        id: "D1", kind: .surveyRun, status: .running, deviceCode: "VES1",
        targets: targets, targetIndex: 0, step: "preflight",
        stepStartedAt: Date(timeIntervalSince1970: 0), returnToOrigin: false,
        originDesignation: nil, attentionReason: nil,
        createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0)
    )
}

@Suite("WorldSnapshot")
struct WorldSnapshotTests {
    /// The snapshot carries THIS directive's log entries and no one else's —
    /// completion detection keys off them, so a neighbouring mission's timeline
    /// must never be mistaken for this one's.
    @Test func loadsOnlyThisDirectivesLogEntries() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try DirectiveLogEntry.insert {
                DirectiveLogEntry(
                    id: "L1", directiveID: "D1", deviceCode: nil, kind: .directiveCompleted,
                    summary: "mine", step: nil, operationID: nil, eventID: "E1",
                    occurredAt: Date(timeIntervalSince1970: 10)
                )
            }.execute(db)
            try DirectiveLogEntry.insert {
                DirectiveLogEntry(
                    id: "L2", directiveID: "D2", deviceCode: nil, kind: .directiveCompleted,
                    summary: "someone else's", step: nil, operationID: nil, eventID: "E2",
                    occurredAt: Date(timeIntervalSince1970: 11)
                )
            }.execute(db)
        }
        let world = try await WorldSnapshot.read(
            from: database, now: Date(timeIntervalSince1970: 100), directive: directive()
        )
        #expect(world.log.map(\.id) == ["L1"])
    }

    /// Cached system blobs are decoded for the directive's targets, so the
    /// machine can read scan counts without any I/O of its own.
    @Test func decodesCachedSystemsForTheTargets() async throws {
        let database = try GameDatabase.bootstrap()
        let system = StarSystem(designation: "SOL", planetsScanned: 3, planetsTotal: 3)
        let row = try SystemDetail(system: system, hydratedAt: Date(timeIntervalSince1970: 0))
        try await database.write { db in
            try SystemDetail.upsert { row }.execute(db)
        }
        let world = try await WorldSnapshot.read(
            from: database, now: Date(timeIntervalSince1970: 100), directive: directive()
        )
        #expect(world.system("SOL")?.planetsScanned == 3)
        #expect(world.system("NOPE") == nil)
    }

    /// A system the directive doesn't name isn't decoded — the catalogue runs
    /// to thousands of bodies and decoding all of it per tick would be real cost.
    @Test func doesNotDecodeUnrelatedSystems() async throws {
        let database = try GameDatabase.bootstrap()
        let row = try SystemDetail(
            system: StarSystem(designation: "FARAWAY"),
            hydratedAt: Date(timeIntervalSince1970: 0)
        )
        try await database.write { db in
            try SystemDetail.upsert { row }.execute(db)
        }
        let world = try await WorldSnapshot.read(
            from: database, now: Date(timeIntervalSince1970: 100), directive: directive()
        )
        #expect(world.systems.isEmpty)
    }

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
        let world = try await WorldSnapshot.read(from: database, now: now, directive: directive())

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
        let world = try await WorldSnapshot.read(from: database, now: Date(timeIntervalSince1970: 0), directive: directive())
        #expect(world.openOperation(for: "VES1")?.id == "OP1")
    }

    /// An empty database is a valid snapshot, not an error — the engine starts
    /// before the fleet has cold-loaded.
    @Test func emptyDatabaseYieldsAnEmptySnapshot() async throws {
        let database = try GameDatabase.bootstrap()
        let world = try await WorldSnapshot.read(from: database, now: Date(timeIntervalSince1970: 1), directive: directive())
        #expect(world.devices.isEmpty)
        #expect(world.openOperations.isEmpty)
    }
}
