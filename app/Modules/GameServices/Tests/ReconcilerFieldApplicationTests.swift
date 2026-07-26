//
//  ReconcilerFieldApplicationTests.swift
//  Replicould — GameServices
//
//  Guarded payload application (V3.5 row 2): the event envelope's location is
//  folded into the device row under a strict event-time guard — replayed or
//  out-of-order events can never regress the row, and applying advances the
//  row's event-time so earlier-issued reads landing later are dropped too.
//

import ComposableArchitecture
import Foundation
import GameDatabase
import GameModels
import SQLiteData
import Testing
@testable import GameServices

@Suite struct ReconcilerFieldApplicationTests {

    private func seed(
        _ database: any DatabaseWriter,
        code: String = "SHIP",
        location: String? = "TENEGSHE-3",
        locationName: String? = "Tenegshe III",
        updatedAt: Date
    ) async throws {
        let device = Device(
            deviceCode: code, deviceType: "heaven_vessel", replicantCode: "R1", status: "travelling",
            location: location, locationName: locationName, operationalCapacity: 100, queueSize: 0,
            stowedInDeviceCode: nil, controllerDeviceCode: nil, attachedToDeviceCode: nil,
            createdAt: Date(timeIntervalSince1970: 0), availableCommands: [], features: [], tags: [],
            detail: .object([:]), updatedAt: updatedAt, firstSeenAt: updatedAt
        )
        try await database.write { db in try Device.upsert { device }.execute(db) }
    }

    private func row(_ database: any DatabaseWriter, _ code: String = "SHIP") async throws -> Device? {
        try await database.read { db in
            try Device.where { $0.deviceCode.eq(code) }.fetchOne(db)
        }
    }

