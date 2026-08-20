//
//  WorldCoreTests.swift
//  Replicould — DirectiveEngine
//
//  The global half of a world read — the 13 fields identical for every
//  directive, and therefore the half worth reading once per tick.
//

import Foundation
import GameDatabase
import GameModels
import SQLiteData
import Testing
import UniverseModels
@testable import DirectiveEngine

@Suite struct WorldCoreEquivalence {
    /// The extraction is a refactor: a core read inside the same transaction
    /// must produce exactly the fields the composed snapshot exposes. This is
    /// the test that makes Tasks 4-8 safe to attempt.
    @Test func matchesTheSnapshotItComposes() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Device.insert {
                Device(
                    deviceCode: "V1", deviceType: "transport_hauler", replicantCode: "R1",
                    status: "idle", location: "SOL-3", locationName: nil,
                    operationalCapacity: 100, queueSize: 0, stowedInDeviceCode: nil,
                    controllerDeviceCode: nil, attachedToDeviceCode: nil,
                    createdAt: Date(timeIntervalSince1970: 0), availableCommands: [],
                    features: [], tags: [], detail: .object([:]),
                    updatedAt: Date(timeIntervalSince1970: 0),
                    firstSeenAt: Date(timeIntervalSince1970: 0)
                )
            }.execute(db)
            try LocationFootprint.insert {
                LocationFootprint(
                    location: "SOL-3", devices: 1, resources: 500, resourceSites: 0,
                    locationEvents: 0, replicants: 0,
                    fetchedAt: Date(timeIntervalSince1970: 0)
                )
            }.execute(db)
        }

        let core = try await database.read { db in try WorldCore.read(from: db) }
        let world = try await WorldSnapshot.read(
            from: database, now: Date(timeIntervalSince1970: 100),
            directive: directiveFixture(id: "D1", deviceCode: "V1", targets: ["SOL"])
        )

        #expect(core.devices == world.devices)
        #expect(core.footprints == world.footprints)
        #expect(core.openOperations == world.openOperations)
        #expect(core.queuedOperations == world.queuedOperations)
        #expect(core.starPositions == world.starPositions)
        #expect(core.components == world.components)
        #expect(core.blueprintBills == world.blueprintBills)
        #expect(core.blueprintComponents == world.blueprintComponents)
        #expect(core.blueprintPrintTimes == world.blueprintPrintTimes)
        #expect(core.theatres == world.theatres)
        #expect(core.locationEvents == world.locationEvents)
        #expect(core.replicantHostDevices == world.replicantHostDevices)
        #expect(core.peers == world.peers)
    }
}
