//
//  DirectivesFeatureTests.swift
//  Replicould — Directives feature
//
//  The list reducer: rows come from the two live queries, selection resolves to
//  a row, and the two built-in-only actions (reconfigure/clear) dispatch
//  against the selected controller and no-op when a custom row is selected.
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

    /// Clearing dispatches clear_directive for the selected controller. No
    /// explicit refresh follows — the accepted op surfaces via table
    /// observation (see `DirectivesFeature.dispatch`'s doc comment).
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
        }
        store.exhaustivity = .off

        await store.send(.clearConfirmed(deviceCode: "AMI1"))
        await store.receive(\.commandFinished)
        #expect(store.state.errorMessage == "No directive in force.")
    }

    /// Reconfigure opens the shared composer seeded from the selected device.
    @Test func reconfigurePresentsTheComposer() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Device.insert { Self.controller(code: "AMI1", directive: "survey_system") }.execute(db)
        }
        let store = TestStore(initialState: DirectivesFeature.State(selectedRowID: "builtin:AMI1")) {
            DirectivesFeature()
        } withDependencies: {
            $0.defaultDatabase = database
        }
        store.exhaustivity = .off

        await store.send(.reconfigureTapped)
        #expect(store.state.composer?.deviceCode == "AMI1")
        #expect(store.state.composer?.directive == "survey_system")
    }

    /// Reconfigure is a no-op with a custom row selected — its `deviceCode` is
    /// the mission's vessel, not a directive-capable controller, so opening
    /// the AMI composer from it would be nonsensical.
    @Test func reconfigureIsANoOpForACustomRow() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Directive.insert { Self.mission(id: "D1") }.execute(db)
        }
        let store = TestStore(initialState: DirectivesFeature.State(selectedRowID: "custom:D1")) {
            DirectivesFeature()
        } withDependencies: {
            $0.defaultDatabase = database
        }
        store.exhaustivity = .off

        await store.send(.reconfigureTapped)
        #expect(store.state.composer == nil)
    }

    /// Clear is a no-op with a custom row selected — dispatching
    /// `clear_directive` at a mission's vessel would send an AMI command to a
    /// device that was never a directive controller.
    @Test func clearIsANoOpForACustomRow() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Directive.insert { Self.mission(id: "D1") }.execute(db)
        }
        let dispatched = LockIsolated<Bool>(false)
        let store = TestStore(initialState: DirectivesFeature.State(selectedRowID: "custom:D1")) {
            DirectivesFeature()
        } withDependencies: {
            $0.defaultDatabase = database
            $0.commandClient.dispatch = { _, _, _ in
                dispatched.setValue(true)
                return .accepted(operationID: nil)
            }
        }
        store.exhaustivity = .off

        await store.send(.clearTapped)
        #expect(dispatched.value == false)
    }

    /// Reconfigure and Clear are refused on a row the engine owns. The guard
    /// lives in the reducer, not only in the view's `.disabled`, so a stale
    /// click or a future keyboard path can't clear a directive a mission step
    /// is waiting on.
    @Test func engineOwnedRowRefusesReconfigureAndClear() async throws {
        let database = try GameDatabase.bootstrap()
        let driving: Directive = {
            var mission = Self.mission(id: "D1")
            mission.controllerCode = "AMI1"
            return mission
        }()
        try await database.write { db in
            try Device.insert { Self.controller(code: "AMI1", directive: "survey_system") }.execute(db)
            try Directive.insert { driving }.execute(db)
        }
        let dispatched = LockIsolated(false)
        let store = TestStore(initialState: DirectivesFeature.State(selectedRowID: "builtin:AMI1")) {
            DirectivesFeature()
        } withDependencies: {
            $0.defaultDatabase = database
            $0.commandClient.dispatch = { _, _, _ in
                dispatched.setValue(true)
                return .accepted(operationID: nil)
            }
        }
        store.exhaustivity = .off

        await store.send(.reconfigureTapped)
        #expect(store.state.composer == nil)
        await store.send(.clearTapped)
        #expect(dispatched.value == false)
    }

    /// The composer's confirmation dispatches `set_directive` at the controller
    /// the composer was opened on, carrying the chosen directive and its config.
    /// This is the feature's headline write — the one path whose regression
    /// would silently stop directives being set at all.
    @Test func composerConfirmationDispatchesSetDirective() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Device.insert { Self.controller(code: "AMI1", directive: "patrol") }.execute(db)
        }
        let dispatched = LockIsolated<(OperationKind, String, CommandParams)?>(nil)
        let store = TestStore(initialState: DirectivesFeature.State(selectedRowID: "builtin:AMI1")) {
            DirectivesFeature()
        } withDependencies: {
            $0.defaultDatabase = database
            $0.commandClient.dispatch = { kind, code, params in
                dispatched.setValue((kind, code, params))
                return .accepted(operationID: nil)
            }
        }
        store.exhaustivity = .off

        await store.send(.reconfigureTapped)
        await store.send(
            .composer(.presented(.delegate(.confirmed(
                directive: "survey_system",
                configuration: ["planets": .string("all")]
            ))))
        )
        await store.receive(\.commandFinished)

        let call = try #require(dispatched.value)
        #expect(call.0 == .setDirective)
        #expect(call.1 == "AMI1")
        #expect(call.2.directive == "survey_system")
        #expect(call.2.configuration?["planets"]?.stringValue == "all")
    }

    /// An AMI controller fixture carrying an in-force directive. Real
    /// controllers always advertise `available_directives` at runtime (see
    /// `Device.availableDirectives`'s doc comment — the fallback vocabulary
    /// is for worker devices only), so the fixture mirrors that: the passed
    /// directive is always included, alongside a second option so the shape
    /// matches a real survey controller's `["survey_system", "belt_search"]`
    /// pairing (see `GameServices/Tests/DeviceDirectiveTests.swift`).
    nonisolated static func controller(code: String, directive: String) -> Device {
        let availableDirectives = [directive] + (["survey_system", "belt_search"].filter { $0 != directive })
        return Device(
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
            detail: .object([
                "ami_directive": .object(["name": .string(directive)]),
                "available_directives": .array(availableDirectives.map(JSONValue.string)),
            ]),
            updatedAt: Date(timeIntervalSince1970: 0),
            firstSeenAt: Date(timeIntervalSince1970: 0)
        )
    }

    /// A minimal custom mission fixture, for tests asserting the built-in-only
    /// actions no-op when a custom row is selected.
    nonisolated static func mission(id: String) -> Directive {
        Directive(
            id: id, kind: .surveyRun, status: .running, deviceCode: "VESSEL1",
            targets: ["TAU"], targetIndex: 0, step: "surveying",
            stepStartedAt: Date(timeIntervalSince1970: 0),
            returnToOrigin: false, originDesignation: "SOL", attentionReason: nil,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0)
        )
    }
}
