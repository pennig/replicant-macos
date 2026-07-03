//
//  DevicesFeatureTests.swift
//  Replicould — Devices feature
//
//  The reducer's two jobs: cold-load the fleet on first run (reconciling each
//  device into SQLite) and forward a confirmed command to `CommandClient`.
//

import ComposableArchitecture
import Foundation
import GameModels
import GameServices
import SQLiteData
import Testing
@testable import DevicesFeature

private func makeDatabase() throws -> any DatabaseWriter {
    let database = try SQLiteData.defaultDatabase()
    var migrator = DatabaseMigrator()
    Device.registerMigrations(&migrator)
    Operation.registerMigrations(&migrator)  // ingest reconciles devices against open ops
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

    /// Requesting a travel preview opens the sheet (loading), then loads the
    /// dry-run plan from `CommandClient.previewTravel`.
    @Test func travelPreviewRequestLoadsPlan() async throws {
        let database = try makeDatabase()
        let plan = TravelPlan(
            finalDestination: "IZARUM-2-L4",
            totalTimeSeconds: 125.5,
            route: [TravelPlan.Leg(leg: 1, from: "A", to: "IZARUM-2-L4", type: "surge")]
        )

        let store = TestStore(initialState: DevicesFeature.State()) {
            DevicesFeature()
        } withDependencies: {
            $0.defaultDatabase = database
            $0.commandClient.previewTravel = { _, _ in .plan(plan) }
        }

        await store.send(.travelPreviewRequested(deviceCode: "A", destination: "IZARUM")) {
            $0.travelPreview = DevicesFeature.TravelPreview(deviceCode: "A", destination: "IZARUM")
        }
        await store.receive(\.travelPreviewResponse) {
            $0.travelPreview?.phase = .loaded(plan)
        }
    }

    /// Confirming the previewed itinerary clears the sheet and dispatches the
    /// real travel command for the previewed device/destination.
    @Test func travelPreviewConfirmedDispatches() async throws {
        let database = try makeDatabase()
        let dispatched = LockIsolated<(OperationKind, String, CommandParams)?>(nil)

        let store = withDependencies {
            $0.defaultDatabase = database
            $0.commandClient.dispatch = { kind, code, params in
                dispatched.setValue((kind, code, params))
                return .accepted(operationID: "op")
            }
        } operation: {
            var state = DevicesFeature.State()
            state.travelPreview = DevicesFeature.TravelPreview(
                deviceCode: "A", destination: "IZARUM", phase: .loaded(TravelPlan())
            )
            return TestStore(initialState: state) { DevicesFeature() }
        }
        store.exhaustivity = .off

        await store.send(.travelPreviewConfirmed) {
            $0.travelPreview = nil
        }
        await store.finish()

        #expect(dispatched.value?.0 == .travel)
        #expect(dispatched.value?.1 == "A")
        #expect(dispatched.value?.2.destination == "IZARUM")
    }
}
