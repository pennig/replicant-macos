//
//  GameSyncTests.swift
//  Replicould — GameSync
//
//  Routing is the core of the ingestion service, so it's tested directly: an
//  `EventRouter` with canned routes must dispatch an event to every route whose
//  matcher accepts it (and to no others). (Pipeline/stream I/O is exercised
//  end-to-end in the app, not here.)
//

import API
import ComposableArchitecture
import Foundation
import GameDatabase
import GameModels
import GameServices
import SQLiteData
import Testing
import Utils
@testable import GameSync

@Suite struct EventRouterTests {

    /// Build a `GameEventEnvelope` with a given dotted name (category defaults to
    /// the name's prefix).
    private func event(
        _ name: String,
        deviceCode: String? = nil,
        payload: [String: JSONValue]? = nil
    ) -> GameEventEnvelope {
        GameEventEnvelope(
            id: "1-0",
            category: String(name.split(separator: ".").first ?? ""),
            event: name,
            deviceCode: deviceCode,
            payload: payload,
            createdAt: "2026-06-25T09:42:06-05:00"
        )
    }

    @Test func categoryMatcherRunsOnlyMatchingRoutes() async throws {
        let routes = LockIsolated<[EventRoute]>([])
        let router = EventRouter(routes: routes)
        let messageRan = LockIsolated(false)
        let miningRan = LockIsolated(false)

        routes.withValue {
            $0.append(EventRoute(id: "message", match: .category("message")) { _ in messageRan.setValue(true) })
            $0.append(EventRoute(id: "mining", match: .category("mining")) { _ in miningRan.setValue(true) })
        }

        await router.dispatch(event("message.new_", payload: ["title": .string("x")]))

        #expect(messageRan.value == true)
        #expect(miningRan.value == false)
    }

    @Test func eventAndPrefixMatchersSelectByDottedName() async throws {
        let routes = LockIsolated<[EventRoute]>([])
        let router = EventRouter(routes: routes)
        let exactRan = LockIsolated(false)
        let prefixRan = LockIsolated(false)
        let allRan = LockIsolated(0)

        routes.withValue {
            $0.append(EventRoute(id: "exact", match: .event("relay.activated")) { _ in exactRan.setValue(true) })
            $0.append(EventRoute(id: "prefix", match: .eventPrefix("travel.")) { _ in prefixRan.setValue(true) })
            $0.append(EventRoute(id: "all", match: .all) { _ in allRan.withValue { $0 += 1 } })
        }

        await router.dispatch(event("travel.departed", deviceCode: "D1"))
        #expect(exactRan.value == false)
        #expect(prefixRan.value == true)
        #expect(allRan.value == 1, "the .all route matches everything")

        await router.dispatch(event("relay.activated", deviceCode: "D2"))
        #expect(exactRan.value == true)
        #expect(allRan.value == 2)
    }

    /// `runGapRepair` invokes every route's tier-2 catch-up, and a route with the
    /// default no-op `gapRepair` is a harmless skip.
    @Test func runGapRepairInvokesEveryRoutesGapRepair() async throws {
        let routes = LockIsolated<[EventRoute]>([])
        let router = EventRouter(routes: routes)
        let ran = LockIsolated<[String]>([])

        routes.withValue {
            $0.append(EventRoute(id: "a", match: .all, apply: { _ in }, gapRepair: { ran.withValue { $0.append("a") } }))
            $0.append(EventRoute(id: "b", match: .category("message"), apply: { _ in }, gapRepair: { ran.withValue { $0.append("b") } }))
            $0.append(EventRoute(id: "c", match: .category("bobnet"), apply: { _ in }))   // default no-op gapRepair
        }

        await router.runGapRepair()

        #expect(Set(ran.value) == ["a", "b"])
    }
}

// MARK: - Reconciliation guard

@Suite struct ReconcilerTests {

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
        let database = try GameDatabase.bootstrap()
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
        let database = try GameDatabase.bootstrap()
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

// MARK: - Print-complete new-device read

@Suite struct PrintCompleteRouteTests {

