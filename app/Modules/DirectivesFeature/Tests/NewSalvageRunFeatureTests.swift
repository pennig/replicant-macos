//
//  NewSalvageRunFeatureTests.swift
//  Replicould — Directives feature
//
//  The Salvage Run launcher: it offers only vessels `SalvageRun`'s OWN fleet
//  queries would call staged, and the row it writes is exactly what
//  `SalvageRun.preflight` expects to find — an empty queue and no claimed
//  controller, so the engine plans and claims both itself. There is no fixed-
//  queue variant here: a Salvage Run is always continuous (design spec §5).
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

@Suite("New salvage run")
@MainActor
struct NewSalvageRunFeatureTests {
    /// Only a vessel carrying a mining controller with at least one adopted
    /// drone stowed aboard is offered — the same two preconditions
    /// `SalvageRun.preflight` hard-stalls on, read through `SalvageRun`'s own
    /// queries so the picker cannot manufacture a stall.
    @Test func onlyStagedVesselsAreEligible() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            for device in Self.stagedFleet() { try Device.insert { device }.execute(db) }
            try Device.insert { Self.bareVessel("VES2") }.execute(db)
        }
        let store = TestStore(initialState: NewSalvageRunFeature.State()) {
            NewSalvageRunFeature()
        } withDependencies: { $0.defaultDatabase = database }
        store.exhaustivity = .off

        #expect(store.state.eligibleVessels.map(\.deviceCode) == ["VES1"])
    }

    /// A vessel carrying a controller with NO adopted drone is not eligible —
    /// `launch` would deploy nothing.
    @Test func aControllerWithoutDronesIsNotEligible() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Device.insert { Self.bareVessel("VES1") }.execute(db)
            try Device.insert {
                Self.controller("AMI1", stowedIn: "VES1", controlling: [])
            }.execute(db)
        }
        let store = TestStore(initialState: NewSalvageRunFeature.State()) {
            NewSalvageRunFeature()
        } withDependencies: { $0.defaultDatabase = database }
        store.exhaustivity = .off

        #expect(store.state.eligibleVessels.isEmpty)
    }

    /// A vessel with no mining controller aboard at all is not eligible.
    @Test func aBareVesselIsNotEligible() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Device.insert { Self.bareVessel("VES1") }.execute(db)
        }
        let store = TestStore(initialState: NewSalvageRunFeature.State()) {
            NewSalvageRunFeature()
        } withDependencies: { $0.defaultDatabase = database }
        store.exhaustivity = .off

        #expect(store.state.eligibleVessels.isEmpty)
    }

    /// Adoption recorded ONLY on the drone's side (`controller_device_code`) —
    /// what a fleet-wide sync actually stores, since `GET devices` omits
    /// `controlled_devices` — must still make the vessel eligible.
    @Test func aVesselStagedButSyncedFromTheListIsEligible() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Device.insert { Self.bareVessel("VES1") }.execute(db)
            try Device.insert { Self.controller("AMI1", stowedIn: "VES1", controlling: []) }.execute(db)
            var drone = Self.bareVessel("DRONE1")
            drone.deviceType = "mining_drone"
            drone.stowedInDeviceCode = "VES1"
            drone.controllerDeviceCode = "AMI1"
            try Device.insert { drone }.execute(db)
        }
        let store = TestStore(initialState: NewSalvageRunFeature.State()) {
            NewSalvageRunFeature()
        } withDependencies: { $0.defaultDatabase = database }
        store.exhaustivity = .off

        #expect(store.state.eligibleVessels.map(\.deviceCode) == ["VES1"])
    }

    // MARK: - Readiness (staged AND tagged)

    /// A vessel that is BOTH physically staged and fully tagged is ready to
    /// launch, and there is no untagged gap to report.
    @Test func aStagedAndTaggedVesselIsReady() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            for device in Self.taggedFleet() { try Device.insert { device }.execute(db) }
        }
        let store = TestStore(initialState: NewSalvageRunFeature.State()) {
            NewSalvageRunFeature()
        } withDependencies: { $0.defaultDatabase = database }
        store.exhaustivity = .off

        #expect(store.state.readyVessels.map(\.deviceCode) == ["VES1"])
        #expect(store.state.untaggedStagedVessel == nil)
    }

    /// A vessel that is physically staged but carries NO `auto:salvage` tag
    /// anywhere is still `eligible` (staging is a different question from
    /// tagging), but is NOT ready to launch, and IS named as the specific
    /// gap the empty state should point at.
    @Test func aStagedButUntaggedVesselIsNotReadyAndIsNamed() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            for device in Self.stagedFleet() { try Device.insert { device }.execute(db) }
        }
        let store = TestStore(initialState: NewSalvageRunFeature.State()) {
            NewSalvageRunFeature()
        } withDependencies: { $0.defaultDatabase = database }
        store.exhaustivity = .off

        #expect(store.state.eligibleVessels.map(\.deviceCode) == ["VES1"], "still physically staged")
        #expect(store.state.readyVessels.isEmpty)
        #expect(store.state.untaggedStagedVessel?.deviceCode == "VES1")
    }

    /// Tagging the vessel alone is NOT enough — the picker gates on the
    /// WHOLE fleet the run depends on (vessel, controller, drones, relay),
    /// since `.refreshFleet` is exactly as blind to an untagged controller or
    /// drone as it is to an untagged vessel. Pins that the check isn't
    /// accidentally checking only `vessel.tags`.
    @Test func taggingOnlyTheVesselIsNotEnoughToBeReady() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            var fleet = Self.stagedFleet()
            fleet[0].tags = [SalvageRun.defaultFleetTag] // the vessel only
            for device in fleet { try Device.insert { device }.execute(db) }
        }
        let store = TestStore(initialState: NewSalvageRunFeature.State()) {
            NewSalvageRunFeature()
        } withDependencies: { $0.defaultDatabase = database }
        store.exhaustivity = .off

        #expect(store.state.readyVessels.isEmpty)
        #expect(store.state.untaggedStagedVessel?.deviceCode == "VES1")
    }

    /// A relay aboard but missing the tag also blocks readiness, even when
    /// the vessel/controller/drone are all correctly tagged — the relay is
    /// part of the fleet `.refreshFleet` must be able to see too.
    @Test func anUntaggedRelayAboardAlsoBlocksReadiness() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            for device in Self.taggedFleet() { try Device.insert { device }.execute(db) }
            var relay = Self.bareVessel("RELAY1")
            relay.deviceType = "ftl_relay"
            relay.features = ["relay"]
            relay.stowedInDeviceCode = "VES1"
            // No tags — the gap this test pins.
            try Device.insert { relay }.execute(db)
        }
        let store = TestStore(initialState: NewSalvageRunFeature.State()) {
            NewSalvageRunFeature()
        } withDependencies: { $0.defaultDatabase = database }
        store.exhaustivity = .off

        #expect(store.state.readyVessels.isEmpty)
        #expect(store.state.untaggedStagedVessel?.deviceCode == "VES1")
    }

    /// Launch writes exactly the row the design calls for: the run is always
    /// continuous, the controller is claimed later (at preflight, not here),
    /// and the queue starts empty because the engine plans the first target.
    @Test func launchWritesTheRowTheEngineExpects() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            for device in Self.stagedFleet() { try Device.insert { device }.execute(db) }
        }
        let store = TestStore(initialState: NewSalvageRunFeature.State()) {
            NewSalvageRunFeature()
        } withDependencies: {
            $0.defaultDatabase = database
            $0.uuid = .incrementing
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
        }
        store.exhaustivity = .off

        await store.send(.binding(.set(\.vesselCode, "VES1")))
        await store.send(.launchTapped)
        await store.receive(\.delegate.created)

        let created = try await database.read { db in try Directive.all.fetchAll(db) }
        #expect(created.count == 1)
        #expect(created[0].kind == .salvageRun)
        #expect(created[0].status == .running)
        #expect(created[0].deviceCode == "VES1")
        #expect(created[0].fleetTag == "auto:salvage")
        // `bareVessel` sits at SOL-3, and a system designation is the part
        // before the first hyphen.
        #expect(created[0].roamCentre == "SOL")
        #expect(created[0].controllerCode == nil, "the engine claims the controller at preflight")
        #expect(created[0].targets.isEmpty, "the engine plans the first target itself")
        #expect(created[0].targetIndex == 0)
        #expect(created[0].step == SalvageRun().firstStep)
        #expect(created[0].returnToOrigin == false, "a continuous run has no queue to empty")
    }

    /// The operator-launched path must stamp the SAME per-theatre tag the
    /// brain does — not the bare literal, which is the account-wide
    /// reservation bug this whole effort exists to close.
    @Test func launchStampsThePerTheatreTagWhenATheatreResolves() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            for device in Self.stagedFleet() { try Device.insert { device }.execute(db) }
            try Star.insert {
                Star(
                    designation: "SOL", spectralType: "G", color: "yellow",
                    positionX: 0, positionY: 0, positionZ: 0, estimatedPlanets: 0,
                    explored: false, hasLife: nil, entryPoint: nil,
                    createdAt: Date(timeIntervalSince1970: 0)
                )
            }.execute(db)
            var relay = Self.bareVessel("REL1")
            relay.deviceType = "ftl_relay"
            relay.status = "relaying"
            relay.features = ["relay"]
            relay.location = "SOL"
            try Device.insert { relay }.execute(db)
            var hub = Self.bareVessel("HUB1")
            hub.deviceType = "autofactory"
            hub.availableCommands = ["enqueue_print"]
            try Device.insert { hub }.execute(db)
            try LocationFootprint.insert {
                LocationFootprint(
                    location: "SOL-3", devices: 1, resources: 100_000, resourceSites: 0,
                    locationEvents: 0, replicants: 0, fetchedAt: Date(timeIntervalSince1970: 0)
                )
            }.execute(db)
        }
        let store = TestStore(initialState: NewSalvageRunFeature.State()) {
            NewSalvageRunFeature()
        } withDependencies: {
            $0.defaultDatabase = database
            $0.uuid = .incrementing
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
        }
        store.exhaustivity = .off

        await store.send(.binding(.set(\.vesselCode, "VES1")))
        await store.send(.launchTapped)
        await store.receive(\.delegate.created)

        let row = try #require(try await database.read { db in try Directive.all.fetchAll(db) }.first)
        #expect(row.fleetTag == SalvageRun.fleetTag(forTheatre: "SOL-3"))
    }

    /// Launch is refused with no vessel chosen.
    @Test func launchNeedsAVessel() async throws {
        let database = try GameDatabase.bootstrap()
        let store = TestStore(initialState: NewSalvageRunFeature.State()) {
            NewSalvageRunFeature()
        } withDependencies: { $0.defaultDatabase = database }
        store.exhaustivity = .off

        #expect(store.state.canLaunch == false)
        await store.send(.launchTapped)
        let created = try await database.read { db in try Directive.all.fetchAll(db) }
        #expect(created.isEmpty)
    }

    /// A vessel with no known location gives the run no system to centre on,
    /// so Launch stays disabled rather than writing a row the engine cannot
    /// plan for.
    @Test func launchNeedsAVesselWithAKnownLocation() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            for var device in Self.stagedFleet() {
                if device.deviceCode == "VES1" { device.location = nil }
                try Device.insert { device }.execute(db)
            }
        }
        let store = TestStore(initialState: NewSalvageRunFeature.State()) {
            NewSalvageRunFeature()
        } withDependencies: { $0.defaultDatabase = database }
        store.exhaustivity = .off

        await store.send(.binding(.set(\.vesselCode, "VES1")))
        #expect(store.state.canLaunch == false)
        await store.send(.launchTapped)
        let created = try await database.read { db in try Directive.all.fetchAll(db) }
        #expect(created.isEmpty)
    }

    // MARK: - Fixtures

    nonisolated static func bareVessel(_ code: String) -> Device {
        Device(
            deviceCode: code, deviceType: "heaven_vessel", replicantCode: "R1",
            status: "idle", location: "SOL-3", locationName: nil, operationalCapacity: 100,
            queueSize: 0, stowedInDeviceCode: nil, controllerDeviceCode: nil,
            attachedToDeviceCode: nil, createdAt: Date(timeIntervalSince1970: 0),
            availableCommands: [], features: [], tags: [], detail: .object([:]),
            updatedAt: Date(timeIntervalSince1970: 0), firstSeenAt: Date(timeIntervalSince1970: 0)
        )
    }

    nonisolated static func controller(_ code: String, stowedIn: String, controlling: [String]) -> Device {
        var detail: [String: JSONValue] = [
            "available_directives": .array([.string("gather_salvage")]),
        ]
        if !controlling.isEmpty {
            detail["controlled_devices"] = .array(controlling.map { drone in
                .object(["device_code": .string(drone), "device_type": .string("mining_drone")])
            })
        }
        var device = bareVessel(code)
        device.deviceType = "ami_mining_controller"
        device.stowedInDeviceCode = stowedIn
        device.detail = .object(detail)
        return device
    }

    nonisolated static func stagedFleet() -> [Device] {
        var drone = bareVessel("DRONE1")
        drone.deviceType = "mining_drone"
        drone.stowedInDeviceCode = "VES1"
        drone.controllerDeviceCode = "AMI1"
        return [bareVessel("VES1"), controller("AMI1", stowedIn: "VES1", controlling: ["DRONE1"]), drone]
    }

    /// `stagedFleet()` with every device also carrying `auto:salvage` — the
    /// set the picker will actually offer, and the engine can actually see.
    nonisolated static func taggedFleet() -> [Device] {
        stagedFleet().map { fleetDevice in
            var tagged = fleetDevice
            tagged.tags = [SalvageRun.defaultFleetTag]
            return tagged
        }
    }
}
