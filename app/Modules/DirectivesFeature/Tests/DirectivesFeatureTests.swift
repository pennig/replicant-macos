//
//  DirectivesFeatureTests.swift
//  Replicould — Directives feature
//
//  The list reducer: rows come from the two live queries, selection resolves to
//  a row, and clearing a built-in directive dispatches clear_directive and
//  confirms through the device refresher.
//

import ComposableArchitecture
import Foundation
import GameDatabase
import GameModels
import GameServices
import SQLiteData
import Testing
import Utils
@testable import DirectivesFeature

@Suite("Directives feature")
@MainActor
struct DirectivesFeatureTests {
    /// A device with an in-force directive shows up as a built-in row, with no
    /// row ever written to the Directive table.
    @Test func builtInRowsComeFromTheFleet() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Device.insert { Self.controller(code: "AMI1", directive: "survey_system") }.execute(db)
        }
        let store = TestStore(initialState: DirectivesFeature.State()) {
            DirectivesFeature()
        } withDependencies: {
            $0.defaultDatabase = database
        }
        store.exhaustivity = .off

        #expect(store.state.rows.map(\.id) == ["builtin:AMI1"])
        let persisted = try await database.read { db in try Directive.all.fetchAll(db) }
        #expect(persisted.isEmpty)
    }

    /// Selecting a row resolves it; an unknown id resolves to nil rather than
    /// crashing the detail pane.
    @Test func selectionResolvesToARow() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Device.insert { Self.controller(code: "AMI1", directive: "patrol") }.execute(db)
        }
        let store = TestStore(initialState: DirectivesFeature.State(selectedRowID: "builtin:AMI1")) {
            DirectivesFeature()
        } withDependencies: {
            $0.defaultDatabase = database
        }
        store.exhaustivity = .off

        #expect(store.state.selectedRow?.deviceCode == "AMI1")

        await store.send(.binding(.set(\.selectedRowID, "builtin:NOPE")))
        #expect(store.state.selectedRow == nil)
    }

    /// Clearing dispatches clear_directive for the selected controller and
    /// confirms the result through the shared device refresher.
    @Test func clearDispatchesClearDirective() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Device.insert { Self.controller(code: "AMI1", directive: "survey_system") }.execute(db)
        }
        let dispatched = LockIsolated<(OperationKind, String)?>(nil)
        let store = TestStore(initialState: DirectivesFeature.State(selectedRowID: "builtin:AMI1")) {
            DirectivesFeature()
        } withDependencies: {
            $0.defaultDatabase = database
            $0.commandClient.dispatch = { kind, code, _ in
                dispatched.setValue((kind, code))
                return .accepted(operationID: nil)
            }
            $0.deviceRefresher.refresh = { _, _ in nil }
        }
        store.exhaustivity = .off

        await store.send(.clearConfirmed(deviceCode: "AMI1"))
        await store.receive(\.commandFinished)
        #expect(dispatched.value?.0 == .clearDirective)
        #expect(dispatched.value?.1 == "AMI1")
    }

    /// A rejected clear surfaces its message instead of failing silently.
    @Test func rejectedClearSurfacesTheMessage() async throws {
        let database = try GameDatabase.bootstrap()
        let store = TestStore(initialState: DirectivesFeature.State()) {
            DirectivesFeature()
        } withDependencies: {
            $0.defaultDatabase = database
            $0.commandClient.dispatch = { _, _, _ in .rejected("No directive in force.") }
            $0.deviceRefresher.refresh = { _, _ in nil }
        }
        store.exhaustivity = .off

        await store.send(.clearConfirmed(deviceCode: "AMI1"))
        await store.receive(\.commandFinished)
        #expect(store.state.errorMessage == "No directive in force.")
    }

    /// An AMI controller fixture carrying an in-force directive.
    nonisolated static func controller(code: String, directive: String) -> Device {
        Device(
            deviceCode: code,
            deviceType: "ami_survey_controller",
            replicantCode: "R1",
            status: "idle",
            location: "ATIANFU-3",
            locationName: nil,
            operationalCapacity: 100,
            queueSize: 0,
            stowedInDeviceCode: nil,
            controllerDeviceCode: nil,
            attachedToDeviceCode: nil,
            createdAt: Date(timeIntervalSince1970: 0),
            availableCommands: ["set_directive", "clear_directive"],
            features: [],
            tags: [],
            detail: .object(["ami_directive": .object(["name": .string(directive)])]),
            updatedAt: Date(timeIntervalSince1970: 0),
            firstSeenAt: Date(timeIntervalSince1970: 0)
        )
    }
}