    private func device(_ code: String, at instant: Date) -> Device {
        Device(
            deviceCode: code, deviceType: "mining_drone", replicantCode: "R1", status: "idle",
            location: nil, locationName: nil, operationalCapacity: 100, queueSize: 0,
            stowedInDeviceCode: nil, controllerDeviceCode: nil, attachedToDeviceCode: nil,
            createdAt: Date(timeIntervalSince1970: 0), availableCommands: [], features: [], tags: [],
            detail: .object([:]), updatedAt: instant, firstSeenAt: instant
        )
    }

    /// A finished print spawns a device whose code the local fleet has never seen.
    /// The route reads *just that new device* — named by the event's
    /// `new_device_code` — through the coordinator at high priority, with no
    /// full-fleet walk, and does not prune (pruning belongs to the explicit
    /// cold-load, §5.5). Regression: the old path re-walked `GET /v1/devices` on
    /// every print completion, bypassing the coordinator.
    @Test func printCompleteReadsNewDeviceWithoutFleetWalkOrPrune() async throws {
        let database = try GameDatabase.bootstrap()
        let now = Date(timeIntervalSince1970: 10_000)
        let refreshed = LockIsolated<[(code: String, priority: RefreshPriority)]>([])

        try await withDependencies {
            $0.defaultDatabase = database
            $0.uuid = .incrementing
            $0.date = .constant(now)
            // fetchAll must never be touched — a full walk is the regression.
            $0.devicesClient.fetchAll = { Issue.record("should not re-walk the fleet"); return [] }
            $0.deviceRefresher = DeviceRefreshClient { code, priority in
                refreshed.withValue { $0.append((code, priority)) }
                // Stand in for the coordinator's read+reconcile of the named device.
                guard code == "CLONE" else { return nil }
                await Reconciler().ingest(device("CLONE", at: now))
                return device("CLONE", at: now)
            }
        } operation: {
            // Printer + an unrelated device are already local.
            await Reconciler().ingest(device("PRNT", at: now))
            await Reconciler().ingest(device("GONE", at: now))

            let event = GameEventEnvelope(
                id: "1-0", category: "print", event: "print.completed",
                deviceCode: "PRNT",
                payload: ["new_device_code": .string("CLONE"), "device_type": .string("ftl_beacon")],
                createdAt: "2026-06-26T01:00:00Z"
            )
            await GameSync.deviceRoute(reconciler: Reconciler()).apply(event)

            let codes = try await database.read { db in
                try Device.select(\.deviceCode).fetchAll(db)
            }
            #expect(Set(codes) == ["PRNT", "GONE", "CLONE"])  // clone landed; nothing pruned
            // The new device was read at high priority; the printer row was too.
            #expect(refreshed.value.contains { $0.code == "CLONE" && $0.priority == .high })
            #expect(refreshed.value.contains { $0.code == "PRNT" })
        }
    }
}

// MARK: - Bobnet decoding

@Suite struct BobnetDecodeTests {
    @Test func decodesEventPayload() {
        let payload: [String: JSONValue] = [
            "id": .number(3421),
            "replicant_name": .string("Riker"),
            "replicant_code": .string("B3DDEDE7"),
            "current_star": .string("SOL"),
            "channel": .string("#general"),
            "message": .string("We have to move faster."),
        ]
        let message = BobnetMessage(eventPayload: payload, createdAt: Date(timeIntervalSince1970: 1_000))
        #expect(message?.id == 3421)
        #expect(message?.replicantName == "Riker")
        #expect(message?.replicantCode == "B3DDEDE7")
        #expect(message?.currentStar == "SOL")
        #expect(message?.channel == "#general")
        #expect(message?.message == "We have to move faster.")
        #expect(message?.time == Date(timeIntervalSince1970: 1_000))  // envelope createdAt fallback
    }

    @Test func payloadWithoutIDYieldsNil() {
        #expect(BobnetMessage(eventPayload: ["message": .string("hi")], createdAt: nil) == nil)
    }
}
