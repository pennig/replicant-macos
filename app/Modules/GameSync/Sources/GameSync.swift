//
//  GameSync.swift
//  Replicould — GameSync
//
//  The app's single long-lived ingestion service: the sole consumer of the
//  native event stream and the one place external change enters the app. It owns
//  the `EventPipeline` + `EventStreamClient` lifecycle and a registry of
//  `EventRoute`s. Features stay pure SQLite observers; the composition root
//  registers routes that map the dotted event taxonomy onto feature tables (see
//  IMPLEMENTATION_PLAN §2).
//
//  Exposed as `@Dependency(\.gameSync)`. Registration is synchronous (like
//  `AccountManager.registerHandler`); start/stop are driven from the session
//  lifecycle. Re-registering the same route `id` replaces it.
//

import API
import Dependencies
import Foundation
import GameModels
import GameServices
import GameSession
import OSLog
import SQLiteData

private let logger = Logger(subsystem: "name.pennig.replicould", category: "GameSync")

public struct GameSync: Sendable {
    /// Register a route for a set of events. Synchronous and immediate, so routes
    /// registered at app launch are in place before `start()` runs.
    public var registerRoute: @Sendable (EventRoute) -> Void

    /// Begin consuming the event stream and dispatching to routes. Idempotent —
    /// a second call while already running is a no-op (so a restored-session
    /// launch start and a later login start can't double-connect).
    public var start: @Sendable () async -> Void

    /// Stop consuming the stream and tear the pipeline down. The persisted cursor
    /// survives, so a later `start()` resumes where this left off.
    public var stop: @Sendable () async -> Void

    public init(
        registerRoute: @escaping @Sendable (EventRoute) -> Void,
        start: @escaping @Sendable () async -> Void,
        stop: @escaping @Sendable () async -> Void
    ) {
        self.registerRoute = registerRoute
        self.start = start
        self.stop = stop
    }
}

// MARK: - Live implementation

extension GameSync {
    /// Build a live service backed by a fresh route registry and stream engine.
    /// The process shares one instance via `liveValue` (mirroring `GameClient`'s
    /// single governor and `AccountManager`'s single registry).
    public static func makeLive() -> GameSync {
        // One registry per service, shared between the (synchronous) registration
        // closure and the engine that reads it on every dispatch.
        let routes = LockIsolated<[EventRoute]>([])

        // Built-in routes for the shared-infrastructure tables `GameSync` owns
        // (Device / BobnetMessage live in GameServices, not a feature), so
        // they're wired here rather than from the app. Feature-specific routes
        // (e.g. Messages) are still registered by the composition root.
        let reconciler = Reconciler()
        let scheduler = DeadlineScheduler(reconciler: reconciler)
        routes.withValue { current in
            current.append(Self.deviceRoute(reconciler: reconciler))
            current.append(Self.bobnetRoute())
            // Registered after the device route so, when both fire for the same
            // event, the device confirm-read lands first and the roster the mesh
            // rebuild reads is current.
            current.append(Self.ftlMeshRoute())
        }

        let engine = GameSyncEngine(
            router: EventRouter(routes: routes),
            scheduler: scheduler
        )

        return GameSync(
            registerRoute: { route in
                routes.withValue { current in
                    current.removeAll { $0.id == route.id }
                    current.append(route)
                }
            },
            start: { await engine.start() },
            stop: { await engine.stop() }
        )
    }
}

