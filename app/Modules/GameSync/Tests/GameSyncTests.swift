//
//  GameSyncTests.swift
//  Replicould — GameSync
//
//  Routing is the core of the ingestion service, so it's tested directly: a
//  `RelayRouter` with canned routes must dispatch an event only to the route
//  whose `type` matches, and to every matching route. (Pipeline/relay I/O is
//  exercised end-to-end in the app, not here.)
//

import API
import ComposableArchitecture
import DependencyClients
import Foundation
import SQLiteData
import Testing
import Utils
@testable import GameSync

@Suite struct RelayRouterTests {

    /// Build a `UnifiedEvent` of a given top-level type from a relay payload.
    private func event(type: String) throws -> UnifiedEvent {
        let raw = #"{"type":"\#(type)","title":"x","body":"y","timestamp":"2026-06-25T09:42:06-05:00"}"#
        return try UnifiedEvent(relayEvent: RelayEvent(id: "1-0", raw: Data(raw.utf8)))
    }

    @Test func dispatchRunsOnlyTheMatchingRoute() async throws {
        let routes = LockIsolated<[RelayRoute]>([])
        let router = RelayRouter(routes: routes)
        let messageRan = LockIsolated(false)
        let eventRan = LockIsolated(false)

        routes.withValue {
            $0.append(RelayRoute(id: "message", type: "message") { _ in messageRan.setValue(true) })
            $0.append(RelayRoute(id: "event", type: "event") { _ in eventRan.setValue(true) })
        }

        await router.dispatch(try event(type: "message"))

        #expect(messageRan.value == true)
        #expect(eventRan.value == false)
    }

    @Test func dispatchRunsEveryRouteForTheSameType() async throws {
        let routes = LockIsolated<[RelayRoute]>([])
        let router = RelayRouter(routes: routes)
        let count = LockIsolated(0)

        routes.withValue {
            $0.append(RelayRoute(id: "a", type: "message") { _ in count.withValue { $0 += 1 } })
            $0.append(RelayRoute(id: "b", type: "message") { _ in count.withValue { $0 += 1 } })
        }

        await router.dispatch(try event(type: "message"))

        #expect(count.value == 2)
    }
}

// MARK: - Reconciliation guard

@Suite struct ReconcilerTests {

    private func makeDeviceDatabase() throws -> any DatabaseWriter {
        let database = try SQLiteData.defaultDatabase()
        var migrator = DatabaseMigrator()
        Device.registerMigrations(&migrator)
        try migrator.migrate(database)
        return database
    }

    private func device(_ code: String, status: String, at instant: Date) -> Device {
        Device(
            deviceCode: code, deviceType: "mining_drone", replicantCode: "R1", status: status,
            location: nil, locationName: nil, operationalCapacity: 100, queueSize: 0,
            stowedInDeviceCode: nil, controllerDeviceCode: nil, attachedToDeviceCode: nil,
            createdAt: Date(timeIntervalSince1970: 0), availableCommands: [], features: [], tags: [],
            detail: .object([:]), updatedAt: instant, firstSeenAt: instant
        )
    }

    /// A newer snapshot wins; a later-arriving older snapshot is dropped; the
    /// original `firstSeenAt` survives every upsert.
    @Test func newerWinsOlderDroppedAndFirstSeenPreserved() async throws {
        let database = try makeDeviceDatabase()
        let t1 = Date(timeIntervalSince1970: 1_000)
        let t2 = Date(timeIntervalSince1970: 2_000)

        try await withDependencies {
            $0.defaultDatabase = database
        } operation: {
            let reconciler = Reconciler()
            await reconciler.ingest(device("D1", status: "idle", at: t1))
            await reconciler.ingest(device("D1", status: "travelling", at: t2))
            // Out-of-order: a stale snapshot arrives after the newer one.
            await reconciler.ingest(device("D1", status: "STALE", at: t1))

            let stored = try await database.read { db in
                try Device.where { $0.deviceCode.eq("D1") }.fetchOne(db)
            }
            #expect(stored?.status == "travelling")   // newest event-time won
            #expect(stored?.updatedAt == t2)
            #expect(stored?.firstSeenAt == t1)         // provenance preserved
        }
    }

    /// Equal event-time still applies (guard is `>=`, last-writer-wins).
    @Test func equalEventTimeApplies() async throws {
        let database = try makeDeviceDatabase()
        let t = Date(timeIntervalSince1970: 5_000)

        try await withDependencies {
            $0.defaultDatabase = database
        } operation: {
            let reconciler = Reconciler()
            await reconciler.ingest(device("D2", status: "idle", at: t))
            await reconciler.ingest(device("D2", status: "mining", at: t))
            let stored = try await database.read { db in
                try Device.where { $0.deviceCode.eq("D2") }.fetchOne(db)
            }
            #expect(stored?.status == "mining")
        }
    }
}

// MARK: - Bobnet decoding

@Suite struct BobnetDecodeTests {
    @Test func decodesRelayEnvelopeMessages() {
        let raw = #"""
        {"type":"bobnet","messages":[{"id":3421,"replicant_name":"Riker","replicant_code":"B3DDEDE7","current_star":"SOL","channel":"#general","message":"We have to move faster.","time":"2026-06-25T10:09:33-05:00"}]}
        """#
        let messages = BobnetMessage.decode(from: Data(raw.utf8))
        #expect(messages.count == 1)
        let message = messages.first
        #expect(message?.id == 3421)
        #expect(message?.replicantName == "Riker")
        #expect(message?.replicantCode == "B3DDEDE7")
        #expect(message?.currentStar == "SOL")
        #expect(message?.channel == "#general")
        #expect(message?.message == "We have to move faster.")
    }

    @Test func malformedPayloadYieldsEmpty() {
        #expect(BobnetMessage.decode(from: Data("not json".utf8)).isEmpty)
        // An "event" envelope has no `messages` array.
        #expect(BobnetMessage.decode(from: Data(#"{"type":"event"}"#.utf8)).isEmpty)
    }
}
