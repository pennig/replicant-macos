//
//  DirectiveEngine.swift
//  Replicould — DirectiveEngine
//
//  One serial executor per RUNNING custom directive, off the event-dispatch hot
//  path (directives design spec §6). Built-in directives get no executor — the
//  server runs them.
//
//  Evaluation is clock-driven rather than event-driven on purpose: an
//  evaluation is a local SQLite read plus a pure function, and it only touches
//  the network when the mission actually wants a command. That buys replay
//  immunity for free (the engine never sees an event, so it cannot be spooked
//  by its own command echo) and makes every test deterministic under
//  `TestClock` — with no observation plumbing to get wrong.
//
//  Lifecycle is owned by the composition root: started with the sync engine on
//  login, and stopped BEFORE the directive tables are wiped on logout.
//

import Dependencies
import Foundation
import GameModels
import GameServices
import OSLog
import SQLiteData

private let logger = Logger(subsystem: "name.pennig.replicould", category: "DirectiveEngine")

public struct DirectiveEngine: Sendable {
    /// Begin supervising running directives. Idempotent.
    public var start: @Sendable () async -> Void
    /// Cancel the supervisor and every executor. Must complete before the
    /// directive tables are wiped.
    public var stop: @Sendable () async -> Void

    public init(
        start: @escaping @Sendable () async -> Void,
        stop: @escaping @Sendable () async -> Void
    ) {
        self.start = start
        self.stop = stop
    }

    /// `machines` is EMPTY in this stage — Survey Run lands in Stage 4, Relay
    /// Run in Stage 5. With no machine registered for a kind the engine leaves
    /// the row completely alone, so starting it today is a no-op on real data.
    public static func makeLive(machines: [any MissionStepMachine] = []) -> DirectiveEngine {
        let core = DirectiveEngineCore(machines: machines, tick: .seconds(5))
        return DirectiveEngine(
            start: { await core.start() },
            stop: { await core.stop() }
        )
    }
}

actor DirectiveEngineCore {
    private let machines: [DirectiveKind: any MissionStepMachine]
    private let tick: Duration
    private var supervisor: Task<Void, Never>?
    private var executors: [String: Task<Void, Never>] = [:]

    /// Test seam: how many executors are alive.
    var executorCount: Int { executors.count }

    init(machines: [any MissionStepMachine], tick: Duration) {
        self.machines = Dictionary(machines.map { ($0.kind, $0) }, uniquingKeysWith: { first, _ in first })
        self.tick = tick
    }

    /// Claims `supervisor` before any suspension, so a concurrent `start()`
    /// can't double-supervise and a `stop()` can't interleave between the guard
    /// and the claim (the `GameSyncEngine.start()` shape).
    func start() {
        guard supervisor == nil else {
            logger.debug("start ignored — already running")
            return
        }
        logger.info("starting — \(self.machines.count) mission machine(s) registered")
        @Dependency(\.continuousClock) var clock
        let tick = self.tick
        supervisor = Task { [weak self] in
            while !Task.isCancelled {
                await self?.reconcileExecutors()
                try? await clock.sleep(for: tick)
            }
        }
    }

    func stop() {
        logger.info("stopping")
        supervisor?.cancel()
        supervisor = nil
        for (_, task) in executors { task.cancel() }
        executors.removeAll()
    }

    /// Spawn an executor for each running directive that lacks one, and retire
    /// executors whose directive is no longer running.
    func reconcileExecutors() async {
        @Dependency(\.defaultDatabase) var database
        let running: [Directive]
        do {
            running = try await database.read { db in
                try Directive.where { $0.status.eq(DirectiveStatus.running) }.fetchAll(db)
            }
        } catch {
            logger.error("supervisor read failed: \(error)")
            return
        }
        // A stop() may have interleaved across the read above — never resurrect
        // executors for a torn-down engine.
        guard supervisor != nil, !Task.isCancelled else { return }

        let runningIDs = Set(running.map(\.id))
        for (id, task) in executors where !runningIDs.contains(id) {
            task.cancel()
            executors[id] = nil
        }
        for directive in running where executors[directive.id] == nil {
            executors[directive.id] = makeExecutor(directiveID: directive.id)
        }
    }

    private func makeExecutor(directiveID: String) -> Task<Void, Never> {
        @Dependency(\.continuousClock) var clock
        let tick = self.tick
        return Task { [weak self] in
            while !Task.isCancelled {
                await self?.evaluateOnce(directiveID: directiveID)
                try? await clock.sleep(for: tick)
            }
        }
    }

    /// One evaluation: re-read the row (it may have changed under us), ask the
    /// machine for a single action, apply it. Re-reading every time is what
    /// makes the directive row the checkpoint a relaunch resumes from (spec
    /// §11), rather than any in-memory state that a restart would lose.
    func evaluateOnce(directiveID: String) async {
        @Dependency(\.defaultDatabase) var database
        @Dependency(\.date) var date

        let directive: Directive?
        do {
            directive = try await database.read { db in
                try Directive.where { $0.id.eq(directiveID) }.fetchOne(db)
            }
        } catch {
            logger.error("executor read failed for \(directiveID, privacy: .public): \(error)")
            return
        }
        // Only a RUNNING directive is advanced. A stall or a pause is the
        // user's to resolve — a tick must never resume one behind their back.
        guard let directive, directive.status == .running else { return }
        guard let machine = machines[directive.kind] else {
            // Expected in Stage 3 for every real directive: no machines ship
            // until Stage 4. Leave the row entirely alone.
            logger.debug("no machine for \(directive.kind.rawValue, privacy: .public) — directive \(directiveID, privacy: .public) left alone")
            return
        }

        let world: WorldSnapshot
        do {
            world = try await WorldSnapshot.read(from: database, now: date.now, directive: directive)
        } catch {
            logger.error("world snapshot failed: \(error)")
            return
        }

        let action = machine.nextAction(directive: directive, world: world)
        let stillRunnable = await DirectiveExecutor.apply(action, to: directive, machine: machine)
        if !stillRunnable {
            // The row is no longer `.running`, so the supervisor would retire
            // this executor within a tick anyway; dropping it here stops it
            // spending one more evaluation first.
            executors[directiveID]?.cancel()
            executors[directiveID] = nil
        }
    }
}

// MARK: - Dependency

extension DirectiveEngine: DependencyKey {
    public static let liveValue = DirectiveEngine.makeLive()
}

extension DirectiveEngine: TestDependencyKey {
    /// Inert: engine tests drive `DirectiveEngineCore` directly, and no feature
    /// should be starting the engine.
    public static let testValue = DirectiveEngine(start: {}, stop: {})
}

extension DependencyValues {
    public var directiveEngine: DirectiveEngine {
        get { self[DirectiveEngine.self] }
        set { self[DirectiveEngine.self] = newValue }
    }
}
