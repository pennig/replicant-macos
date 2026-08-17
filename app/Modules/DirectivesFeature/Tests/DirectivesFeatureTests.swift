//
//  DirectivesFeatureTests.swift
//  Replicould — Directives feature
//
//  The list reducer: rows come from the two live queries, selection resolves to
//  a row, and the two built-in-only actions (reconfigure/clear) dispatch
//  against the selected controller and no-op when a custom row is selected.
//

import ComposableArchitecture
import DirectiveEngine
import Foundation
import GameDatabase
import GameModels
import GameServices
import SQLiteData
import Testing
import UniverseModels
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

    /// The same refusal on a row owned by its fleet tag alone. The permanent
    /// mine's belt controllers have no mission row to hold them, so without
    /// this one Clear silently breaks the mine.
    @Test func fleetTaggedRowRefusesReconfigureAndClear() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Device.insert {
                Self.controller(code: "AMI1", directive: "belt_search", tags: [MineRecipe.fleetTag.string])
            }.execute(db)
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

    /// The three verbs reach the resolution client for the selected mission.
    @Test func stallVerbsResolveTheSelectedRun() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Directive.insert { Self.stalledMission(id: "D1") }.execute(db)
        }
        let calls = LockIsolated<[String]>([])
        let store = TestStore(initialState: DirectivesFeature.State(selectedRowID: "custom:D1")) {
            DirectivesFeature()
        } withDependencies: {
            $0.defaultDatabase = database
            $0.directiveResolution.retry = { id in calls.withValue { $0.append("retry:\(id)") } }
            $0.directiveResolution.skipTarget = { id in calls.withValue { $0.append("skip:\(id)") } }
            $0.directiveResolution.cancel = { id in calls.withValue { $0.append("cancel:\(id)") } }
        }
        store.exhaustivity = .off

        await store.send(.retryTapped)
        await store.send(.skipTargetTapped)
        await store.send(.cancelRunTapped)
        #expect(calls.value == ["retry:D1", "skip:D1", "cancel:D1"])
    }

    /// The verbs are no-ops with a BUILT-IN row selected — it has no mission to
    /// resolve, and its `deviceCode` is a controller, not a directive id.
    @Test func stallVerbsAreNoOpsForABuiltInRow() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Device.insert { Self.controller(code: "AMI1", directive: "survey_system") }.execute(db)
        }
        let called = LockIsolated(false)
        let store = TestStore(initialState: DirectivesFeature.State(selectedRowID: "builtin:AMI1")) {
            DirectivesFeature()
        } withDependencies: {
            $0.defaultDatabase = database
            $0.directiveResolution.retry = { _ in called.setValue(true) }
            $0.directiveResolution.cancel = { _ in called.setValue(true) }
        }
        store.exhaustivity = .off

        await store.send(.retryTapped)
        await store.send(.cancelRunTapped)
        #expect(called.value == false)
    }

    /// Pause and resume reach the client too.
    @Test func pauseAndResumeReachTheClient() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Directive.insert { Self.stalledMission(id: "D1") }.execute(db)
        }
        let calls = LockIsolated<[String]>([])
        let store = TestStore(initialState: DirectivesFeature.State(selectedRowID: "custom:D1")) {
            DirectivesFeature()
        } withDependencies: {
            $0.defaultDatabase = database
            $0.directiveResolution.pause = { id in calls.withValue { $0.append("pause:\(id)") } }
            $0.directiveResolution.resume = { id in calls.withValue { $0.append("resume:\(id)") } }
        }
        store.exhaustivity = .off

        await store.send(.pauseTapped)
        await store.send(.resumeTapped)
        #expect(calls.value == ["pause:D1", "resume:D1"])
    }

    /// Selecting a mission loads its timeline — and only its own entries.
    @Test func selectingAMissionLoadsItsTimeline() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Directive.insert { Self.stalledMission(id: "D1") }.execute(db)
            try DirectiveLogEntry.insert { Self.logEntry("L1", directiveID: "D1", at: 10) }.execute(db)
            try DirectiveLogEntry.insert { Self.logEntry("L2", directiveID: "D9", at: 20) }.execute(db)
        }
        let store = TestStore(initialState: DirectivesFeature.State()) {
            DirectivesFeature()
        } withDependencies: { $0.defaultDatabase = database }
        store.exhaustivity = .off

        await store.send(.binding(.set(\.selectedRowID, "custom:D1")))
        #expect(store.state.timeline.entries.map(\.id) == ["L1"])
    }

    /// Selecting a built-in row loads that controller's completion history.
    @Test func selectingABuiltInRowLoadsItsHistory() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Device.insert { Self.controller(code: "AMI1", directive: "survey_system") }.execute(db)
            try DirectiveLogEntry.insert {
                Self.logEntry("L1", deviceCode: "AMI1", kind: .directiveCompleted, at: 10)
            }.execute(db)
        }
        let store = TestStore(initialState: DirectivesFeature.State()) {
            DirectivesFeature()
        } withDependencies: { $0.defaultDatabase = database }
        store.exhaustivity = .off

        await store.send(.binding(.set(\.selectedRowID, "builtin:AMI1")))
        #expect(store.state.timeline.entries.map(\.id) == ["L1"])
    }

    /// Deselecting clears the timeline rather than leaving the last run's
    /// entries under an empty pane.
    @Test func deselectingClearsTheTimeline() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Directive.insert { Self.stalledMission(id: "D1") }.execute(db)
            try DirectiveLogEntry.insert { Self.logEntry("L1", directiveID: "D1", at: 10) }.execute(db)
        }
        let store = TestStore(initialState: DirectivesFeature.State()) {
            DirectivesFeature()
        } withDependencies: { $0.defaultDatabase = database }
        store.exhaustivity = .off

        await store.send(.binding(.set(\.selectedRowID, "custom:D1")))
        #expect(store.state.timeline.entries.count == 1)
        await store.send(.binding(.set(\.selectedRowID, String?.none)))
        #expect(store.state.timeline.entries.isEmpty)
    }

    /// Launching a run selects it AND loads its timeline — the programmatic
    /// selection path must not skip the reload.
    @Test func launchingARunLoadsItsTimeline() async throws {
        let database = try GameDatabase.bootstrap()
        let launched = Self.stalledMission(id: "D2")
        try await database.write { db in
            try Directive.insert { launched }.execute(db)
            try DirectiveLogEntry.insert { Self.logEntry("L9", directiveID: "D2", at: 10) }.execute(db)
        }
        let store = TestStore(initialState: DirectivesFeature.State()) {
            DirectivesFeature()
        } withDependencies: { $0.defaultDatabase = database }
        store.exhaustivity = .off

        // Present the sheet first: a `.presented` action with absent
        // destination state is an application-logic error, not a path the app
        // can take.
        await store.send(.newDirectiveTapped)
        await store.send(.newDirective(.presented(.delegate(.created(launched)))))
        #expect(store.state.selectedRowID == "custom:D2")
        #expect(store.state.timeline.entries.map(\.id) == ["L9"])
    }

    /// The Salvage Run launcher is a SEPARATE presentation from the Survey Run
    /// one, with its own reducer — this pins that the handoff back (select +
    /// load timeline) works identically through it.
    @Test func launchingASalvageRunLoadsItsTimeline() async throws {
        let database = try GameDatabase.bootstrap()
        let launched = Self.stalledMission(id: "D3", kind: .salvageRun)
        try await database.write { db in
            try Directive.insert { launched }.execute(db)
            try DirectiveLogEntry.insert { Self.logEntry("L10", directiveID: "D3", at: 10) }.execute(db)
        }
        let store = TestStore(initialState: DirectivesFeature.State()) {
            DirectivesFeature()
        } withDependencies: { $0.defaultDatabase = database }
        store.exhaustivity = .off

        await store.send(.newSalvageRunTapped)
        await store.send(.newSalvageRun(.presented(.delegate(.created(launched)))))
        #expect(store.state.selectedRowID == "custom:D3")
        #expect(store.state.timeline.entries.map(\.id) == ["L10"])
    }

    nonisolated static func logEntry(
        _ id: String,
        directiveID: String? = nil,
        deviceCode: String? = nil,
        kind: DirectiveLogKind = .stepStarted,
        at seconds: TimeInterval
    ) -> DirectiveLogEntry {
        DirectiveLogEntry(
            id: id, directiveID: directiveID, deviceCode: deviceCode, kind: kind,
            summary: "entry \(id)", step: nil, operationID: nil, eventID: nil,
            occurredAt: Date(timeIntervalSince1970: seconds)
        )
    }

    /// A stalled mission fixture, for the resolution verbs.
    nonisolated static func stalledMission(id: String, kind: DirectiveKind = .surveyRun) -> Directive {
        Directive(
            id: id, kind: kind, status: .needsAttention, deviceCode: "VESSEL1",
            controllerCode: "AMI1", targets: ["TAU"], targetIndex: 0, step: "configuring",
            stepStartedAt: Date(timeIntervalSince1970: 100), returnToOrigin: false,
            originDesignation: "SOL", attentionReason: .commandRejected,
            createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0)
        )
    }

    /// An AMI controller fixture carrying an in-force directive. Real
    /// controllers always advertise `available_directives` at runtime (see
    /// `Device.availableDirectives`'s doc comment — the fallback vocabulary
    /// is for worker devices only), so the fixture mirrors that: the passed
    /// directive is always included, alongside a second option so the shape
    /// matches a real survey controller's `["survey_system", "belt_search"]`
    /// pairing (see `GameServices/Tests/DeviceDirectiveTests.swift`).
    nonisolated static func controller(
        code: String, directive: String, tags: [String] = []
    ) -> Device {
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
            tags: tags,
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

@Suite("Directives — Print Mine Fleet")
@MainActor
struct PrintMineFleetTests {
    @Test func tappingPresentsTheConfirmDialog() async throws {
        let database = try GameDatabase.bootstrap()
        let store = TestStore(initialState: DirectivesFeature.State()) {
            DirectivesFeature()
        } withDependencies: {
            $0.defaultDatabase = database
        }
        store.exhaustivity = .off

        await store.send(.printMineFleetTapped)
        #expect(store.state.printMineFleetDialog?.title == TextState("Print a mine fleet?"))
        #expect(store.state.printMineFleetDialog?.message == TextState(
            "Eleven devices, 3,455 units from hub stock, plus a surge carrier if none is idle. The brain sites and delivers it when complete."
        ))
    }

    /// Confirming inserts exactly one row at the lowest-designated operational
    /// theatre, on that depot's own lowest-coded hub — `AAA-B` is the lowest-coded
    /// printer in the account and stands at the OTHER depot, so an account-wide
    /// `min` picks it and is wrong.
    @Test func confirmingInsertsOnTheDepotsOwnHost() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in try Self.seedTwoTheatres(db) }
        let store = Self.launchStore(database)

        await store.send(.printMineFleetTapped)
        await store.send(.printMineFleetDialog(.presented(.confirm)))
        await store.receive(\.printMineFleetLaunched)

        let created = try await database.read { db in try Directive.all.fetchAll(db) }
        #expect(created.count == 1)
        #expect(created[0].kind == .mineFleetPrint)
        #expect(created[0].status == .running)
        #expect(created[0].deviceCode == "HUB-A")
        #expect(created[0].theatreDepot == "AINALRAM-BELT-1")
        #expect(created[0].fleetTag == MineRecipe.fleetTag.string)
        #expect(created[0].step == MineFleetPrint().firstStep)
        #expect(created[0].targets.isEmpty)
        #expect(created[0].returnToOrigin == false)
    }

    /// The launch pin must be a hub that can take a job now. `HUB-A` sorts first
    /// and is compacted for carriage, so pinning it would hand the run a printer
    /// the server refuses before it ever prints anything.
    @Test func confirmingSkipsAHubThatCannotPrint() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Self.seedTwoTheatres(db)
            try Device.update { $0.status = "compacted" }.where { $0.deviceCode.eq("HUB-A") }.execute(db)
        }
        let store = Self.launchStore(database)

        await store.send(.printMineFleetTapped)
        await store.send(.printMineFleetDialog(.presented(.confirm)))
        await store.receive(\.printMineFleetLaunched)

        let created = try await database.read { db in try Directive.all.fetchAll(db) }
        #expect(created.count == 1)
        #expect(created[0].deviceCode == "HUB-Z")
        #expect(created[0].theatreDepot == "AINALRAM-BELT-1")
    }

    /// A carrier hull advertises `enqueue_print`, and hosting the print on one
    /// would reserve the vessel the fleet is waiting on out of the fleet.
    @Test func confirmingNeverHostsOnACarrierHull() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Self.seedTwoTheatres(db)
            try Device.insert {
                Self.theatreDevice(
                    "AAA-HULL", type: "heaven_vessel", location: "AINALRAM-BELT-1",
                    commands: ["enqueue_print"], features: ["cradle", "surge"]
                )
            }.execute(db)
        }
        let store = Self.launchStore(database)

        await store.send(.printMineFleetTapped)
        await store.send(.printMineFleetDialog(.presented(.confirm)))
        await store.receive(\.printMineFleetLaunched)

        let created = try await database.read { db in try Directive.all.fetchAll(db) }
        #expect(created[0].deviceCode == "HUB-A")
    }

    /// No operational theatre means no bench to print at, so the launch declines
    /// rather than pinning whatever print hub happens to sort first.
    @Test func confirmingWithNoTheatreLaunchesNothing() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Device.insert { Self.printHub(code: "HUB1") }.execute(db)
        }
        let store = Self.launchStore(database)

        await store.send(.printMineFleetTapped)
        await store.send(.printMineFleetDialog(.presented(.confirm)))
        await store.receive(\.printMineFleetHostMissing)

        let created = try await database.read { db in try Directive.all.fetchAll(db) }
        #expect(created.isEmpty)
    }

    /// A live `mineFleetPrint` row blocks a second launch: the tap presents an
    /// already-running dialog instead of the confirm one, and its single
    /// button inserts nothing.
    @Test func aLiveRowBlocksLaunchAndInsertsNothing() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Device.insert { Self.printHub(code: "HUB1") }.execute(db)
            try Directive.insert { Self.mineFleetPrintDirective(id: "D1", status: .running) }.execute(db)
        }
        let store = TestStore(initialState: DirectivesFeature.State()) {
            DirectivesFeature()
        } withDependencies: {
            $0.defaultDatabase = database
        }
        store.exhaustivity = .off

        await store.send(.printMineFleetTapped)
        #expect(store.state.printMineFleetDialog?.title != TextState("Print a mine fleet?"))
        await store.send(.printMineFleetDialog(.dismiss))

        let created = try await database.read { db in try Directive.all.fetchAll(db) }
        #expect(created.count == 1)
    }

    /// No eligible print host at all: confirming presents an error dialog and
    /// still inserts nothing.
    @Test func noPrintHostPresentsAnErrorDialogAndInsertsNothing() async throws {
        let database = try GameDatabase.bootstrap()
        let store = TestStore(initialState: DirectivesFeature.State()) {
            DirectivesFeature()
        } withDependencies: {
            $0.defaultDatabase = database
            $0.uuid = .incrementing
            $0.date = .constant(Date(timeIntervalSince1970: 500))
        }
        store.exhaustivity = .off

        await store.send(.printMineFleetTapped)
        await store.send(.printMineFleetDialog(.presented(.confirm)))
        await store.receive(\.printMineFleetHostMissing)

        #expect(store.state.printMineFleetDialog?.title == TextState("No autofactory found at the hub."))
        let created = try await database.read { db in try Directive.all.fetchAll(db) }
        #expect(created.isEmpty)
    }

    /// A print-capable device, eligible unless overridden to a vessel type.
    nonisolated static func theatreDevice(
        _ code: String, type: String, location: String?, commands: [String] = [],
        features: [String] = [], status: String = "idle"
    ) -> Device {
        Device(
            deviceCode: code, deviceType: type, replicantCode: "R1", status: status,
            location: location, locationName: nil, operationalCapacity: 100, queueSize: 0,
            stowedInDeviceCode: nil, controllerDeviceCode: nil, attachedToDeviceCode: nil,
            createdAt: Date(timeIntervalSince1970: 0), availableCommands: commands,
            features: features, tags: [], detail: .object([:]),
            updatedAt: Date(timeIntervalSince1970: 0), firstSeenAt: Date(timeIntervalSince1970: 0)
        )
    }

    /// Two operational theatres in separate mesh components. `AAA-B` is the
    /// lowest-coded printer in the account and stands at the higher-designated
    /// depot, so an account-wide `min` picks the wrong bench.
    nonisolated static func seedTwoTheatres(_ db: Database) throws {
        let epoch = Date(timeIntervalSince1970: 0)
        for (designation, coordinate) in [("AINALRAM", 0.0), ("DENEBED", 2_000.0)] {
            try Star.insert {
                Star(
                    designation: designation, spectralType: "G", color: "yellow",
                    positionX: coordinate, positionY: coordinate, positionZ: coordinate,
                    estimatedPlanets: 0, explored: true, hasLife: nil, entryPoint: nil,
                    createdAt: epoch
                )
            }.execute(db)
        }
        for (code, system) in [("REL-A", "AINALRAM"), ("REL-B", "DENEBED")] {
            try Device.insert {
                theatreDevice(code, type: "ftl_relay", location: system,
                              features: ["relay"], status: "relaying")
            }.execute(db)
        }
        for (code, depot) in [
            ("HUB-A", "AINALRAM-BELT-1"), ("HUB-Z", "AINALRAM-BELT-1"), ("AAA-B", "DENEBED-BELT-1"),
        ] {
            try Device.insert {
                theatreDevice(code, type: "autofactory", location: depot, commands: ["enqueue_print"])
            }.execute(db)
        }
        for (depot, resources) in [("AINALRAM-BELT-1", 100_000), ("DENEBED-BELT-1", 90_000)] {
            try LocationFootprint.insert {
                LocationFootprint(
                    location: depot, devices: 1, resources: resources, resourceSites: 0,
                    locationEvents: 0, replicants: 0, fetchedAt: epoch
                )
            }.execute(db)
        }
    }

    static func launchStore(_ database: any DatabaseWriter) -> TestStoreOf<DirectivesFeature> {
        let store = TestStore(initialState: DirectivesFeature.State()) {
            DirectivesFeature()
        } withDependencies: {
            $0.defaultDatabase = database
            $0.uuid = .incrementing
            $0.date = .constant(Date(timeIntervalSince1970: 500))
        }
        store.exhaustivity = .off
        return store
    }

    nonisolated static func printHub(
        code: String, deviceType: String = "system_hub", location: String = "SOL-1"
    ) -> Device {
        Device(
            deviceCode: code, deviceType: deviceType, replicantCode: "R1", status: "idle",
            location: location, locationName: nil, operationalCapacity: 100, queueSize: 0,
            stowedInDeviceCode: nil, controllerDeviceCode: nil, attachedToDeviceCode: nil,
            createdAt: Date(timeIntervalSince1970: 0), availableCommands: ["enqueue_print"],
            features: [], tags: [], detail: .object([:]),
            updatedAt: Date(timeIntervalSince1970: 0), firstSeenAt: Date(timeIntervalSince1970: 0)
        )
    }

    nonisolated static func mineFleetPrintDirective(id: String, status: DirectiveStatus) -> Directive {
        Directive(
            id: id, kind: .mineFleetPrint, status: status, deviceCode: "HUB1",
            fleetTag: MineRecipe.fleetTag.string, targets: [], targetIndex: 0,
            step: MineFleetPrint().firstStep, stepStartedAt: Date(timeIntervalSince1970: 0),
            returnToOrigin: false, originDesignation: nil, attentionReason: nil,
            createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0)
        )
    }
}
