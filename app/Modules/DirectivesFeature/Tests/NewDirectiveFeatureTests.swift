//
//  NewDirectiveFeatureTests.swift
//  Replicould — Directives feature
//
//  The launcher: it offers only vessels the engine could actually run on, and
//  the row it writes is exactly what `SurveyRun` expects to find at preflight.
//

import ComposableArchitecture
import DirectiveEngine
import Foundation
import GameDatabase
import GameModels
import SQLiteData
import Testing
import UniverseModels
import Utils
@testable import DirectivesFeature

@Suite("New directive")
@MainActor
struct NewDirectiveFeatureTests {
    /// Only properly staged vessels are offered — one with no controller aboard
    /// would stall on its first evaluation, so offering it would manufacture a
    /// stall the user then has to clear.
    @Test func onlyStagedVesselsAreEligible() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            for device in Self.stagedFleet() { try Device.insert { device }.execute(db) }
            try Device.insert { Self.bareVessel("VES2") }.execute(db)
        }
        let store = TestStore(initialState: NewDirectiveFeature.State()) {
            NewDirectiveFeature()
        } withDependencies: { $0.defaultDatabase = database }
        store.exhaustivity = .off

        #expect(store.state.eligibleVessels.map(\.deviceCode) == ["VES1"])
    }

    /// The launcher must offer a vessel whose staging is legible only from the
    /// drone side. `GET devices` omits `controlled_devices`, so for any
    /// controller nobody has opened the inspector on, the adoption link lives
    /// exclusively in the drone's `controller_device_code` column — the normal
    /// case, and the one that used to hide every staged vessel.
    @Test func aVesselStagedButSyncedFromTheListIsEligible() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            for device in Self.listSyncedFleet() { try Device.insert { device }.execute(db) }
        }
        let store = TestStore(initialState: NewDirectiveFeature.State()) {
            NewDirectiveFeature()
        } withDependencies: { $0.defaultDatabase = database }
        store.exhaustivity = .off

        #expect(store.state.eligibleVessels.map(\.deviceCode) == ["VES1"])
    }

    /// The real fleet topology this bug was found on (2026-07-26): two vessels
    /// and two survey controllers, only one of them staged. The staged vessel
    /// carries its controller and six drones stowed, with adoption recorded
    /// ONLY on the drones — and the second controller is deployed elsewhere, so
    /// it must not be mistaken for the idle vessel's. Exactly one vessel is
    /// offered.
    @Test func offersOnlyTheStagedVesselOfTwo() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            // The staged vessel: controller + six drones aboard, adoption on the
            // drone side only (what `GET devices` actually returns).
            try Device.insert { Self.bareVessel("F2908E6E") }.execute(db)
            try Device.insert {
                Self.controller("B2CBDEC6", stowedIn: "F2908E6E", controlling: [])
            }.execute(db)
            for code in ["A697D0E8", "416059AA", "A1D08194", "71AF5FE8", "7487448E", "89C1A6EF"] {
                try Device.insert {
                    Self.drone(code, stowedIn: "F2908E6E", controlledBy: "B2CBDEC6")
                }.execute(db)
            }
            // The other vessel, carrying no controller, and the other survey
            // controller — deployed in another system, stowed in nothing.
            try Device.insert { Self.bareVessel("965AC2C3") }.execute(db)
            try Device.insert { Self.deployedController("E45C43AB") }.execute(db)
        }
        let store = TestStore(initialState: NewDirectiveFeature.State()) {
            NewDirectiveFeature()
        } withDependencies: { $0.defaultDatabase = database }
        store.exhaustivity = .off

        #expect(store.state.eligibleVessels.map(\.deviceCode) == ["F2908E6E"])
    }

    /// A vessel carrying a controller with NO adopted drone is not eligible
    /// either — `launch` would deploy nothing.
    @Test func aControllerWithoutDronesIsNotEligible() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Device.insert { Self.bareVessel("VES1") }.execute(db)
            try Device.insert {
                Self.controller("AMI1", stowedIn: "VES1", controlling: [])
            }.execute(db)
        }
        let store = TestStore(initialState: NewDirectiveFeature.State()) {
            NewDirectiveFeature()
        } withDependencies: { $0.defaultDatabase = database }
        store.exhaustivity = .off

        #expect(store.state.eligibleVessels.isEmpty)
    }

    /// Launch writes a running directive seeded at the machine's first step,
    /// with the origin recorded so `returnToOrigin` has a destination.
    @Test func launchCreatesARunningDirective() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            for device in Self.stagedFleet() { try Device.insert { device }.execute(db) }
        }
        let store = TestStore(initialState: NewDirectiveFeature.State()) {
            NewDirectiveFeature()
        } withDependencies: {
            $0.defaultDatabase = database
            $0.uuid = .incrementing
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
        }
        store.exhaustivity = .off

        await store.send(.binding(.set(\.vesselCode, "VES1")))
        await store.send(.targetAdded("TAU"))
        await store.send(.launchTapped)
        await store.receive(\.delegate.created)

        let created = try await database.read { db in try Directive.all.fetchAll(db) }
        #expect(created.count == 1)
        #expect(created[0].status == .running)
        #expect(created[0].kind == .surveyRun)
        #expect(created[0].deviceCode == "VES1")
        #expect(created[0].targets == ["TAU"])
        #expect(created[0].targetIndex == 0)
        #expect(created[0].step == SurveyRun().firstStep)
        #expect(created[0].originDesignation == "SOL")
        #expect(created[0].controllerCode == nil, "the engine claims the controller at preflight")
    }

    /// Launch is refused with no vessel or no targets — an empty queue would
    /// complete instantly and read as a bug.
    @Test func launchNeedsAVesselAndATarget() async throws {
        let database = try GameDatabase.bootstrap()
        let store = TestStore(initialState: NewDirectiveFeature.State()) {
            NewDirectiveFeature()
        } withDependencies: { $0.defaultDatabase = database }
        store.exhaustivity = .off

        #expect(store.state.canLaunch == false)
        await store.send(.launchTapped)
        let created = try await database.read { db in try Directive.all.fetchAll(db) }
        #expect(created.isEmpty)
    }

    /// A double tap doesn't queue the same target twice. (The queue itself
    /// allows duplicates — a deliberate revisit is a real thing to want — the
    /// picker just doesn't create them by accident.)
    @Test func doesNotDoubleAddATarget() async throws {
        let database = try GameDatabase.bootstrap()
        let store = TestStore(initialState: NewDirectiveFeature.State()) {
            NewDirectiveFeature()
        } withDependencies: { $0.defaultDatabase = database }
        store.exhaustivity = .off

        await store.send(.targetAdded("TAU"))
        await store.send(.targetAdded("TAU"))
        #expect(store.state.targets == ["TAU"])
    }

    /// Search matches by prefix, case-insensitively, and hides what's queued.
    @Test func searchExcludesQueuedTargets() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Star.insert { Self.star("TAU") }.execute(db)
            try Star.insert { Self.star("TAURUS") }.execute(db)
            try Star.insert { Self.star("SOL") }.execute(db)
        }
        let store = TestStore(initialState: NewDirectiveFeature.State()) {
            NewDirectiveFeature()
        } withDependencies: { $0.defaultDatabase = database }
        store.exhaustivity = .off

        await store.send(.binding(.set(\.search, "tau")))
        #expect(store.state.searchResults.map(\.designation) == ["TAU", "TAURUS"])

        await store.send(.targetAdded("TAU"))
        await store.send(.binding(.set(\.search, "tau")))
        #expect(store.state.searchResults.map(\.designation) == ["TAURUS"])
    }

    // MARK: - Fixtures

    nonisolated static func bareVessel(_ code: String) -> Device {
        Device(
            deviceCode: code, deviceType: "transport_hauler", replicantCode: "R1",
            status: "idle", location: "SOL-3", locationName: nil, operationalCapacity: 100,
            queueSize: 0, stowedInDeviceCode: nil, controllerDeviceCode: nil,
            attachedToDeviceCode: nil, createdAt: Date(timeIntervalSince1970: 0),
            availableCommands: [], features: [], tags: [], detail: .object([:]),
            updatedAt: Date(timeIntervalSince1970: 0), firstSeenAt: Date(timeIntervalSince1970: 0)
        )
    }

    nonisolated static func controller(_ code: String, stowedIn: String, controlling: [String]) -> Device {
        var detail: [String: JSONValue] = [
            "available_directives": .array([.string("survey_system")]),
        ]
        if !controlling.isEmpty {
            detail["controlled_devices"] = .array(controlling.map { drone in
                .object(["device_code": .string(drone), "device_type": .string("survey_drone")])
            })
        }
        var device = bareVessel(code)
        device.deviceType = "ami_survey_controller"
        device.stowedInDeviceCode = stowedIn
        device.detail = .object(detail)
        return device
    }

    nonisolated static func stagedFleet() -> [Device] {
        var drone = bareVessel("DRONE1")
        drone.deviceType = "survey_drone"
        drone.stowedInDeviceCode = "VES1"
        drone.controllerDeviceCode = "AMI1"
        return [bareVessel("VES1"), controller("AMI1", stowedIn: "VES1", controlling: ["DRONE1"]), drone]
    }

    /// The launcher suggests the five nearest systems still worth surveying,
    /// measured from the chosen vessel's own system. The anchor is `SOL` because
    /// `bareVessel` sits at `SOL-3`, and a system designation is the part before
    /// the first hyphen.
    @Test func suggestsTheFiveNearestUnexploredSystems() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            for device in Self.stagedFleet() { try Device.insert { device }.execute(db) }
            try Star.insert { Self.star("SOL", x: 0) }.execute(db)
            for (index, name) in ["A", "B", "C", "D", "E", "F"].enumerated() {
                try Star.insert { Self.star(name, x: Double(index + 1)) }.execute(db)
            }
        }
        let store = TestStore(initialState: NewDirectiveFeature.State()) {
            NewDirectiveFeature()
        } withDependencies: { $0.defaultDatabase = database }
        store.exhaustivity = .off

        await store.send(\.binding.vesselCode, "VES1")
        #expect(store.state.anchorSystem == "SOL")
        #expect(store.state.suggestedTargets.map(\.designation) == ["A", "B", "C", "D", "E"])
    }

    /// Adding a suggestion removes it and pulls in the next-nearest — the list
    /// stays anchored on the vessel rather than re-basing on the queue.
    @Test func addingASuggestionPullsInTheNextNearest() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            for device in Self.stagedFleet() { try Device.insert { device }.execute(db) }
            try Star.insert { Self.star("SOL", x: 0) }.execute(db)
            for (index, name) in ["A", "B", "C", "D", "E", "F"].enumerated() {
                try Star.insert { Self.star(name, x: Double(index + 1)) }.execute(db)
            }
        }
        let store = TestStore(initialState: NewDirectiveFeature.State()) {
            NewDirectiveFeature()
        } withDependencies: { $0.defaultDatabase = database }
        store.exhaustivity = .off

        await store.send(\.binding.vesselCode, "VES1")
        await store.send(.targetAdded("B"))
        #expect(store.state.suggestedTargets.map(\.designation) == ["A", "C", "D", "E", "F"])
    }

    /// A fully-scanned system is done and must not be offered. This is what the
    /// fullyScannedAt work exists for.
    @Test func doesNotSuggestFullyScannedSystems() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            for device in Self.stagedFleet() { try Device.insert { device }.execute(db) }
            try Star.insert { Self.star("SOL", x: 0) }.execute(db)
            try Star.insert {
                Self.star("DONE", x: 1, fullyScannedAt: Date(timeIntervalSince1970: 10))
            }.execute(db)
            try Star.insert { Self.star("UNDONE", x: 2) }.execute(db)
        }
        let store = TestStore(initialState: NewDirectiveFeature.State()) {
            NewDirectiveFeature()
        } withDependencies: { $0.defaultDatabase = database }
        store.exhaustivity = .off

        await store.send(\.binding.vesselCode, "VES1")
        #expect(store.state.suggestedTargets.map(\.designation) == ["UNDONE"])
    }

    /// No vessel chosen means no anchor to measure from — and so no suggestions.
    /// Consistent with the row this dialog writes, which already leaves
    /// `originDesignation` nil for a vessel with no location.
    @Test func offersNoSuggestionsWithoutAnAnchor() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            for device in Self.stagedFleet() { try Device.insert { device }.execute(db) }
            try Star.insert { Self.star("SOL", x: 0) }.execute(db)
            try Star.insert { Self.star("A", x: 1) }.execute(db)
        }
        let store = TestStore(initialState: NewDirectiveFeature.State()) {
            NewDirectiveFeature()
        } withDependencies: { $0.defaultDatabase = database }
        store.exhaustivity = .off

        #expect(store.state.anchorSystem == nil)
        #expect(store.state.suggestedTargets.isEmpty)
    }

    /// A survey drone stowed aboard `stowedIn` and adopted by `controlledBy`,
    /// with adoption recorded only here — the drone's side of the link.
    nonisolated static func drone(_ code: String, stowedIn: String, controlledBy: String) -> Device {
        var device = bareVessel(code)
        device.deviceType = "survey_drone"
        device.status = "stowed"
        device.stowedInDeviceCode = stowedIn
        device.controllerDeviceCode = controlledBy
        return device
    }

    /// A survey controller out in the world rather than stowed in anything.
    nonisolated static func deployedController(_ code: String) -> Device {
        var device = bareVessel(code)
        device.deviceType = "ami_survey_controller"
        device.status = "coordinating"
        device.detail = .object(["available_directives": .array([.string("survey_system")])])
        return device
    }

    /// The staged fleet as the fleet-wide sync stores it: no `controlled_devices`
    /// on the controller, adoption visible only on the drone.
    nonisolated static func listSyncedFleet() -> [Device] {
        var drone = bareVessel("DRONE1")
        drone.deviceType = "survey_drone"
        drone.stowedInDeviceCode = "VES1"
        drone.controllerDeviceCode = "AMI1"
        return [bareVessel("VES1"), controller("AMI1", stowedIn: "VES1", controlling: []), drone]
    }

    nonisolated static func star(_ designation: String) -> Star {
        Star(
            designation: designation, spectralType: "G", color: "yellow",
            positionX: 0, positionY: 0, positionZ: 0, estimatedPlanets: 3,
            explored: false, hasLife: nil, entryPoint: nil,
            createdAt: Date(timeIntervalSince1970: 0), firstVisitedAt: nil, fullyScannedAt: nil
        )
    }

    /// A census row at `x` light-years along the X axis, optionally stamped as
    /// fully scanned.
    nonisolated static func star(
        _ designation: String, x: Double, fullyScannedAt: Date? = nil
    ) -> Star {
        Star(
            designation: designation, spectralType: "G", color: "yellow",
            positionX: x, positionY: 0, positionZ: 0, estimatedPlanets: 3,
            explored: false, hasLife: nil, entryPoint: nil,
            createdAt: Date(timeIntervalSince1970: 0),
            firstVisitedAt: nil, fullyScannedAt: fullyScannedAt
        )
    }
}