/// Owns the event-stream consumption lifecycle. An actor so start/stop can mutate
/// the pipeline + task safely from concurrent lifecycle callbacks.
actor GameSyncEngine {
    private let router: EventRouter
    private let scheduler: DeadlineScheduler
    /// Builds a fresh pipeline per (re)start. Injectable so tests can drive the
    /// restart path with canned streams instead of a live SSE endpoint.
    private let makePipeline: @Sendable () -> EventPipeline
    private var pipeline: EventPipeline?
    private var consumeTask: Task<Void, Never>?
    /// Pending stream-death restart, retained so `stop()` can cancel it —
    /// logout must never be followed by a zombie reconnect.
    private var restartTask: Task<Void, Never>?
    /// The per-route tier-2 gap-repair fan-out, retained so `stop()` can cancel
    /// it — a quick logout mid-repair must not keep issuing reads on the old
    /// session's token.
    private var gapRepairTask: Task<Void, Never>?
    private var streamFailureCount = 0
    /// When the current pipeline was (re)started — the failure ladder resets
    /// only after a connection *survived* 10 minutes, so a capped ladder can't
    /// saw-tooth back to fast retries just because each capped sleep itself
    /// exceeds the quiet threshold.
    private var lastStartAt: Date?

    init(
        router: EventRouter,
        scheduler: DeadlineScheduler,
        makePipeline: @escaping @Sendable () -> EventPipeline = GameSyncEngine.livePipeline
    ) {
        self.router = router
        self.scheduler = scheduler
        self.makePipeline = makePipeline
    }

    /// The production pipeline: SSE authenticated with the session bearer token,
    /// read fresh per (re)connect from the Keychain — the same source
    /// `GameClient` uses; catch-up pull reads share the app's rate-limit budget
    /// via `gameClient`'s client.
    static func livePipeline() -> EventPipeline {
        @Dependency(\.gameClient) var gameClient
        @Dependency(\.keychain) var keychain
        let streamClient = EventStreamClient.live(
            token: { keychain.load(KeychainClient.apiKeyAccount) }
        )
        return EventPipeline(streamClient: streamClient, client: gameClient())
    }

    /// Synchronous on the actor by design: `consumeTask` is claimed before any
    /// suspension, so a concurrent `start()` can't double-connect and a
    /// `stop()` can never interleave between the guard and the claim (the
    /// zombie-engine-after-logout shape). All async work happens inside the
    /// claimed task, where `stop()`'s cancellation reaches it.
    func start() {
        guard consumeTask == nil else {
            logger.debug("start ignored — already running")
            return
        }
        logger.info("starting — native event stream")

        let pipeline = makePipeline()
        self.pipeline = pipeline

        let router = self.router
        let scheduler = self.scheduler
        @Dependency(\.date) var date
        let now = date.now
        lastStartAt = now
        let onStreamError: @Sendable (Error) -> Void = { [weak self] error in
            // Immutable rebinding: a `weak self` capture is a var, which the
            // nested @Sendable Task closure may not reference directly under
            // strict concurrency.
            let engine = self
            Task { await engine?.streamDied(error) }
        }
        @Dependency(\.deviceStaleness) var deviceStaleness
        consumeTask = Task { [weak self] in
            // Arm the deadline backstop for any already-open operations —
            // inside the claimed task, so a stop() that has already cancelled
            // it can't be followed by a zombie arming (`DeadlineScheduler
            // .start()` refuses a cancelled caller — as does the staleness
            // drain loop, armed the same way).
            await scheduler.start()
            await deviceStaleness.startDraining()
            // Catch-up (§5.3) runs *inside* `start()`, sequentially before the
            // SSE connection opens: the gap is emitted as `.catchUp` and the
            // stream then connects from the advanced cursor, so replayed history
            // can never arrive tagged `.stream` (V3.3-S1). The 15-minute window
            // errs toward walking — a needless pull costs a few deduped reads,
            // skipping a real gap loses events. Feature channels own their own
            // tier-2 as `EventRoute.gapRepair` (e.g. the messages route re-reads
            // the REST inbox); that fan-out is REST-side and order-independent,
            // so it runs concurrently with stream consumption.
            let stream = await pipeline.start(
                catchUpIfOlderThan: 15 * 60,
                now: now,
                onStreamError: onStreamError
            )
            await self?.spawnGapRepair()
            for await event in stream {
                await router.dispatch(event)
            }
        }
    }

    /// Run the per-route tier-2 gap repair as a retained task, so `stop()` can
    /// cancel a repair still in flight. Refuses a cancelled caller (this runs
    /// on the consume task, like `DeadlineScheduler.start()`): a stop() during
    /// the catch-up walk must not be followed by a fresh, uncancellable repair
    /// issuing reads on the old session's token. The `consumeTask != nil`
    /// check also keeps a superseded consume task (restart path) from
    /// respawning over its successor's repair.
    private func spawnGapRepair() {
        guard !Task.isCancelled, consumeTask != nil else { return }
        gapRepairTask?.cancel()
        gapRepairTask = Task { [router] in
            await router.runGapRepair()
        }
    }

    func stop() async {
        logger.info("stopping")
        restartTask?.cancel()
        restartTask = nil
        gapRepairTask?.cancel()
        gapRepairTask = nil
        consumeTask?.cancel()
        consumeTask = nil
        await pipeline?.stop()
        pipeline = nil
        await scheduler.stop()
        // Stop the staleness drain and forget the marks — they're
        // account-scoped, and a drain firing post-logout would read on the old
        // session's behalf.
        @Dependency(\.deviceStaleness) var deviceStaleness
        await deviceStaleness.stopDraining()
        streamFailureCount = 0
        lastStartAt = nil
    }

    /// The stream finished permanently — transient errors retry *inside*
    /// `EventStreamClient`; only auth failures and stale gaps land here. Tear
    /// down and re-run the full sequenced start (fresh Keychain token read,
    /// catch-up when stale, per-route gap repair), so a wake-from-sleep or a
    /// rotated token recovers without a relaunch (V3.3-S5/S6).
    private func streamDied(_ error: Error) {
        guard consumeTask != nil else { return }   // stopped — don't resurrect
        @Dependency(\.date) var date
        @Dependency(\.continuousClock) var clock

        let delay: Duration
        if case EventStreamError.staleGap(let idle) = error {
            // Not a failure — a planned handoff: the gap outgrew cursor-replay
            // trust, and the restart's catch-up pull is the repair. Go promptly
            // (one beat for post-wake networking to settle); no backoff ladder,
            // since a fresh pipeline can't re-trip the gap check for another
            // quiet window.
            logger.notice("event stream handed off after \(Int(idle))s gap — restarting through catch-up")
            delay = .seconds(1)
        } else {
            // Auth failure (or an unexpected terminal error): back off
            // exponentially — each retry re-reads the Keychain, so a re-issued
            // token is picked up; a genuinely dead session costs one connect
            // per backoff step, capped at 10 minutes.
            let now = date.now
            if let started = lastStartAt, now.timeIntervalSince(started) > 10 * 60 {
                streamFailureCount = 0   // the connection survived a while → fresh ladder
            }
            streamFailureCount += 1
            let seconds = min(5 * pow(2, Double(streamFailureCount - 1)), 600)
            logger.error("event stream died (\(error)) — restart #\(self.streamFailureCount) in \(Int(seconds))s")
            delay = .seconds(seconds)
        }

        restartTask?.cancel()
        restartTask = Task { [weak self] in
            try? await clock.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.restart()
        }
    }

    private func restart() async {
        guard consumeTask != nil else { return }   // logged out meanwhile
        consumeTask?.cancel()
        consumeTask = nil
        let old = pipeline
        pipeline = nil
        await old?.stop()
        // The await above is a real suspension: a logout (`stop()`, which
        // cancels restartTask) or a fresh lifecycle `start()` may have
        // interleaved — never resurrect over either.
        guard !Task.isCancelled, consumeTask == nil else { return }
        start()
    }
}

