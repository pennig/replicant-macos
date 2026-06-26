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
            // Phase 2 will hook `onRelayError` into per-route tier-2 gap repair.
            let stream = await pipeline.start()
            for await event in stream {
                await router.dispatch(event)
            }
        }
    }

    func stop() async {
        consumeTask?.cancel()
        consumeTask = nil
        await pipeline?.stop()
        pipeline = nil
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