    /// A strictly newer event applies its location, clears the (now unknown)
    /// display name, and advances the row's event-time.
    @Test func newerEventAppliesLocation() async throws {
        let database = try GameDatabase.bootstrap()
        try await seed(database, updatedAt: Date(timeIntervalSince1970: 1_000))

        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 2_000))
        } operation: {
            let applied = await Reconciler().applyEventFields(
                deviceCode: "SHIP",
                location: "TENEGSHE-7-L4",
                eventTime: Date(timeIntervalSince1970: 1_010)
            )
            #expect(applied)
        }

        let device = try await row(database)
        #expect(device?.location == "TENEGSHE-7-L4")
        #expect(device?.locationName == nil)
        #expect(device?.updatedAt == Date(timeIntervalSince1970: 1_010))
    }

    /// A stale event is dropped whole — no field change, no clock advance.
    @Test func staleEventIsDropped() async throws {
        let database = try GameDatabase.bootstrap()
        try await seed(database, updatedAt: Date(timeIntervalSince1970: 1_000))

        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 2_000))
        } operation: {
            let stale = await Reconciler().applyEventFields(
                deviceCode: "SHIP", location: "ELSEWHERE-1",
                eventTime: Date(timeIntervalSince1970: 990)
            )
            #expect(!stale)
        }

        let device = try await row(database)
        #expect(device?.location == "TENEGSHE-3")
        #expect(device?.locationName == "Tenegshe III")
        #expect(device?.updatedAt == Date(timeIntervalSince1970: 1_000))
    }

    /// A tied event applies: live `created_at` stamps have second granularity,
    /// so the later event of an ordered same-second pair (arrive → deploy)
    /// must win; a replayed identical event is an idempotent re-apply.
    @Test func tiedEventApplies() async throws {
        let database = try GameDatabase.bootstrap()
        try await seed(database, updatedAt: Date(timeIntervalSince1970: 1_000))

        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 2_000))
        } operation: {
            let tied = await Reconciler().applyEventFields(
                deviceCode: "SHIP", location: "TENEGSHE-7-L4",
                eventTime: Date(timeIntervalSince1970: 1_000)
            )
            #expect(tied)
        }

        let device = try await row(database)
        #expect(device?.location == "TENEGSHE-7-L4")
    }

    /// A server clock running ahead can't stamp the row into the local future:
    /// the applied stamp is clamped to the local clock, so the very next read
    /// (issued locally) still wins.
    @Test func futureEventTimeIsClampedToLocalClock() async throws {
        let database = try GameDatabase.bootstrap()
        try await seed(database, updatedAt: Date(timeIntervalSince1970: 1_000))

        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_005))   // local now
            $0.uuid = .incrementing
        } operation: {
            _ = await Reconciler().applyEventFields(
                deviceCode: "SHIP", location: "TENEGSHE-7-L4",
                eventTime: Date(timeIntervalSince1970: 1_060)   // server ahead
            )
            let clamped = try #require(await row(database))
            #expect(clamped.updatedAt == Date(timeIntervalSince1970: 1_005))

            // Self-heal: a read issued right after (locally) must apply.
            var snapshot = clamped
            snapshot.status = "idle"
            snapshot.updatedAt = Date(timeIntervalSince1970: 1_006)
            await Reconciler().ingest(snapshot)
        }

        let device = try await row(database)
        #expect(device?.status == "idle")
    }

    /// A nil event time (unparseable `created_at`) is a no-op.
    @Test func nilEventTimeIsANoOp() async throws {
        let database = try GameDatabase.bootstrap()
        try await seed(database, updatedAt: Date(timeIntervalSince1970: 1_000))

        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 2_000))
        } operation: {
            let applied = await Reconciler().applyEventFields(
                deviceCode: "SHIP", location: "ELSEWHERE-1", eventTime: nil
            )
            #expect(!applied)
        }

        let device = try await row(database)
        #expect(device?.location == "TENEGSHE-3")
    }

    /// A nil envelope location is meaningful — the device is in transit or
    /// stowed — and applies like any other value.
    @Test func nilLocationAppliesForInTransit() async throws {
        let database = try GameDatabase.bootstrap()
        try await seed(database, updatedAt: Date(timeIntervalSince1970: 1_000))

        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 2_000))
        } operation: {
            let applied = await Reconciler().applyEventFields(
                deviceCode: "SHIP", location: nil,
                eventTime: Date(timeIntervalSince1970: 1_005)
            )
            #expect(applied)
        }

        let device = try await row(database)
        #expect(device?.location == nil)
        #expect(device?.locationName == nil)
    }

    /// An unchanged location keeps its display name (nothing to invalidate).
    @Test func unchangedLocationKeepsDisplayName() async throws {
        let database = try GameDatabase.bootstrap()
        try await seed(database, updatedAt: Date(timeIntervalSince1970: 1_000))

        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 2_000))
        } operation: {
            _ = await Reconciler().applyEventFields(
                deviceCode: "SHIP", location: "TENEGSHE-3",
                eventTime: Date(timeIntervalSince1970: 1_010)
            )
        }

        let device = try await row(database)
        #expect(device?.location == "TENEGSHE-3")
        #expect(device?.locationName == "Tenegshe III")
        #expect(device?.updatedAt == Date(timeIntervalSince1970: 1_010))
    }

    /// An unknown device is a no-op — events can't create fleet rows.
    @Test func unknownDeviceIsANoOp() async throws {
        let database = try GameDatabase.bootstrap()

        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 2_000))
        } operation: {
            let applied = await Reconciler().applyEventFields(
                deviceCode: "GHOST", location: "SOMEWHERE-1",
                eventTime: Date(timeIntervalSince1970: 1_000)
            )
            #expect(!applied)
        }

        let device = try await row(database, "GHOST")
        #expect(device == nil)
    }

    /// An applied event's clock advance also blocks an *earlier-issued* read
    /// that lands later — the same LWW rule reads follow among themselves.
    @Test func appliedEventBlocksEarlierIssuedRead() async throws {
        let database = try GameDatabase.bootstrap()
        try await seed(database, updatedAt: Date(timeIntervalSince1970: 1_000))

        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 2_000))
            $0.uuid = .incrementing
        } operation: {
            _ = await Reconciler().applyEventFields(
                deviceCode: "SHIP", location: "TENEGSHE-7-L4",
                eventTime: Date(timeIntervalSince1970: 1_010)
            )
            // A read issued at t=1005 (pre-event) resolves late with the old
            // location: ingest must drop it.
            var lateSnapshot = try #require(await row(database))
            lateSnapshot.location = "TENEGSHE-3"
            lateSnapshot.updatedAt = Date(timeIntervalSince1970: 1_005)
            await Reconciler().ingest(lateSnapshot)
        }

        let device = try await row(database)
        #expect(device?.location == "TENEGSHE-7-L4")
    }
}

