//
//  NewFetchRunFeatureTests.swift
//  Replicould — Directives feature
//
//  The Fetch Run launcher: which devices it offers, which plate it resolves,
//  and the shape of the row it writes — which is what `FetchRun.preflight`
//  reads back, so getting it wrong manufactures a stall on the first tick.
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

@Suite("New fetch run")
@MainActor
struct NewFetchRunFeatureTests {
    /// `devices`/`directives`/`stars` are `@FetchAll`, so they hydrate from the
    /// database rather than being set directly — seed, then read the computed
    /// state. Same shape as `NewHaulRunFeatureTests`.
    private func store(
        seeding devices: [Device],
        directives: [Directive] = [],
        stars: [Star] = []
    ) async throws -> (store: TestStoreOf<NewFetchRunFeature>, database: any DatabaseWriter) {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            for device in devices { try Device.insert { device }.execute(db) }
            for directive in directives { try Directive.insert { directive }.execute(db) }
            for star in stars { try Star.insert { star }.execute(db) }
        }
        let store = TestStore(initialState: NewFetchRunFeature.State()) {
            NewFetchRunFeature()
        } withDependencies: {
            $0.defaultDatabase = database
            $0.date = .constant(fixtureNow)
            $0.uuid = .incrementing
        }
        store.exhaustivity = .off
        return (store, database)
    }

    // MARK: - Eligibility, as pure functions

    /// A stowed device has no `location` and no plate can reach it. That is
    /// what the filter is for, not an accident of the query.
    @Test nonisolated func offersOnlyDevicesThatHaveALocationAndAreUnleased() {
        let offered = NewFetchRunFeature.State.eligiblePayloads(
            in: [
                Self.payload("FREE"),
                Self.payload("STOWED", location: nil),
                Self.payload("HELD"),
                Self.plate("PLATE1"),
            ],
            reserved: ["HELD"]
        )
        #expect(offered.map(\.deviceCode) == ["FREE"])
    }

    /// A fetch to where the device already stands does nothing.
    @Test nonisolated func refusesADestinationThePayloadAlreadyOccupies() {
        #expect(!NewFetchRunFeature.State.canLaunch(
            payload: Self.payload("FREE"), destination: "VEGA-2", plate: Self.plate("PLATE1")
        ))
        #expect(NewFetchRunFeature.State.canLaunch(
            payload: Self.payload("FREE"), destination: "SOL-3", plate: Self.plate("PLATE1")
        ))
    }

    @Test nonisolated func refusesToLaunchWithoutAPlate() {
        #expect(!NewFetchRunFeature.State.canLaunch(
            payload: Self.payload("FREE"), destination: "SOL-3", plate: nil
        ))
    }

    // MARK: - Against a seeded world

    @Test func resolvesThePlateOnceADeviceIsPicked() async throws {
        let (store, _) = try await store(seeding: [Self.payload("FREE"), Self.plate("PLATE1")])
        #expect(store.state.resolvedPlate == nil, "nothing picked yet")
        await store.send(.binding(.set(\.payloadCode, "FREE")))
        #expect(store.state.resolvedPlate?.deviceCode == "PLATE1")
    }

    /// The picker and the engine share one definition of "already held", so a
    /// device the brain is using is never offered in the first place.
    @Test func aDeviceHeldByARunningDirectiveIsNotOffered() async throws {
        let holder = Directive.launch(
            .init(kind: .salvageRun, deviceCode: "FREE", theatre: nil), id: "S1", now: fixtureNow
        )
        let (store, _) = try await store(
            seeding: [Self.payload("FREE"), Self.plate("PLATE1")], directives: [holder]
        )
        #expect(store.state.eligiblePayloads.isEmpty)
    }

    /// The row the launcher writes is what the engine reads back: the plate is
    /// the hull, the payload is the lease, and the two stops are pinned in
    /// pickup-then-destination order.
    @Test func launchWritesThePlateThePayloadAndBothStops() async throws {
        let (store, database) = try await store(seeding: [Self.payload("FREE"), Self.plate("PLATE1")])
        await store.send(.binding(.set(\.payloadCode, "FREE")))
        await store.send(.binding(.set(\.destination, "SOL-3")))
        #expect(store.state.canLaunch)

        await store.send(.launchTapped)
        await store.receive(\.delegate.created)

        let rows = try await database.read { db in try Directive.all.fetchAll(db) }
        let row = try #require(rows.first)

        #expect(rows.count == 1)
        #expect(row.kind == .fetchRun)
        #expect(row.status == .running)
        // The PLATE is the hull; the payload rides in its own column.
        #expect(row.deviceCode == "PLATE1")
        #expect(row.payloadCode == "FREE")
        #expect(row.targets == ["VEGA-2", "SOL-3"])
        #expect(row.step == FetchRun.Step.preflight.rawValue)
        // Reserves by device columns alone — no tag.
        #expect(row.fleetTag == nil)
        // The plate parks near the DESTINATION, resolved at homing; a return
        // leg would send it back where it started instead.
        #expect(!row.returnToOrigin)
    }

    // MARK: - Fixtures

    nonisolated static func payload(
        _ code: String, location: String? = "VEGA-2", type: String = "autofactory"
    ) -> Device {
        Device(
            deviceCode: code, deviceType: type, replicantCode: "R1", status: "idle",
            location: location, locationName: nil, operationalCapacity: 100, queueSize: 0,
            stowedInDeviceCode: nil, controllerDeviceCode: nil, attachedToDeviceCode: nil,
            createdAt: fixtureNow, availableCommands: [], features: [], tags: [],
            detail: .object([:]), updatedAt: fixtureNow, firstSeenAt: fixtureNow
        )
    }

    nonisolated static func plate(
        _ code: String, location: String? = "SOL-3", tags: [String] = ["fetch"]
    ) -> Device {
        Device(
            deviceCode: code, deviceType: "surge_plate", replicantCode: "R1", status: "idle",
            location: location, locationName: nil, operationalCapacity: 100, queueSize: 0,
            stowedInDeviceCode: nil, controllerDeviceCode: nil, attachedToDeviceCode: nil,
            createdAt: fixtureNow, availableCommands: [], features: [], tags: tags,
            detail: .object(["attach_capacity": .number(2)]),
            updatedAt: fixtureNow, firstSeenAt: fixtureNow
        )
    }
}