// MARK: - Built-in routes (shared-infrastructure tables)

extension GameSync {
    /// Every game event naming a device is treated as an invalidation signal.
    /// Matches `.all` (it parses no device fields out of the event, so it's
    /// robust to evolving payloads); message/bobnet events simply carry no
    /// device code and no-op here.
    ///
    /// Mark-mostly (V3.5): only a *live* op-closing event pays an immediate
    /// read. Everything else — thin/unknown events, and the entire catch-up
    /// replay — just marks the device stale in the `StalenessTracker`, where
    /// the mark is spent later (promptly for a visible device, on the slow
    /// drain loop for an op-holding one, on selection for the rest). An event
    /// burst therefore costs O(1) marks instead of O(events) reads, and a
    /// launch replay costs zero immediate reads (V3.4-B9).
    static func deviceRoute(reconciler: Reconciler) -> EventRoute {
        EventRoute(id: "device.event", match: .all) { event in
            @Dependency(\.deviceRefresher) var deviceRefresher
            @Dependency(\.deviceStaleness) var deviceStaleness
            // Completion events are truth for the action they close (§4.4): fold
            // the result into the device's open operation first (cheap, no read).
            let completedOp = await reconciler.applyOperationEvent(event)
            // A finished print job spawns a brand-new device (the printed clone)
            // whose code isn't in the local fleet yet — a single-device confirm-read
            // of the printer can't surface it. The event payload names it
            // (`new_device_code`), so read *just that device* — one coalesced,
            // high-priority read through the coordinator — rather than re-walking
            // the whole account list: at hundreds-to-1000+ devices a full paged
            // walk per print completion is the rate-limit shape §5.5 forbids (and
            // it bypassed the coordinator's coalescing/budget entirely). Pruning
            // stays with the explicit cold-load walk in the Devices feature — the
            // one place that knows the account's complete set (see `pruneDevices`).
            // This read is deliberately NOT gated on provenance: a mark can't
            // surface a device the fleet has never seen, so a replayed print
            // completion still costs its one clone read — the only way the clone
            // enters the fleet short of a full walk.
            // `new_device_code` was verified against the native stream on
            // 2026-07-28 (four real completions, three device types, both print
            // modes), so it is treated like any other payload key from here on.
            if event.event == "print.completed",
               let newCode = event.payload?["new_device_code"]?.stringValue,
               !newCode.isEmpty {
                _ = await deviceRefresher.refresh(newCode, .high)
            }
            guard let code = event.deviceCode, !code.isEmpty else { return }
            // Payload-complete field application (V3.5 row 2), for EVERY device
            // event: the envelope itself names the device's location after this
            // event — the arrival's destination, null while in transit or
            // stowed — so fold it in under the event-time guard and travel
            // legs / deploy/stow moves render immediately at zero read cost.
            // Applied on the op-closing path too: if its `.high` read fails,
            // the row at least holds the arrival's location. (Blindspot worth
            // knowing: the decoder can't tell `location: null` from an omitted
            // field, so a future device event that merely omits it would wipe
            // the row to "in transit" until the mark's read repairs it.)
            //
            // The two stowage events carry the containment link the same way, so
            // `stowed_in_device_code` settles here too rather than waiting on a
            // `.low` read the budget floor can defer indefinitely — the exact
            // gap that let a Survey Run stall on a controller it had already
            // been told was re-stowed.
            await reconciler.applyEventFields(
                deviceCode: code,
                location: event.location,
                stow: stowChange(for: event),
                eventTime: event.date
            )
            if completedOp, event.provenance == .stream {
                // A live event just closed an operation: the device's finished
                // activity block (e.g. an arrived `travel` block) must clear from
                // its snapshot promptly, or the UI keeps rendering the completed
                // activity — a mark could be deferred past that. One authoritative
                // high-priority read.
                _ = await deviceRefresher.refresh(code, .high)
            } else {
                // Remember, don't read: thin/unknown live events and all
                // catch-up replay. Catch-up especially — it can replay hundreds
                // of events at launch, and the cold-load gates plus the drain
                // loop already own that repair.
                await deviceStaleness.markStale(code, event.event)
            }
        }
    }

