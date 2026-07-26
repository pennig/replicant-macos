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

    /// Machines come from `MissionRegistry` — the single registration point
    /// resolution also consults. With no machine registered for a kind the
    /// engine leaves those rows completely alone, so a `relayRun` directive is
    /// inert rather than mishandled until Stage 5.
    public static func makeLive(
        machines: [any MissionStepMachine] = MissionRegistry.machines
    ) -> DirectiveEngine {
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

        var action = machine.nextAction(directive: directive, world: world)
        if case let .refreshDevices(deviceCodes, thenStall) = action {
            action = await resolveRefresh(
                deviceCodes: deviceCodes, thenStall: thenStall,
                directive: directive, machine: machine
            )
        }
        let stillRunnable = await DirectiveExecutor.apply(action, to: directive, machine: machine)
        if !stillRunnable {
            // The row is no longer `.running`, so the supervisor would retire
            // this executor within a tick anyway; dropping it here stops it
            // spending one more evaluation first.
            executors[directiveID]?.cancel()
            executors[directiveID] = nil
        }
    }

    /// Spend authoritative reads on a mission's `.refreshDevices` request, then
    /// ask it once more against the fresh world.
    ///
    /// The re-ask is what makes the action worth having: the mission gets to
    /// distinguish "genuinely not staged" from "our rows were stale", which a
    /// `WorldSnapshot` alone cannot express. It happens here rather than in
    /// `DirectiveExecutor` because it needs a second snapshot read and a second
    /// call into the machine — the executor's job is applying ONE decided action
    /// to the database, and threading re-evaluation through it would blur that.
    ///
    /// Bounded by construction: a second `.refreshDevices` becomes the carried
    /// stall, so an evaluation issues at most one refresh round no matter what
    /// the machine says, and a genuinely unstaged vessel still surfaces to the
    /// user on this same tick.
    private func resolveRefresh(
        deviceCodes: [String],
        thenStall reason: DirectiveAttentionReason,
        directive: Directive,
        machine: any MissionStepMachine
    ) async -> MissionAction {
        @Dependency(\.deviceRefresher) var deviceRefresher
        @Dependency(\.defaultDatabase) var database
        @Dependency(\.date) var date

        // `.high` deliberately: the TTL and the read-budget floor exist to keep
        // background chatter cheap, and this is the opposite of background — the
        // alternative to these reads is a run that stops dead until a human
        // notices. `seen` keeps the fan-out to one read per device.
        var seen = Set<String>()
        for code in deviceCodes where seen.insert(code).inserted {
            guard let device = await deviceRefresher.refresh(code, .high) else { continue }
            // Containment is two-ended. The carrier's fresh row names who is
            // aboard, but the staging checks read each CHILD's stow column, so
            // refreshing the vessel alone would leave the very rows the answer
            // depends on exactly as stale as they were.
            for stowed in device.stowedDeviceCodes where seen.insert(stowed).inserted {
                _ = await deviceRefresher.refresh(stowed, .high)
            }
        }
        logger.info("directive \(directive.id, privacy: .public): refreshed \(seen.count) device(s) before \(reason.rawValue, privacy: .public)")

        let fresh: WorldSnapshot
        do {
            fresh = try await WorldSnapshot.read(from: database, now: date.now, directive: directive)
        } catch {
            // The reads may well have landed; we just can't see them. Surfacing
            // the stall is the honest outcome — the user's Retry now re-reads.
            logger.error("world snapshot after refresh failed: \(error)")
            return .stall(reason)
        }

        let action = machine.nextAction(directive: directive, world: fresh)
        if case .refreshDevices = action {
            logger.notice("directive \(directive.id, privacy: .public): fresh reads confirm \(reason.rawValue, privacy: .public)")
            return .stall(reason)
        }
        return action
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
