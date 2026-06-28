//
//  DevicesFeatureTests.swift
//  Replicould — Devices feature
//
//  The reducer's two jobs: cold-load the fleet on first run (reconciling each
//  device into SQLite) and forward a confirmed command to `CommandClient`.
//

import ComposableArchitecture
import DependencyClients
import Foundation
import SQLiteData
import Testing
@testable import DevicesFeature

private func makeDatabase() throws -> any DatabaseWriter {
    let database = try SQLiteData.defaultDatabase()
    var migrator = DatabaseMigrator()
    Device.registerMigrations(&migrator)
    try migrator.migrate(database)
    return database
}

private func device(_ code: String) -> Device {
    Device(
        deviceCode: code, deviceType: "mining_drone", replicantCode: "R1", status: "idle",
        location: nil, locationName: nil, operationalCapacity: 100, queueSize: 0,
        stowedInDeviceCode: nil, controllerDeviceCode: nil, attachedToDeviceCode: nil,
        createdAt: Date(timeIntervalSince1970: 0), availableCommands: [], features: [], tags: [],
        detail: .object([:]), updatedAt: Date(timeIntervalSince1970: 1_000),
        firstSeenAt: Date(timeIntervalSince1970: 1_000)
    )
}

@MainActor
@Suite struct DevicesFeatureTests {

    /// An empty fleet triggers a cold-load on `.task`, persisting the devices.
    @Test func emptyFleetColdLoadsOnTask() async throws {
        let database = try makeDatabase()
        let store = TestStore(initialState: DevicesFeature.State()) {
            DevicesFeature()
        } withDependencies: {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 2_000))
            $0.devicesClient.fetchAll = { [device("A"), device("B")] }
        }
        store.exhaustivity = .off

        await store.send(.task)
        await store.receive(\.load)
        await store.receive(\.loadSucceeded)

        let count = try await database.read { db in try Device.fetchCount(db) }
        #expect(count == 2)
    }

    /// A non-empty fleet does not cold-load on `.task` (the relay keeps it warm).
    @Test func nonEmptyFleetSkipsColdLoad() async throws {
        let database = try makeDatabase()
        try await database.write { db in try Device.insert { device("A") }.execute(db) }

        let store = TestStore(initialState: DevicesFeature.State()) {
            DevicesFeature()
        } withDependencies: {
            $0.defaultDatabase = database
            $0.devicesClient.fetchAll = { Issue.record("should not cold-load"); return [] }
        }
        store.exhaustivity = .off

        await store.send(.task)   // no .load follows
    }

    /// A confirmed command is forwarded to `CommandClient.dispatch`.
    @Test func commandConfirmedDispatches() async throws {
        let database = try makeDatabase()
        let dispatched = LockIsolated<(OperationKind, String, CommandParams)?>(nil)

        let store = TestStore(initialState: DevicesFeature.State()) {
            DevicesFeature()
        } withDependencies: {
            $0.defaultDatabase = database
            $0.commandClient.dispatch = { kind, code, params in
                dispatched.setValue((kind, code, params))
                return .accepted(operationID: "op")
            }
        }
        store.exhaustivity = .off

        await store.send(.commandConfirmed(kind: .travel, deviceCode: "A", params: CommandParams(destination: "X")))
        await store.finish()

        #expect(dispatched.value?.0 == .travel)
        #expect(dispatched.value?.1 == "A")
        #expect(dispatched.value?.2.destination == "X")
    }
}
