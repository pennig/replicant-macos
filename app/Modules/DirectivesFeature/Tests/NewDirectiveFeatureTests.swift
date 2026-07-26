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

    nonisolated static func star(_ designation: String) -> Star {
        Star(
            designation: designation, spectralType: "G", color: "yellow",
            positionX: 0, positionY: 0, positionZ: 0, estimatedPlanets: 3,
            explored: false, hasLife: nil, entryPoint: nil,
            createdAt: Date(timeIntervalSince1970: 0), firstVisitedAt: nil, fullyScannedAt: nil
        )
    }
}
