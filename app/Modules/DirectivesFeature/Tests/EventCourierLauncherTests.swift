//
//  EventCourierLauncherTests.swift
//  Replicould — Directives feature
//
//  The one-time courier bootstrap: which depot it prints at, and on which host.
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

@Suite("Directives — Print Event Courier")
@MainActor
struct EventCourierLauncherTests {
    nonisolated static let epoch = Date(timeIntervalSince1970: 0)

    nonisolated static func device(
        _ code: String, type: String, location: String?,
        commands: [String] = [], features: [String] = [], status: String = "idle"
    ) -> Device {
        Device(
            deviceCode: code, deviceType: type, replicantCode: "R1", status: status,
            location: location, locationName: nil, operationalCapacity: 100, queueSize: 0,
            stowedInDeviceCode: nil, controllerDeviceCode: nil, attachedToDeviceCode: nil,
            createdAt: epoch, availableCommands: commands, features: features, tags: [],
            detail: .object([:]), updatedAt: epoch, firstSeenAt: epoch
        )
    }

    nonisolated static func star(_ designation: String, at coordinate: Double) -> Star {
        Star(
            designation: designation, spectralType: "G", color: "yellow",
            positionX: coordinate, positionY: coordinate, positionZ: coordinate,
            estimatedPlanets: 0, explored: true, hasLife: nil, entryPoint: nil,
            createdAt: epoch
        )
    }

    nonisolated static func footprint(_ location: String, resources: Int) -> LocationFootprint {
        LocationFootprint(
            location: location, devices: 1, resources: resources, resourceSites: 0,
            locationEvents: 0, replicants: 0, fetchedAt: epoch
        )
    }

    /// Two operational theatres, each with its own printer, far enough apart
    /// that `MeshGraph` keeps them in separate components. `AAA-B` is the
    /// lowest-coded printer in the whole account and stands at the OTHER
    /// theatre's depot — an account-wide `min` picks it and is wrong.
    nonisolated private static func seedTwoTheatres(_ db: Database) throws {
        try Star.insert { Self.star("AINALRAM", at: 0) }.execute(db)
        try Star.insert { Self.star("DENEBED", at: 2_000) }.execute(db)
        try Device.insert {
            Self.device("REL-A", type: "ftl_relay", location: "AINALRAM",
                        features: ["relay"], status: "relaying")
        }.execute(db)
        try Device.insert {
            Self.device("REL-B", type: "ftl_relay", location: "DENEBED",
                        features: ["relay"], status: "relaying")
        }.execute(db)
        try Device.insert {
            Self.device("HUB-A", type: "autofactory", location: "AINALRAM-BELT-1",
                        commands: ["enqueue_print"])
        }.execute(db)
        try Device.insert {
            Self.device("HUB-Z", type: "autofactory", location: "AINALRAM-BELT-1",
                        commands: ["enqueue_print"])
        }.execute(db)
        try Device.insert {
            Self.device("AAA-B", type: "autofactory", location: "DENEBED-BELT-1",
                        commands: ["enqueue_print"])
        }.execute(db)
        try LocationFootprint.insert { Self.footprint("AINALRAM-BELT-1", resources: 100_000) }.execute(db)
        try LocationFootprint.insert { Self.footprint("DENEBED-BELT-1", resources: 90_000) }.execute(db)
    }

    /// A courier already standing at `depot`: a container hosting a replicant.
    nonisolated private static func seedCourier(_ db: Database, at depot: String) throws {
        try Device.insert {
            Self.device("BOX-A", type: EventRun.courierDeviceType, location: depot)
        }.execute(db)
        try Replicant.insert {
            Replicant(
                replicantCode: "R1", name: "R1", createdAt: epoch,
                currentStar: SiteAssay.system(of: depot), currentStarName: nil,
                currentLocation: depot, currentLocationName: nil, hostedDeviceCode: "BOX-A"
            )
        }.execute(db)
    }