/// Stowage folded straight out of the event, the same way location already was.
///
/// This is the free half of the Survey Run staleness fix: `stowed_in_device_code`
/// is what every "is this vessel staged?" question reads, and its only repair
/// path used to be a `.low` confirm-read the budget floor may defer for minutes.
/// Both stowage events name the far end of the link, so the column now settles
/// from the event itself — at zero read cost and immune to budget pressure.
@Suite struct ReconcilerStowApplicationTests {

    private func seed(
        _ database: any DatabaseWriter,
        code: String = "AMI1",
        stowedIn: String?,
        updatedAt: Date
    ) async throws {
        let device = Device(
            deviceCode: code, deviceType: "ami_survey_controller", replicantCode: "R1",
            status: "idle", location: nil, locationName: nil, operationalCapacity: 100,
            queueSize: 0, stowedInDeviceCode: stowedIn, controllerDeviceCode: nil,
            attachedToDeviceCode: nil, createdAt: Date(timeIntervalSince1970: 0),
            availableCommands: [], features: [], tags: [], detail: .object([:]),
            updatedAt: updatedAt, firstSeenAt: updatedAt
        )
        try await database.write { db in try Device.upsert { device }.execute(db) }
    }

    private func row(_ database: any DatabaseWriter, _ code: String = "AMI1") async throws -> Device? {
        try await database.read { db in
            try Device.where { $0.deviceCode.eq(code) }.fetchOne(db)
        }
    }

    /// The exact repair the stalled run needed: a controller that had been
    /// deployed is recorded as back aboard the moment the event says so.
    @Test func stowedEventRecordsTheCarrier() async throws {
        let database = try GameDatabase.bootstrap()
        try await seed(database, stowedIn: nil, updatedAt: Date(timeIntervalSince1970: 1_000))

        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 2_000))
        } operation: {
            let applied = await Reconciler().applyEventFields(
                deviceCode: "AMI1", location: nil, stow: .stowed(inDeviceCode: "VES1"),
                eventTime: Date(timeIntervalSince1970: 1_010)
            )
            #expect(applied)
        }

        let device = try await row(database)
        #expect(device?.stowedInDeviceCode == "VES1")
    }

    /// Deploying clears the column — the far half of the same link.
    @Test func deployedEventClearsTheCarrier() async throws {
        let database = try GameDatabase.bootstrap()
        try await seed(database, stowedIn: "VES1", updatedAt: Date(timeIntervalSince1970: 1_000))

        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 2_000))
        } operation: {
            _ = await Reconciler().applyEventFields(
                deviceCode: "AMI1", location: "SOL-3", stow: .deployed,
                eventTime: Date(timeIntervalSince1970: 1_010)
            )
        }

        let device = try await row(database)
        #expect(device?.stowedInDeviceCode == nil)
    }

    /// An event with no stowage opinion leaves the column ALONE. The important
    /// negative: most device events say nothing about containment, and reading
    /// their silence as "not stowed" would unstage a perfectly staged vessel on
    /// every unrelated event that arrived.
    @Test func anEventWithNoStowClaimLeavesTheColumnAlone() async throws {
        let database = try GameDatabase.bootstrap()
        try await seed(database, stowedIn: "VES1", updatedAt: Date(timeIntervalSince1970: 1_000))

        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 2_000))
        } operation: {
            _ = await Reconciler().applyEventFields(
                deviceCode: "AMI1", location: nil, eventTime: Date(timeIntervalSince1970: 1_010)
            )
        }

        let device = try await row(database)
        #expect(device?.stowedInDeviceCode == "VES1")
    }

    /// Stowage obeys the same event-time guard as everything else: a replayed
    /// deploy from before the row's clock can't un-stow a re-stowed controller.
    @Test func staleStowEventIsDropped() async throws {
        let database = try GameDatabase.bootstrap()
        try await seed(database, stowedIn: "VES1", updatedAt: Date(timeIntervalSince1970: 1_000))

        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 2_000))
        } operation: {
            let applied = await Reconciler().applyEventFields(
                deviceCode: "AMI1", location: "SOL-3", stow: .deployed,
                eventTime: Date(timeIntervalSince1970: 990)
            )
            #expect(!applied)
        }

        let device = try await row(database)
        #expect(device?.stowedInDeviceCode == "VES1")
    }
}
