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
    /// `WorldSnapshot.read` composes from the same `WorldCore.read` this test
    /// calls, so the `==` assertions are a WIRING check only, not a query
    /// correctness one; the `!isEmpty` assertions are what carry the weight.
    @Test func matchesTheSnapshotItComposes() async throws {
        let database = try GameDatabase.bootstrap()
        let directive = directiveFixture(id: "D1", deviceCode: "V1", targets: ["SOL"])
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
            try Directive.insert { directive }.execute(db)
            try GameModels.Operation.insert {
                GameModels.Operation(
                    id: "OP1", entityCode: "V1", kind: OperationKind.travel.rawValue,
                    status: .active, source: .optimistic,
                    startedAt: Date(timeIntervalSince1970: 0), completesAt: nil,
                    lastConfirmedAt: Date(timeIntervalSince1970: 0), detail: .object([:])
                )
            }.execute(db)
            try seedStar(db, designation: "SOL", x: 0, y: 0, z: 0)
            try seedRelay(db, code: "REL1", location: "SOL-3")
            try TheatrePin.insert {
                TheatrePin(location: "SOL-3", createdAt: Date(timeIntervalSince1970: 0))
            }.execute(db)
            try Blueprint.insert {
                Blueprint(
                    deviceType: "transport_hauler", shortDescription: "", fullDescription: "",
                    printTime: 600, features: [], directives: [],
                    resources: ResourceCost(structural: 200), stowCapacity: 0, cargoCapacity: 0,
                    attachCapacity: 0, queueSize: 0, strength: 1, currentHubs: nil
                )
            }.execute(db)
            try seedLocationEvent(db, designation: "EVT1", location: "SOL-3")
            try seedReplicant(db, code: "REP1", star: "SOL", hostedDeviceCode: "V1")
        }

        let core = try await database.read { db in try WorldCore.read(from: db) }
        let world = try await WorldSnapshot.read(
            from: database, now: Date(timeIntervalSince1970: 100), directive: directive
        )

        #expect(core.devices == world.devices)
        #expect(core.footprints == world.footprints)
        #expect(core.openOperations == world.openOperations)
        #expect(core.queuedOperations == world.queuedOperations)
        #expect(core.starPositions == world.starPositions)
        #expect(core.components == world.components)
        #expect(!core.components.isEmpty)
        #expect(core.blueprintBills == world.blueprintBills)
        #expect(core.blueprintComponents == world.blueprintComponents)
        #expect(core.blueprintPrintTimes == world.blueprintPrintTimes)
        #expect(core.theatres == world.theatres)
        #expect(!core.theatres.isEmpty)
        #expect(core.locationEvents == world.locationEvents)
        #expect(core.replicantHostDevices == world.replicantHostDevices)
        #expect(core.peers == world.peers)
        #expect(!core.peers.isEmpty)
    }
}