    private static func store(_ database: any DatabaseWriter) -> TestStoreOf<DirectivesFeature> {
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

    @Test func tappingPresentsTheConfirmDialog() async throws {
        let database = try GameDatabase.bootstrap()
        let store = Self.store(database)

        await store.send(.eventCourierTapped)
        #expect(store.state.eventCourierDialog?.title == TextState("Print an event courier?"))
    }

    /// The row stamps `theatreDepot` — `EventCourierPrint` resolves its depot
    /// through it and an unstamped row resolves to nothing — and hosts on that
    /// depot's OWN printer, lowest-coded, never the account's.
    @Test func confirmingStampsTheDepotAndHostsOnItsOwnPrinter() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in try Self.seedTwoTheatres(db) }
        let store = Self.store(database)

        await store.send(.eventCourierTapped)
        await store.send(.eventCourierDialog(.presented(.confirm)))
        await store.receive(\.eventCourierLaunched)

        let created = try await database.read { db in try Directive.all.fetchAll(db) }
        #expect(created.count == 1)
        #expect(created[0].kind == .eventCourierPrint)
        #expect(created[0].status == .running)
        #expect(created[0].theatreDepot == "AINALRAM-BELT-1")
        #expect(created[0].deviceCode == "HUB-A")
        #expect(created[0].step == EventCourierPrint().firstStep)
        #expect(created[0].targets.isEmpty)
        #expect(created[0].returnToOrigin == false)
    }

    /// A depot whose courier already stands is skipped, and the launch lands on
    /// the next theatre — on ITS printer, at ITS depot.
    @Test func aDepotThatAlreadyHasACourierIsSkipped() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Self.seedTwoTheatres(db)
            try Self.seedCourier(db, at: "AINALRAM-BELT-1")
        }
        let store = Self.store(database)

        await store.send(.eventCourierTapped)
        await store.send(.eventCourierDialog(.presented(.confirm)))
        await store.receive(\.eventCourierLaunched)

        let created = try await database.read { db in try Directive.all.fetchAll(db) }
        #expect(created.count == 1)
        #expect(created[0].theatreDepot == "DENEBED-BELT-1")
        #expect(created[0].deviceCode == "AAA-B")
    }

    /// A live courier print blocks a second launch: the tap presents the
    /// already-running dialog and its one button inserts nothing.
    @Test func aLiveRowBlocksLaunchAndInsertsNothing() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Self.seedTwoTheatres(db)
            try Directive.insert {
                Directive(
                    id: "C1", kind: .eventCourierPrint, status: .running, deviceCode: "HUB-A",
                    targets: [], targetIndex: 0, step: EventCourierPrint().firstStep,
                    stepStartedAt: Self.epoch, returnToOrigin: false, originDesignation: nil,
                    attentionReason: nil, createdAt: Self.epoch, updatedAt: Self.epoch,
                    theatreDepot: "AINALRAM-BELT-1"
                )
            }.execute(db)
        }
        let store = Self.store(database)

        await store.send(.eventCourierTapped)
        #expect(store.state.eventCourierDialog?.title != TextState("Print an event courier?"))
        await store.send(.eventCourierDialog(.dismiss))

        let created = try await database.read { db in try Directive.all.fetchAll(db) }
        #expect(created.count == 1)
    }

    /// No theatre needs one — the only theatre's courier already stands — so
    /// confirming reports it and writes nothing.
    @Test func noSiteReportsItAndInsertsNothing() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Star.insert { Self.star("AINALRAM", at: 0) }.execute(db)
            try Device.insert {
                Self.device("REL-A", type: "ftl_relay", location: "AINALRAM",
                            features: ["relay"], status: "relaying")
            }.execute(db)
            try Device.insert {
                Self.device("HUB-A", type: "autofactory", location: "AINALRAM-BELT-1",
                            commands: ["enqueue_print"])
            }.execute(db)
            try LocationFootprint.insert {
                Self.footprint("AINALRAM-BELT-1", resources: 100_000)
            }.execute(db)
            try Self.seedCourier(db, at: "AINALRAM-BELT-1")
        }
        let store = Self.store(database)

        await store.send(.eventCourierTapped)
        await store.send(.eventCourierDialog(.presented(.confirm)))
        await store.receive(\.eventCourierSiteMissing)

        #expect(store.state.eventCourierDialog?.title == TextState("No depot can print a courier."))
        let created = try await database.read { db in try Directive.all.fetchAll(db) }
        #expect(created.isEmpty)
    }
}
