//
//  SidebarFeatureTests.swift
//  Replicould — Sidebar feature
//
//  The reducer's jobs: bridge a category change into a `categoryChanged`
//  delegate (so the container resets its detail selection), bubble logout, and
//  persist an edited plan through `replicantsClient`.
//

import ComposableArchitecture
import Foundation
import GameModels
import GameServices
import SQLiteData
import Testing
@testable import SidebarFeature

/// Disambiguate from `Foundation.Operation`.
private typealias Operation = GameModels.Operation

private func makeDatabase() throws -> any DatabaseWriter {
    let database = try SQLiteData.defaultDatabase()
    var migrator = DatabaseMigrator()
    Replicant.registerMigrations(&migrator)
    try migrator.migrate(database)
    return database
}

private func device(_ code: String, replicant: String = "R1", status: String = "travelling") -> Device {
    Device(
        deviceCode: code, deviceType: "probe", replicantCode: replicant, status: status,
        location: "IZARUM-2", locationName: "Izarum II", operationalCapacity: 100, queueSize: 0,
        stowedInDeviceCode: nil, controllerDeviceCode: nil, attachedToDeviceCode: nil,
        createdAt: Date(timeIntervalSince1970: 0), availableCommands: [], features: [], tags: [],
        detail: .object([:]), updatedAt: Date(timeIntervalSince1970: 1_000),
        firstSeenAt: Date(timeIntervalSince1970: 1_000)
    )
}

private func replicant(_ code: String, host: String) -> Replicant {
    Replicant(replicantCode: code, name: "Bob", createdAt: Date(timeIntervalSince1970: 0), hostedDeviceCode: host)
}

private func travelOp(_ id: String, device: String, status: OperationStatus, completesAt: Date?) -> Operation {
    Operation(
        id: id, entityCode: device, kind: OperationKind.travel.rawValue,
        status: status, source: OperationSource.poll,
        startedAt: Date(timeIntervalSince1970: 0), completesAt: completesAt,
        lastConfirmedAt: Date(timeIntervalSince1970: 0), detail: .object([:])
    )
}

@MainActor
@Suite struct SidebarFeatureTests {

    /// Selecting a category emits `categoryChanged` so the container can reset its
    /// detail selection.
    @Test func categoryChangeEmitsDelegate() async throws {
        let database = try makeDatabase()
        let store = withDependencies {
            $0.defaultDatabase = database
        } operation: {
            TestStore(initialState: SidebarFeature.State(apiKey: "k")) { SidebarFeature() }
        }

        await store.send(.binding(.set(\.category, .messages))) {
            $0.category = .messages
        }
        await store.receive(\.delegate.categoryChanged)
    }

    /// The Account sheet's Log Out bubbles up as a `loggedOut` delegate.
    @Test func logoutEmitsDelegate() async throws {
        let database = try makeDatabase()
        let store = withDependencies {
            $0.defaultDatabase = database
        } operation: {
            TestStore(initialState: SidebarFeature.State(apiKey: "k")) { SidebarFeature() }
        }

        await store.send(.logoutButtonTapped)
        await store.receive(\.delegate.loggedOut)
    }

    /// Saving a plan forwards to `replicantsClient.updatePlan`.
    @Test func savePlanCallsClient() async throws {
        let database = try makeDatabase()
        let captured = LockIsolated<(String, String)?>(nil)

        let store = withDependencies {
            $0.defaultDatabase = database
            $0.replicantsClient.updatePlan = { code, plan in captured.setValue((code, plan)) }
        } operation: {
            TestStore(initialState: SidebarFeature.State(apiKey: "k")) { SidebarFeature() }
        }
        store.exhaustivity = .off

        await store.send(.savePlan(code: "R1", plan: "Explore the rim"))
        await store.finish()

        #expect(captured.value?.0 == "R1")
        #expect(captured.value?.1 == "Explore the rim")
    }

    // MARK: - Operation-driven progress (atomic completion)

    /// An active, deadline-bearing travel op on the host device yields a row.
    @Test func activeTravelOpYieldsRow() {
        let row = SidebarProgress.active(
            replicant: replicant("R1", host: "HOST"),
            devices: [device("HOST")],
            operations: [travelOp("op1", device: "HOST", status: .active, completesAt: Date(timeIntervalSince1970: 5_000))]
        )
        #expect(row?.symbol == "arrow.right")
    }

    /// The instant the op flips to `.completed`, the row clears — no dependence on
    /// the device's live activity block re-fetching as settled.
    @Test func completedOpClearsRowAtomically() {
        let row = SidebarProgress.active(
            replicant: replicant("R1", host: "HOST"),
            devices: [device("HOST")],
            operations: [travelOp("op1", device: "HOST", status: .completed, completesAt: Date(timeIntervalSince1970: 5_000))]
        )
        #expect(row == nil)
    }
}
