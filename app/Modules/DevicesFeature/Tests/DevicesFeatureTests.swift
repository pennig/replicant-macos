//
//  DevicesFeatureTests.swift
//  Replicould — Devices feature
//
//  The reducer's two jobs: cold-load the fleet on first run (reconciling each
//  device into SQLite) and forward a confirmed command to `CommandClient`.
//

import ComposableArchitecture
import Foundation
import GameDatabase
import GameModels
import GameServices
import SQLiteData
import Testing
import Utils
@testable import DevicesFeature

private func device(_ code: String, status: String = "idle") -> Device {
    Device(
        deviceCode: code, deviceType: "mining_drone", replicantCode: "R1", status: status,
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
        let database = try GameDatabase.bootstrap()
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

    /// A non-empty fleet does not cold-load on `.task` (the event stream keeps it warm).
    @Test func nonEmptyFleetSkipsColdLoad() async throws {
        let database = try GameDatabase.bootstrap()
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

    /// The while-viewing refresh loop stops the moment the view reports the
    /// device is out of sight (`viewingChanged(nil)`) — the teardown signal
    /// `onDisappear`/scenePhase now send. Regression for V3.4-B1: without the
    /// cancel, a never-settling (diverting/mining) device kept polling forever
    /// after the pane was closed.
    @Test func viewingChangedNilStopsTheRefreshLoop() async throws {
        let database = try GameDatabase.bootstrap()
        let clock = TestClock()
        let refreshes = LockIsolated(0)

        let store = TestStore(initialState: DevicesFeature.State()) {
            DevicesFeature()
        } withDependencies: {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 2_000))
            $0.continuousClock = clock
            // Still diverting (never settles) with no location, so each tick is
            // exactly one refresh and the loop re-arms indefinitely.
            $0.deviceRefresher = DeviceRefreshClient { code, _ in
                refreshes.withValue { $0 += 1 }
                return device(code, status: "diverting")
            }
        }
        store.exhaustivity = .off

        await store.send(.viewingChanged(deviceCode: "A"))
        while refreshes.value < 1 { await Task.yield() }   // first tick is in

        await store.send(.viewingChanged(deviceCode: nil)) // view went away
        await clock.run()                                  // any surviving sleep would fire here
        await store.finish()

        #expect(refreshes.value == 1, "no further reads once the view is gone")
    }

    /// A confirmed command is forwarded to `CommandClient.dispatch`.
    @Test func commandConfirmedDispatches() async throws {
        let database = try GameDatabase.bootstrap()
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
    /// The "Review Route…" intent ends field editing (via the `endEditing`
    /// dependency) and defers over the clock before it requests the dry-run — the
    /// side effects the view used to perform inline are now controllable here.
    @Test func travelConfirmedEndsEditingThenRequestsPreview() async throws {
        let database = try GameDatabase.bootstrap()
        let endedEditing = LockIsolated(false)
        let plan = TravelPlan(finalDestination: "IZARUM-2-L4")

        let store = TestStore(initialState: DevicesFeature.State()) {
            DevicesFeature()
        } withDependencies: {
            $0.defaultDatabase = database
            $0.continuousClock = ImmediateClock()
            $0.endEditing = EndEditingClient { endedEditing.setValue(true) }
            $0.commandClient.previewTravel = { _, _ in .plan(plan) }
        }

        await store.send(.travelConfirmed(deviceCode: "A", destination: "IZARUM"))
        await store.receive(\.travelPreviewRequested) {
            $0.travelPreview = TravelPreview(deviceCode: "A", destination: "IZARUM")
        }
        await store.receive(\.travelPreviewResponse) {
            $0.travelPreview?.phase = .loaded(plan)
        }
        #expect(endedEditing.value == true)
    }

    @Test func travelPreviewRequestLoadsPlan() async throws {
        let database = try GameDatabase.bootstrap()
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
            $0.travelPreview = TravelPreview(deviceCode: "A", destination: "IZARUM")
        }
        await store.receive(\.travelPreviewResponse) {
            $0.travelPreview?.phase = .loaded(plan)
        }
    }

    /// Confirming the previewed itinerary clears the sheet and dispatches the
    /// real travel command for the previewed device/destination.
    @Test func travelPreviewConfirmedDispatches() async throws {
        let database = try GameDatabase.bootstrap()
        let dispatched = LockIsolated<(OperationKind, String, CommandParams)?>(nil)

        let store = withDependencies {
            $0.defaultDatabase = database
            $0.commandClient.dispatch = { kind, code, params in
                dispatched.setValue((kind, code, params))
                return .accepted(operationID: "op")
            }
        } operation: {
            var state = DevicesFeature.State()
            state.travelPreview = TravelPreview(
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

    /// The Directive command ends field editing, yields, then presents the
    /// composer seeded from the inspected device.
    @Test func directiveComposeTappedPresentsComposerForSelectedDevice() async throws {
        let database = try GameDatabase.bootstrap()
        var ami = device("AMI1")
        ami.detail = .object([
            "available_directives": .array([.string("survey_system"), .string("belt_search")]),
        ])
        let seeded = ami
        try await database.write { db in try Device.insert { seeded }.execute(db) }
        let endedEditing = LockIsolated(false)

        let store = TestStore(initialState: DevicesFeature.State(selectedDeviceCode: "AMI1")) {
            DevicesFeature()
        } withDependencies: {
            $0.defaultDatabase = database
            $0.continuousClock = ImmediateClock()
            $0.endEditing = EndEditingClient { endedEditing.setValue(true) }
        }
        store.exhaustivity = .off

        await store.send(.directiveComposeTapped)
        await store.receive(\.directiveComposerPresented)
        #expect(endedEditing.value == true)
        #expect(store.state.directiveComposer?.deviceCode == "AMI1")
        #expect(store.state.directiveComposer?.directive == "survey_system")
    }

    /// The composer's confirmed delegate dispatches `set_directive` with the
    /// built configuration for the presented device.
    @Test func directiveComposerConfirmedDispatchesSetDirective() async throws {
        let database = try GameDatabase.bootstrap()
        let dispatched = LockIsolated<(OperationKind, String, CommandParams)?>(nil)

        let store = withDependencies {
            $0.defaultDatabase = database
            $0.commandClient.dispatch = { kind, code, params in
                dispatched.setValue((kind, code, params))
                return .accepted(operationID: "op")
            }
        } operation: {
            var state = DevicesFeature.State(selectedDeviceCode: "AMI1")
            var ami = device("AMI1")
            ami.detail = .object([
                "available_directives": .array([.string("survey_system")]),
            ])
            state.directiveComposer = DirectiveComposer.State(device: ami, fleet: [])
            return TestStore(initialState: state) { DevicesFeature() }
        }
        store.exhaustivity = .off

        await store.send(.directiveComposer(.presented(.delegate(.confirmed(
            directive: "survey_system",
            configuration: ["planets": .string("all"), "moons": .string("none"), "recall": .bool(true)]
        )))))
        await store.finish()

        #expect(dispatched.value?.0 == .setDirective)
        #expect(dispatched.value?.1 == "AMI1")
        #expect(dispatched.value?.2.directive == "survey_system")
        #expect(dispatched.value?.2.configuration?["planets"] == .string("all"))
    }
}
