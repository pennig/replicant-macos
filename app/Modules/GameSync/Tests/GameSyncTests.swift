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

/// Disambiguate from `Foundation.Operation`.
private typealias Operation = GameModels.Operation

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

// MARK: - Stream-death recovery

@Suite struct GameSyncEngineRestartTests {

    /// A stream that dies with `.staleGap` (wake after a long sleep) is restarted
    /// through the FULL sequenced start: a fresh pipeline whose catch-up pull
    /// runs again before the new connection opens (V3.3-S5/S6). The old code
    /// passed no `onStreamError`, so the engine idled on a dry stream forever.
    @Test func staleGapRestartsThroughCatchUp() async throws {
        let database = try GameDatabase.bootstrap()
        let clock = TestClock()
        let connects = LockIsolated(0)
        let catchUps = LockIsolated(0)
        let store = SharedCursorStore("100-0")   // epoch-ancient → catch-up runs every start

        // First connection dies immediately with a stale gap; the second stays open.
        let streamClient = EventStreamClient { _ in
            AsyncThrowingStream { continuation in
                let attempt = connects.withValue { $0 += 1; return $0 }
                if attempt == 1 {
                    continuation.finish(throwing: EventStreamError.staleGap(idleSeconds: 3_600))
                }
            }
        }
        let engine = GameSyncEngine(
            router: EventRouter(routes: LockIsolated([])),
            scheduler: DeadlineScheduler(reconciler: Reconciler()),
            makePipeline: {
                EventPipeline(
                    streamClient: streamClient,
                    fetchPage: { _ in
                        catchUps.withValue { $0 += 1 }
                        return GameEventsPage(events: [], nextCursor: nil)
                    },
                    cursorStore: store
                )
            }
        )

        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 2_000))
            $0.continuousClock = clock
        } operation: {
            await engine.start()

            // Drive the restart: the stale-gap handoff sleeps one beat on the
            // clock, then rebuilds the pipeline (catch-up → connect #2).
            for _ in 0..<200 where connects.value < 2 {
                await clock.advance(by: .seconds(1))
                await Task.yield()
            }
            await engine.stop()
        }

        #expect(connects.value == 2, "the dead stream must be replaced by a fresh connection")
        #expect(catchUps.value == 2, "each start runs the catch-up pull before connecting")
    }

    /// The engine arms the staleness drain loop with the session and stops it
    /// (forgetting marks) on `stop()` — the V3.5 drain lifecycle.
    @Test func engineArmsAndStopsStalenessDraining() async throws {
        let database = try GameDatabase.bootstrap()
        let clock = TestClock()
        let started = LockIsolated(0)
        let stopped = LockIsolated(0)
        let store = SharedCursorStore(nil)

        let streamClient = EventStreamClient { _ in
            AsyncThrowingStream { _ in }   // connects and stays open
        }
        let engine = GameSyncEngine(
            router: EventRouter(routes: LockIsolated([])),
            scheduler: DeadlineScheduler(reconciler: Reconciler()),
            makePipeline: {
                EventPipeline(
                    streamClient: streamClient,
                    fetchPage: { _ in GameEventsPage(events: [], nextCursor: nil) },
                    cursorStore: store
                )
            }
        )

        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 2_000))
            $0.continuousClock = clock
            $0.deviceStaleness.startDraining = { started.withValue { $0 += 1 } }
            $0.deviceStaleness.stopDraining = { stopped.withValue { $0 += 1 } }
        } operation: {
            await engine.start()
            for _ in 0..<2_000 where started.value < 1 { await Task.yield() }
            await engine.stop()
        }

        #expect(started.value == 1)
        #expect(stopped.value == 1)
    }

    /// After `stop()`, a pending stream-death restart must NOT resurrect the
    /// connection (logout tears the whole engine down).
    @Test func stopCancelsPendingRestart() async throws {
        let database = try GameDatabase.bootstrap()
        let clock = TestClock()
        let connects = LockIsolated(0)
        let store = SharedCursorStore(nil)   // cold: no catch-up, connect straight away

        let connected = AsyncStream.makeStream(of: Void.self)
        let streamClient = EventStreamClient { _ in
            AsyncThrowingStream { continuation in
                connects.withValue { $0 += 1 }
                connected.continuation.yield(())
                continuation.finish(throwing: EventStreamError.staleGap(idleSeconds: 3_600))
            }
        }
        let engine = GameSyncEngine(
            router: EventRouter(routes: LockIsolated([])),
            scheduler: DeadlineScheduler(reconciler: Reconciler()),
            makePipeline: {
                EventPipeline(
                    streamClient: streamClient,
                    fetchPage: { _ in GameEventsPage(events: [], nextCursor: nil) },
                    cursorStore: store
                )
            }
        )

        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 2_000))
            $0.continuousClock = clock
        } operation: {
            await engine.start()
            // Suspend until the connect actually lands — the consume task
            // crosses several suspension points (scheduler arm, staleness-drain
            // arm, pipeline start) first, and a yield-spin can starve under
            // full-suite parallel load (this test used to flake that way).
            var iterator = connected.stream.makeAsyncIterator()
            _ = await iterator.next()

            await engine.stop()                      // logout while a restart is pending
            await clock.advance(by: .seconds(120))   // the restart's sleep would fire here
            for _ in 0..<20 { await Task.yield() }   // let a leaked restart surface
        }

        #expect(connects.value == 1, "stop() must cancel the pending restart")
    }
}

