//
//  GameSync.swift
//  Replicould — GameSync
//
//  The app's single long-lived ingestion service: the sole consumer of the
//  account-wide relay and the one place external change enters the app. It owns
//  the `EventPipeline` + `RelayClient` lifecycle and a registry of `RelayRoute`s.
//  Features stay pure SQLite observers; the composition root registers routes
//  that map each relay `type` onto a feature table (see IMPLEMENTATION_PLAN §2).
//
//  Exposed as `@Dependency(\.gameSync)`. Registration is synchronous (like
//  `AccountManager.registerHandler`); start/stop are driven from the session
//  lifecycle. Re-registering the same route `id` replaces it.
//

import API
import ComposableArchitecture
import DependencyClients
import Foundation
import SQLiteData

public struct GameSync: Sendable {
    /// Register a route for a relay event `type`. Synchronous and immediate, so
    /// routes registered at app launch are in place before `start()` runs.
    public var registerRoute: @Sendable (RelayRoute) -> Void

    /// Begin consuming the relay and dispatching events to routes. Idempotent —
    /// a second call while already running is a no-op (so a restored-session
    /// launch start and a later login start can't double-connect).
    public var start: @Sendable () async -> Void

    /// Stop consuming the relay and tear the pipeline down. The persisted cursor
    /// survives, so a later `start()` resumes where this left off.
    public var stop: @Sendable () async -> Void

    public init(
        registerRoute: @escaping @Sendable (RelayRoute) -> Void,
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
    /// Build a live service backed by a fresh route registry and relay engine.
    /// The process shares one instance via `liveValue` (mirroring `GameClient`'s
    /// single governor and `AccountManager`'s single registry).
    public static func makeLive(configuration: RelayConfiguration = .live) -> GameSync {
        // One registry per service, shared between the (synchronous) registration
        // closure and the engine that reads it on every dispatch.
        let routes = LockIsolated<[RelayRoute]>([])

        // Built-in routes for the shared-infrastructure tables `GameSync` owns
        // (Device / BobnetMessage live in DependencyClients, not a feature), so
        // they're wired here rather than from the app. Feature-specific routes
        // (e.g. Messages) are still registered by the composition root.
        let reconciler = Reconciler()
        routes.withValue { current in
            current.append(Self.deviceRoute(reconciler: reconciler))
            current.append(Self.bobnetRoute())
        }

        let engine = GameSyncEngine(configuration: configuration, router: RelayRouter(routes: routes))

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

/// Owns the relay consumption lifecycle. An actor so start/stop can mutate the
/// pipeline + task safely from concurrent lifecycle callbacks.
actor GameSyncEngine {
    private let configuration: RelayConfiguration
    private let router: RelayRouter
    private var pipeline: EventPipeline?
    private var consumeTask: Task<Void, Never>?

    init(configuration: RelayConfiguration, router: RelayRouter) {
        self.configuration = configuration
        self.router = router
    }

    func start() {
        guard consumeTask == nil else { return }   // idempotent
        @Dependency(\.gameClient) var gameClient

        let relay = RelayClient(baseURL: configuration.baseURL, clientToken: configuration.clientToken)
        // Backfill reads share the app's rate-limit budget via gameClient's client.
        let pipeline = EventPipeline(relay: relay, client: gameClient())
        self.pipeline = pipeline

        let router = self.router
        consumeTask = Task {
            let stream = await pipeline.start()
            // Tier-2 gap repair (§5.3): reconstruct recent state from the
            // authoritative game log on every (re)start, covering the case where
            // the relay cursor fell outside Redis retention. Backfilled events
            // flow through the same stream → routes and are deduped against
            // tier-1 cursor replay by the pipeline's fingerprint set. Spawned
            // after `start()` so the stream's continuation is live first.
            Task { await GameSyncEngine.backfillAllReplicants(pipeline) }
            for await event in stream {
                await router.dispatch(event)
            }
        }
    }

    /// Walk the (small) replicant roster and backfill each from the game log.
    private static func backfillAllReplicants(_ pipeline: EventPipeline) async {
        @Dependency(\.defaultDatabase) var database
        let replicants = (try? await database.read { db in try Replicant.fetchAll(db) }) ?? []
        for replicant in replicants {
            _ = try? await pipeline.backfill(replicantCode: replicant.replicantCode, since: nil)
        }
    }

    func stop() async {
        consumeTask?.cancel()
        consumeTask = nil
        await pipeline?.stop()
        pipeline = nil
    }
}

// MARK: - Built-in routes (shared-infrastructure tables)

extension GameSync {
    /// `event`: a game-state event naming a device is treated as an invalidation
    /// signal — confirm-read the authoritative snapshot and reconcile it under
    /// the event-time guard. This is robust to evolving payloads (it parses no
    /// device fields out of the event). Phase 4 adds request coalescing, per-type
    /// TTL, and budget-aware deferral; Phase 2 does one read per device-naming
    /// event.
    static func deviceRoute(reconciler: Reconciler) -> RelayRoute {
        RelayRoute(id: "device.event", type: "event") { event in
            guard let code = event.deviceCode, !code.isEmpty else { return }
            @Dependency(\.devicesClient) var devicesClient
            guard let device = try? await devicesClient.read(code) else { return }
            await reconciler.ingest(device)
        }
    }

    /// `bobnet`: relay-only chat with no authoritative re-read source, so the
    /// route decodes the envelope's `messages[]` from the raw bytes and appends
    /// them (idempotent by message id), persisting history locally.
    static func bobnetRoute() -> RelayRoute {
        RelayRoute(id: "bobnet", type: "bobnet") { event in
            guard let data = event.rawData else { return }
            let messages = BobnetMessage.decode(from: data)
            guard !messages.isEmpty else { return }
            @Dependency(\.defaultDatabase) var database
            try? await database.write { db in
                for message in messages {
                    try BobnetMessage.upsert { message }.execute(db)
                }
            }
        }
    }
}

// MARK: - Dependency

extension GameSync: DependencyKey {
    public static let liveValue = GameSync.makeLive()
}

extension GameSync: TestDependencyKey {
    /// Inert by default: tests that exercise routing build a `RelayRouter`
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