    /// The stowage claim a device event makes, or nil when it makes none.
    ///
    /// Only these two events speak to containment, and each names the far end in
    /// its payload (docs event catalogue, checked 2026-07-26). `device.deployed`
    /// needs no payload field at all — leaving the carrier IS the claim — so a
    /// renamed `deployed_from_device_code` can't silently break the clear, while
    /// `device.stowed` without a readable carrier code is treated as no claim
    /// rather than guessed at: the staleness mark still owns that repair.
    ///
    /// There is no `device.recalled`; an AMI recall reports `ami.withdrawn` and
    /// the per-device `device.stowed` events are what actually land here.
    static func stowChange(for event: GameEventEnvelope) -> StowChange? {
        switch event.event {
        case "device.stowed":
            guard let carrier = event.payload?["stowed_in_device_code"]?.stringValue,
                  !carrier.isEmpty
            else {
                logger.notice("⚠️ device.stowed WITHOUT stowed_in_device_code — stowage left to the staleness mark")
                return nil
            }
            return .stowed(inDeviceCode: carrier)
        case "device.deployed":
            return .deployed
        default:
            return nil
        }
    }

    /// Relay-liveness events (`relay.activated` / deactivation) change the FTL mesh
    /// without changing the relay device roster — the device stays put, only its
    /// status flips — so the star map's roster-change trigger can't see them, and
    /// neither can any confirm-read of the device row (the mesh is edges between
    /// relays, not a device field). Invalidate the mesh domain whenever any
    /// `relay.*` event arrives, independent of whether the map is on screen.
    ///
    /// Note the relay, then invalidate — never read inline (V3.4-B2), because
    /// `EventRouter.dispatch` awaits routes serially and any network read here
    /// head-of-line-blocks all event ingestion behind it. The domain's trailing
    /// debounce collapses a burst into one refresh after it quiets, and the note
    /// is what lets that refresh fold in a single relay instead of reading every
    /// one. An event with no device code cannot be attributed, so it forces the
    /// full read.
    static func ftlMeshRoute() -> EventRoute {
        EventRoute(id: "ftl.mesh", match: .category("relay")) { event in
            @Dependency(\.domainFreshness) var domainFreshness
            @Dependency(\.ftlMeshRefresher) var ftlMeshRefresher
            logger.debug("ftl mesh: \(event.event, privacy: .public) → invalidate")
            ftlMeshRefresher.noteRelayChanged(event.deviceCode)
            domainFreshness.invalidate(.ftlMesh)
        }
    }

    /// `bobnet`: chat with no authoritative re-read source, so the route persists
    /// each `bobnet.new_*` event's message locally (idempotent by message id).
    static func bobnetRoute() -> EventRoute {
        EventRoute(id: "bobnet", match: .category("bobnet")) { event in
            guard let payload = event.payload,
                  let message = BobnetMessage(eventPayload: payload, createdAt: event.date)
            else { return }
            @Dependency(\.defaultDatabase) var database
            try? await database.write { db in
                try BobnetMessage.upsert { message }.execute(db)
            }
            logger.debug("bobnet: appended message \(message.id, privacy: .public)")
        }
    }
}

// MARK: - Dependency

extension GameSync: DependencyKey {
    public static let liveValue = GameSync.makeLive()
}

extension GameSync: TestDependencyKey {
    /// Inert by default: tests that exercise routing build an `EventRouter`
    /// directly, and other features don't touch the stream.
    public static let testValue = GameSync(
        registerRoute: { _ in },
        start: {},
        stop: {}
    )
}

extension DependencyValues {
    public var gameSync: GameSync {
        get { self[GameSync.self] }
        set { self[GameSync.self] = newValue }
    }
}
