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
import ComposableArchitecture
import Foundation
import GameModels
import GameServices
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
    private var pipeline: EventPipeline?
    private var consumeTask: Task<Void, Never>?

    init(router: EventRouter, scheduler: DeadlineScheduler) {
        self.router = router
        self.scheduler = scheduler
    }

    func start() {
        guard consumeTask == nil else {
            logger.debug("start ignored — already running")
            return
        }
        @Dependency(\.gameClient) var gameClient
        @Dependency(\.keychain) var keychain
        logger.info("starting — native event stream")

        // Arm the deadline backstop for any already-open operations.
        Task { await scheduler.start() }

        // The SSE stream authenticates with the session bearer token, read fresh
        // per (re)connect from the Keychain — the same source `GameClient` uses.
        let streamClient = EventStreamClient.live(
            token: { keychain.load(KeychainClient.apiKeyAccount) }
        )
        // Catch-up pull reads share the app's rate-limit budget via gameClient's client.
        let pipeline = EventPipeline(streamClient: streamClient, client: gameClient())
        self.pipeline = pipeline

        let router = self.router
        consumeTask = Task {
            let stream = await pipeline.start()
            // Catch-up (§5.3): reconstruct recent state from the authoritative
            // account-wide event log on every (re)start, covering a stale cursor.
            // Catch-up events flow through the same stream → routes, deduped by
            // stream id. Spawned after `start()` so the stream's continuation is
            // live first. Feature channels own their own tier-2 as
            // `EventRoute.gapRepair` (e.g. the messages route re-reads the REST
            // inbox), so run every route's gapRepair here too.
            Task { await GameSyncEngine.catchUpIfStale(pipeline) }
            Task { await router.runGapRepair() }
            for await event in stream {
                await router.dispatch(event)
            }
        }
    }

    /// Run the account-wide catch-up pull only when the persisted cursor is stale
    /// (or absent). A fresh cursor means the stream's replay-from-cursor already
    /// recovers recent history on connect, so the pull would be redundant reads on
    /// every relaunch/wake. `freshWindow` is generous: a needless walk only costs
    /// a few reads (dedup absorbs them), whereas skipping a real gap loses events,
    /// so we err toward walking.
    static func catchUpIfStale(_ pipeline: EventPipeline, freshWindow: TimeInterval = 15 * 60) async {
        @Dependency(\.date) var date
        if let last = await pipeline.lastCursorDate(), date.now.timeIntervalSince(last) < freshWindow {
            logger.info("catch-up skipped — cursor fresh (\(Int(date.now.timeIntervalSince(last)))s old); stream replay covers it")
            return
        }
        let recovered = (try? await pipeline.catchUp()) ?? 0
        logger.info("catch-up: recovered \(recovered) event(s)")
    }

    func stop() async {
        logger.info("stopping")
        consumeTask?.cancel()
        consumeTask = nil
        await pipeline?.stop()
        pipeline = nil
        await scheduler.stop()
    }
}

// MARK: - Built-in routes (shared-infrastructure tables)

extension GameSync {
    /// Every game event naming a device is treated as an invalidation signal —
    /// confirm-read the authoritative snapshot and reconcile it under the
    /// event-time guard. Matches `.all` (it parses no device fields out of the
    /// event, so it's robust to evolving payloads); message/bobnet events simply
    /// carry no device code and no-op here.
    static func deviceRoute(reconciler: Reconciler) -> EventRoute {
        EventRoute(id: "device.event", match: .all) { event in
            @Dependency(\.deviceRefresher) var deviceRefresher
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
            // NOTE: `new_device_code` is the pre-migration payload key; the loud
            // unhandled-event log will surface the real key if the new stream
            // differs, at which point this becomes a one-line edit.
            if event.event == "print.completed",
               let newCode = event.payload?["new_device_code"]?.stringValue,
               !newCode.isEmpty {
                _ = await deviceRefresher.refresh(newCode, .high)
            }
            // Then refresh the device row via the poll coordinator. When the event
            // just closed an operation, read authoritatively (high priority): the
            // device's now-finished activity block (e.g. an arrived `travel` block)
            // must clear from its snapshot promptly, or the UI keeps rendering the
            // completed activity — a low-priority read can be TTL-suppressed and
            // leave a travel bar stuck on "Arriving…" until a later poll. Otherwise
            // it's a plain invalidation: a low-priority trigger that coalesces,
            // respects the TTL, and defers under read-budget pressure.
            guard let code = event.deviceCode, !code.isEmpty else { return }
            _ = await deviceRefresher.refresh(code, completedOp ? .high : .low)
        }
    }

    /// Relay-liveness events (`relay.activated` / deactivation) change the FTL mesh
    /// without changing the relay device roster — the device stays put, only its
    /// status flips — so the star map's roster-change trigger can't see them, and
    /// neither can any confirm-read of the device row (the mesh is edges between
    /// relays, not a device field). Rebuild and persist the mesh whenever any
    /// `relay.*` event arrives, independent of whether the map is on screen.
    static func ftlMeshRoute() -> EventRoute {
        EventRoute(id: "ftl.mesh", match: .category("relay")) { event in
            @Dependency(\.ftlMeshRefresher) var ftlMeshRefresher
            logger.debug("ftl mesh: \(event.event, privacy: .public) → rebuild")
            await ftlMeshRefresher.refresh()
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
    /// directly, and other features don't touch the relay.
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
