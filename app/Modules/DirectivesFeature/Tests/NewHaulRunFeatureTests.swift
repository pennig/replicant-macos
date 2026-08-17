//
//  NewHaulRunFeatureTests.swift
//  Replicould — Directives feature
//
//  The Haul Run launcher: there is no picker (design spec §6/§4) — the run
//  drives EVERY controller tagged `auto:haul`, so this dialog reports the
//  fleet the tag resolves to and offers Launch. The row it writes is exactly
//  what `HaulRun.preflight` expects: a tagged, continuous run anchored on the
//  lowest-coded tagged controller (`Directive.deviceCode` is a required
//  column the machine never reads back).
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

private let fixtureNow = Date(timeIntervalSince1970: 10_000)

@Suite("New haul run")
@MainActor
struct NewHaulRunFeatureTests {
    /// `devices` is `@ObservationStateIgnored @FetchAll`, so it hydrates from
    /// the database rather than being set directly — seed, then read the
    /// computed state. Same shape as `NewSalvageRunFeatureTests`.
    private func store(seeding devices: [Device]) async throws -> (store: TestStoreOf<NewHaulRunFeature>, database: any DatabaseWriter) {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            for device in devices { try Device.insert { device }.execute(db) }
        }
        let store = TestStore(initialState: NewHaulRunFeature.State()) {
            NewHaulRunFeature()
        } withDependencies: {
            $0.defaultDatabase = database
            $0.date = .constant(fixtureNow)
            $0.uuid = .incrementing
        }
        store.exhaustivity = .off
        return (store, database)
    }

    @Test func aTaggedControllerIsReadyAndAnchorsTheRow() async throws {
        let (store, _) = try await store(seeding: [Self.controller("C2"), Self.controller("C1")])
        #expect(store.state.readyControllers.map(\.deviceCode) == ["C1", "C2"])
        // Lowest code anchors the required deviceCode column.
        #expect(store.state.anchorControllerCode == "C1")
        #expect(store.state.canLaunch)
    }

    /// The distinguishing empty state: a transport controller exists but
    /// nobody tagged it, so the sheet can name it instead of showing an
    /// empty list.
    @Test func anUntaggedControllerIsNamedRatherThanHidden() async throws {
        let (store, _) = try await store(seeding: [Self.controller("C1", tags: [])])
        #expect(store.state.readyControllers.isEmpty)
        #expect(store.state.untaggedController?.deviceCode == "C1")
        #expect(!store.state.canLaunch)
    }

    /// A device that cannot ferry is not a haul controller at all — and is
    /// not offered as an "untagged" near-miss either, which would send the
    /// operator to tag something that still could not haul.
    @Test func aDeviceWithoutFerryIsNotAHaulController() async throws {
        let (store, _) = try await store(
            seeding: [Self.controller("C1", tags: [], directives: ["survey_system"])]
        )
        #expect(store.state.readyControllers.isEmpty)
        #expect(store.state.untaggedController == nil)
    }

    /// The row the launcher writes is what the engine then reads, so its
    /// shape is load-bearing: tagged, continuous, and anchored on the
    /// lowest-coded controller.
    @Test func launchWritesATaggedContinuousRow() async throws {
        let (store, database) = try await store(seeding: [Self.controller("C2"), Self.controller("C1")])

        await store.send(.launchTapped)
        await store.receive(\.delegate.created)

        // `TestStore.receive(_:assert:)`'s closure mutates EXPECTED STATE, not
        // the action's payload — there is no overload that hands back the
        // created `Directive` directly (`NewSalvageRunFeatureTests` reads the
        // same way). Read the written row back off the database instead.
        let rows = try await database.read { db in try Directive.all.fetchAll(db) }
        let row = try #require(rows.first)

        #expect(rows.count == 1)
        #expect(row.kind == .haulRun)
        #expect(row.status == .running)
        #expect(row.deviceCode == "C1")
        #expect(row.fleetTag == HaulRun.defaultFleetTag.string)
        #expect(row.step == HaulRun.Step.preflight.rawValue)
        // Empty and stays empty: the planner re-derives from the census every
        // cycle and records no history.
        #expect(row.targets.isEmpty)
        // A continuous run has no queue to empty, so a return leg could never
        // fire — the column must not claim an intent that cannot happen.
        #expect(!row.returnToOrigin)
        // The run drives EVERY tagged controller, so pinning one would misstate it.
        #expect(row.controllerCode == nil)
        #expect(row.theatreDepot == nil, "nothing in this world makes ATIANFU-1-L4 a theatre")
        // Without this an unstamped row is stranded: `Brain.adoptTheatres` can
        // only rescue one through its origin, or a lone operational theatre.
        #expect(row.originDesignation == "ATIANFU")
    }

    /// The operator-launched path must stamp the SAME per-theatre tag the
    /// brain does — not the bare literal, which is the account-wide
    /// reservation bug this whole effort exists to close.
    @Test func launchStampsThePerTheatreTagWhenATheatreResolves() async throws {
        let (store, database) = try await self.store(seeding: [Self.controller("C1", location: "GRAZ-3")])
        try await database.write { db in
            try Star.insert {
                Star(
                    designation: "GRAZ", spectralType: "G", color: "yellow",
                    positionX: 0, positionY: 0, positionZ: 0, estimatedPlanets: 0,
                    explored: false, hasLife: nil, entryPoint: nil, createdAt: fixtureNow
                )
            }.execute(db)
            try Device.insert {
                Device(
                    deviceCode: "REL1", deviceType: "ftl_relay", replicantCode: "R1",
                    status: "relaying", location: "GRAZ", locationName: nil,
                    operationalCapacity: 100, queueSize: 0, stowedInDeviceCode: nil,
                    controllerDeviceCode: nil, attachedToDeviceCode: nil, createdAt: fixtureNow,
                    availableCommands: [], features: ["relay"], tags: [], detail: .object([:]),
                    updatedAt: fixtureNow, firstSeenAt: fixtureNow
                )
            }.execute(db)
            try Device.insert {
                Device(
                    deviceCode: "HUB1", deviceType: "autofactory", replicantCode: "R1",
                    status: "idle", location: "GRAZ-3", locationName: nil,
                    operationalCapacity: 100, queueSize: 0, stowedInDeviceCode: nil,
                    controllerDeviceCode: nil, attachedToDeviceCode: nil, createdAt: fixtureNow,
                    availableCommands: ["enqueue_print"], features: [], tags: [], detail: .object([:]),
                    updatedAt: fixtureNow, firstSeenAt: fixtureNow
                )
            }.execute(db)
            try LocationFootprint.insert {
                LocationFootprint(
                    location: "GRAZ-3", devices: 1, resources: 100_000, resourceSites: 0,
                    locationEvents: 0, replicants: 0, fetchedAt: fixtureNow
                )
            }.execute(db)
        }

        await store.send(.launchTapped)
        await store.receive(\.delegate.created)

        let row = try #require(try await database.read { db in try Directive.all.fetchAll(db) }.first)
        #expect(row.fleetTag == HaulRun.fleetTag(forTheatre: "GRAZ-3").string)
        #expect(row.theatreDepot == "GRAZ-3", "the stamp `ensureOne.owns` scopes on")
        #expect(row.originDesignation == "GRAZ")
    }

    /// Launch with no tagged controller must write nothing at all.
    @Test func launchIsInertWithoutAFleet() async throws {
        let (store, database) = try await store(seeding: [Self.controller("C1", tags: [])])
        await store.send(.launchTapped)
        // No delegate, no row — `.exhaustivity = .off` would let a stray
        // effect pass silently, so assert the database directly.
        let count = try await database.read { db in
            try Directive.all.fetchCount(db)
        }
        #expect(count == 0)
    }

    // MARK: - Fixtures

    nonisolated static func controller(
        _ code: String,
        tags: [String] = ["auto:haul"],
        directives: [String] = ["delivery", "ferry", "shuttle", "consolidate"],
        location: String = "ATIANFU-1-L4"
    ) -> Device {
        Device(
            deviceCode: code, deviceType: "ami_transport_controller", replicantCode: "R1",
            status: "coordinating", location: location, locationName: nil,
            operationalCapacity: 100, queueSize: 0, stowedInDeviceCode: nil,
            controllerDeviceCode: nil, attachedToDeviceCode: nil,
            createdAt: fixtureNow, availableCommands: [],
            features: ["ami"], tags: tags,
            detail: .object(["available_directives": .array(directives.map(JSONValue.string))]),
            updatedAt: fixtureNow, firstSeenAt: fixtureNow
        )
    }
}