/// Thread-safe in-memory cursor store for engine tests.
private final class SharedCursorStore: EventCursorStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    init(_ initial: String?) { self.value = initial }
    func load() -> String? { lock.withLock { value } }
    func save(_ cursor: String) { lock.withLock { value = cursor } }
    func clear() { lock.withLock { value = nil } }
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
    /// every print completion, bypassing the coordinator. The printer itself
    /// holds no open op here, so under the mark-mostly policy (V3.5) its row is
    /// *marked stale*, not read.
    @Test func printCompleteReadsNewDeviceWithoutFleetWalkOrPrune() async throws {
        let database = try GameDatabase.bootstrap()
        let now = Date(timeIntervalSince1970: 10_000)
        let refreshed = LockIsolated<[(code: String, priority: RefreshPriority)]>([])
        let marked = LockIsolated<[String]>([])

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
            $0.deviceStaleness.markStale = { code, _ in marked.withValue { $0.append(code) } }
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
            // The new device was read at high priority; the printer (no open op
            // closed) was marked stale rather than read.
            #expect(refreshed.value.contains { $0.code == "CLONE" && $0.priority == .high })
            #expect(!refreshed.value.contains { $0.code == "PRNT" })
            #expect(marked.value == ["PRNT"])
        }
    }

    /// Mark-mostly (V3.5): a live event that closes an operation pays one
    /// high-priority confirm-read; a thin live event and *any* catch-up event
    /// only mark the device stale — a launch replay costs zero immediate reads.
    @Test func deviceRouteMarksInsteadOfReadingExceptLiveOpClosings() async throws {
        let database = try GameDatabase.bootstrap()
        let now = Date(timeIntervalSince1970: 10_000)
        let refreshed = LockIsolated<[(code: String, priority: RefreshPriority)]>([])
        let marked = LockIsolated<[String]>([])

        try await withDependencies {
            $0.defaultDatabase = database
            $0.uuid = .incrementing
            $0.date = .constant(now)
            $0.deviceRefresher = DeviceRefreshClient { code, priority in
                refreshed.withValue { $0.append((code, priority)) }
                return nil
            }
            $0.deviceStaleness.markStale = { code, _ in marked.withValue { $0.append(code) } }
        } operation: {
            let route = GameSync.deviceRoute(reconciler: Reconciler())

            // The device exists locally (events can't create rows), stale.
            await Reconciler().ingest(device("SHIP", at: now))

            // 1) Thin live event → payload location applied + mark, no read.
            await route.apply(GameEventEnvelope(
                id: "1-0", category: "travel", event: "travel.cruising",
                deviceCode: "SHIP", location: "TENEGSHE-7-L4",
                createdAt: "2026-07-20T01:00:00Z"
            ))
            #expect(refreshed.value.isEmpty)
            #expect(marked.value == ["SHIP"])
            let moved = try await database.read { db in
                try Device.where { $0.deviceCode.eq("SHIP") }.fetchOne(db)
            }
            #expect(moved?.location == "TENEGSHE-7-L4", "the envelope's location applies at zero read cost")

            // 2) Live op-closing event → one high-priority read, no mark.
            try await database.write { db in
                try Operation.insert {
                    Operation(
                        id: "op-1", entityCode: "SHIP", kind: OperationKind.travel.rawValue,
                        status: .active, source: OperationSource.poll,
                        startedAt: now.addingTimeInterval(-60), completesAt: now,
                        lastConfirmedAt: now.addingTimeInterval(-60), detail: .object([:])
                    )
                }.execute(db)
            }
            await route.apply(GameEventEnvelope(
                id: "2-0", category: "travel", event: "travel.arrived",
                deviceCode: "SHIP", createdAt: "2026-07-20T01:01:00Z"
            ))
            #expect(refreshed.value.map(\.code) == ["SHIP"])
            #expect(refreshed.value.first?.priority == .high)

            // 3) Catch-up replay of an op-closing event → mark only, no read
            //    (the op is closed from the payload either way).
            try await database.write { db in
                try Operation.insert {
                    Operation(
                        id: "op-2", entityCode: "SHIP", kind: OperationKind.travel.rawValue,
                        status: .active, source: OperationSource.poll,
                        startedAt: now.addingTimeInterval(-30), completesAt: now,
                        lastConfirmedAt: now.addingTimeInterval(-30), detail: .object([:])
                    )
                }.execute(db)
            }
            await route.apply(GameEventEnvelope(
                id: "3-0", category: "travel", event: "travel.arrived",
                deviceCode: "SHIP", createdAt: "2026-07-20T01:02:00Z",
                provenance: .catchUp
            ))
            #expect(refreshed.value.count == 1)   // still just the one live read
            #expect(marked.value == ["SHIP", "SHIP"])

            let closed = try await database.read { db in
                try Operation.where { $0.status.eq(OperationStatus.completed) }.fetchCount(db)
            }
            #expect(closed == 2)   // both completions folded in from the payload
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

// MARK: - Stowage claims

/// Which events are allowed to move a device's `stowed_in_device_code`.
///
/// The column decides every "is this vessel staged?" question, so the mapping is
/// deliberately narrow: two events speak, everything else stays silent. Reading
/// silence as "not stowed" would unstage a staged vessel on any unrelated event.
@Suite("GameSync — stowage claims")
struct StowChangeTests {
    private func event(
        _ name: String,
        payload: [String: JSONValue]? = nil
    ) -> GameEventEnvelope {
        GameEventEnvelope(
            id: "1-0",
            category: String(name.split(separator: ".").first ?? ""),
            event: name,
            deviceCode: "AMI1",
            payload: payload,
            createdAt: "2026-06-25T09:42:06-05:00"
        )
    }

    @Test func stowedNamesTheCarrier() {
        #expect(
            GameSync.stowChange(for: event(
                "device.stowed", payload: ["stowed_in_device_code": .string("VES1")]
            )) == .stowed(inDeviceCode: "VES1")
        )
    }

    /// `device.deployed` needs no payload field at all — leaving the carrier IS
    /// the claim — so a renamed `deployed_from_device_code` can't silently break
    /// the clear.
    @Test func deployedClearsWithoutReadingThePayload() {
        #expect(GameSync.stowChange(for: event("device.deployed")) == .deployed)
    }

    /// A stow event we can't read the carrier out of makes NO claim rather than
    /// a guessed one; the staleness mark still owns that repair.
    @Test func stowedWithoutACarrierMakesNoClaim() {
        #expect(GameSync.stowChange(for: event("device.stowed")) == nil)
        #expect(
            GameSync.stowChange(for: event(
                "device.stowed", payload: ["stowed_in_device_code": .string("")]
            )) == nil
        )
    }

    /// Everything else — including the events that fly during a survey — stays
    /// out of the stowage column entirely.
    @Test(arguments: [
        "device.attached", "device.detached", "device.decommissioned",
        "device.changed_owner", "travel.arrived", "ami.withdrawn", "print.completed",
    ])
    func otherEventsMakeNoClaim(name: String) {
        #expect(GameSync.stowChange(for: event(name)) == nil)
    }
}
