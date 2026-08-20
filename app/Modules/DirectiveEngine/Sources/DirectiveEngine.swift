//
//  DirectiveEngine.swift
//  Replicould — DirectiveEngine
//
//  One serial executor per RUNNING custom directive, off the event-dispatch hot
//  path; built-in directives get none, since the server runs them. ONE
//  `WorldTick` read per tick feeds every executor and the brain; the network is
//  touched only when a mission wants a command, so the engine never sees its own
//  command echo. Started with the sync engine on login, stopped BEFORE the
//  tables are wiped.
//

import Dependencies
import Foundation
import GameModels
import GameServices
import OSLog
import Sharing
import SQLiteData
import UniverseModels

private let logger = Logger(subsystem: "name.pennig.replicould", category: "DirectiveEngine")
private let brainLogger = Logger(subsystem: "name.pennig.replicould", category: "Brain")

/// The engine's lifecycle, as two closures the composition root drives.
public struct DirectiveEngine: Sendable {
    /// Begin supervising running directives. Idempotent.
    public var start: @Sendable () async -> Void
    /// Cancel the supervisor and every executor. Must complete before the
    /// directive tables are wiped.
    public var stop: @Sendable () async -> Void

    /// `start` and `stop` are the implementations of the properties of the same
    /// name.
    public init(
        start: @escaping @Sendable () async -> Void,
        stop: @escaping @Sendable () async -> Void
    ) {
        self.start = start
        self.stop = stop
    }

    /// An engine driving `machines`, defaulting to `MissionRegistry` — the
    /// single registration point resolution also consults. A directive whose
    /// kind has no machine here is left completely alone, so it is inert rather
    /// than mishandled.
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

/// The engine's mutable half: the tick loop, one executor task per running
/// directive, and the resolvers for the actions a mission cannot apply by
/// itself.
actor DirectiveEngineCore {
    /// The registered machines, one per kind; a kind absent here is never run.
    private let machines: [DirectiveKind: any MissionStepMachine]
    /// The interval every loop in this actor sleeps for between iterations.
    private let tick: Duration
    /// The one loop, nil when stopped: one world read, then the executors, then
    /// the brain. Doubles as the "am I running?" flag `reconcileExecutors()`
    /// re-checks after a suspension.
    private var tickLoop: Task<Void, Never>?
    /// One evaluation loop per running directive, keyed by directive id.
    private var executors: [String: Task<Void, Never>] = [:]
    /// Where each executor waits for its tick. Buffering the NEWEST alone is
    /// what keeps a directive's evaluations serial: a tick arriving mid-
    /// evaluation replaces the pending one rather than starting a second.
    private var deliveries: [String: AsyncStream<WorldTick>.Continuation] = [:]

    /// Test seam: how many executors are alive.
    var executorCount: Int { executors.count }
    /// Test seam: how many times the brain has ticked, incremented in
    /// `tickBrain()`. The only way to prove the plan loop is wired to the clock
    /// rather than a dead field — the no-writes assertions elsewhere hold
    /// identically whether the loop ticked once or a hundred times.
    private(set) var brainTickCount = 0

    /// Register `machines` by kind (first wins on a duplicate) and run every
    /// loop at `tick`.
    init(machines: [any MissionStepMachine], tick: Duration) {
        self.machines = Dictionary(machines.map { ($0.kind, $0) }, uniquingKeysWith: { first, _ in first })
        self.tick = tick
    }

    /// Start the tick loop. Idempotent — `tickLoop` is claimed before any
    /// suspension, so a concurrent `start()` cannot double-supervise and a
    /// `stop()` cannot interleave between the guard and the claim.
    func start() {
        guard tickLoop == nil else {
            logger.debug("start ignored — already running")
            return
        }
        logger.info("starting — \(self.machines.count) mission machine(s) registered")
        brainLogger.info("starting — brain online")
        @Dependency(\.continuousClock) var clock
        let tick = self.tick
        tickLoop = Task { [weak self] in
            var generation: UInt64 = 0
            while !Task.isCancelled {
                generation &+= 1
                await self?.runTick(generation: generation)
                try? await clock.sleep(for: tick)
            }
        }
    }

    /// Cancel every loop and clear the why-view's feed. Must complete before the
    /// directive tables are wiped.
    func stop() {
        logger.info("stopping")
        brainLogger.info("stopping")
        tickLoop?.cancel()
        tickLoop = nil
        // Cleared here or the why-view shows the PREVIOUS account's data; it STAYS
        // cleared because `tickBrain()` re-checks cancellation before publishing.
        @Shared(.brainReport) var published: BrainReport?
        $published.withLock { $0 = nil }
        for (_, task) in executors { task.cancel() }
        executors.removeAll()
        for (_, delivery) in deliveries { delivery.finish() }
        deliveries.removeAll()
        idlePlanUntil.removeAll()
    }

    /// One tick: read the whole world once, reconcile the executor roster
    /// against it, hand every running directive that read, then let the brain
    /// decide against the same read.
    func runTick(generation: UInt64) async {
        @Dependency(\.defaultDatabase) var database
        @Dependency(\.date) var date

        let tick: WorldTick
        do {
            tick = try await WorldTick.read(from: database, now: date.now, generation: generation)
        } catch {
            logger.error("tick read failed: \(error)")
            return
        }
        // A stop() may have interleaved across the read above — never resurrect
        // executors for a torn-down engine.
        guard !Task.isCancelled else { return }

        reconcile(running: tick.running)
        for directive in tick.running {
            deliveries[directive.id]?.yield(tick)
        }
        await tickBrain(view: tick.view)
    }

    /// One brain tick: bridge `now` in via `@Dependency(\.date)`, ask `Brain` for a
    /// decision, publish it. The decision is REPORTED, not acted on — nothing here
    /// writes a row, and nothing here may, since a bespoke write at this layer sits
    /// outside the brain's audited enactment surface. This actor keeps no copy.
    ///
    /// **Cancellation is checked at both ends, and neither check is redundant.**
    /// The ENTRY check catches a tick that began after `stop()`; the EXIT check
    /// catches one suspended across `Brain.report()`, which would otherwise resume
    /// after the feed was cleared and republish the previous account's data. Both
    /// read `Task.isCancelled`, not `brain != nil` — this body runs inside the task
    /// `stop()` cancels, so the flag is exact where the field is not yet cleared.
    func tickBrain(view: WorldView? = nil) async {
        guard !Task.isCancelled else {
            brainLogger.debug("tick skipped — engine already stopped")
            return
        }
        brainTickCount += 1
        @Dependency(\.date) var date
        let report = await Brain(now: date.now).report(view: view)
        guard !Task.isCancelled else {
            brainLogger.debug("tick discarded — engine stopped mid-tick")
            return
        }
        @Shared(.brainReport) var published: BrainReport?
        $published.withLock { $0 = report }
        brainLogger.debug("tick: \(String(describing: report.decision), privacy: .public)")
    }

    /// Test seam: reconcile against a tick read for this call alone. The loop
    /// itself reconciles against the tick it already read.
    func reconcileExecutors() async {
        @Dependency(\.defaultDatabase) var database
        @Dependency(\.date) var date
        let tick: WorldTick
        do {
            tick = try await WorldTick.read(from: database, now: date.now, generation: 0)
        } catch {
            logger.error("supervisor read failed: \(error)")
            return
        }
        // A stop() may have interleaved across the read above — never resurrect
        // executors for a torn-down engine.
        guard tickLoop != nil, !Task.isCancelled else { return }
        reconcile(running: tick.running)
    }

    /// Spawn an executor for each running directive that lacks one, and retire
    /// executors whose directive has stopped running.
    private func reconcile(running: [Directive]) {
        let runningIDs = Set(running.map(\.id))
        for id in Array(executors.keys) where !runningIDs.contains(id) {
            retire(id)
        }
        for directive in running where executors[directive.id] == nil {
            executors[directive.id] = makeExecutor(directiveID: directive.id)
        }
    }

    /// Cancel `directiveID`'s executor and forget everything held for it.
    private func retire(_ directiveID: String) {
        executors[directiveID]?.cancel()
        executors[directiveID] = nil
        deliveries[directiveID]?.finish()
        deliveries[directiveID] = nil
        idlePlanUntil[directiveID] = nil
    }

    /// A task evaluating directive `directiveID` once per delivered tick until
    /// cancelled. One evaluation at a time: the next tick waits in the stream
    /// rather than starting a second run of the same directive.
    private func makeExecutor(directiveID: String) -> Task<Void, Never> {
        let (ticks, delivery) = AsyncStream<WorldTick>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        deliveries[directiveID] = delivery
        return Task { [weak self] in
            for await tick in ticks where !Task.isCancelled {
                await self?.evaluateOnce(directiveID: directiveID, tick: tick)
            }
        }
    }

    /// Test seam: one evaluation against a tick read for this call alone.
    func evaluateOnce(directiveID: String) async {
        @Dependency(\.defaultDatabase) var database
        @Dependency(\.date) var date
        do {
            let tick = try await WorldTick.read(
                from: database, now: date.now, generation: 0
            )
            await evaluateOnce(directiveID: directiveID, tick: tick)
        } catch {
            logger.error("executor read failed for \(directiveID, privacy: .public): \(error)")
        }
    }

    /// One evaluation of `directiveID`: the row and the world both come from
    /// `tick`'s single read, and the row as read at TICK TIME is the checkpoint
    /// a relaunch resumes from, never in-memory state a restart loses.
    func evaluateOnce(directiveID: String, tick: WorldTick) async {
        // Only a RUNNING directive is advanced. A stall or a pause is the
        // user's to resolve — a tick must never resume one behind their back.
        guard let directive = tick.running.first(where: { $0.id == directiveID }),
              directive.status == .running
        else { return }
        guard let machine = machines[directive.kind] else {
            // A kind with no registered machine is left entirely alone: the row
            // is inert, never partially advanced.
            logger.debug("no machine for \(directive.kind.rawValue, privacy: .public) — directive \(directiveID, privacy: .public) left alone")
            return
        }

        guard let world = tick.snapshot(for: directiveID) else { return }

        // Audit only, and deliberately BEFORE the machine runs: it appends
        // `.opCompleted` timeline rows for dispatched ops that have since closed,
        // and touches nothing the machine reads to decide. Running it first means a
        // tick that also advances the step still records why the previous one
        // ended. `world` is the pre-write snapshot, so these rows are invisible to
        // `nextAction` on this tick — mission behaviour is unchanged.
        await DirectiveExecutor.recordCompletedOps(for: directive, world: world)

        var action = machine.nextAction(directive: directive, world: world)
        // The row the action gets applied to. Only `.extendQueue` moves it off
        // the value read at the top of this method — it is the one resolver that
        // WRITES the row, so applying its result to the pre-write value would
        // roll its append back (see `Resolution`).
        var current = directive
        switch action {
        case let .refreshDevices(deviceCodes, thenStall):
            action = await resolveRefresh(
                deviceCodes: deviceCodes, thenStall: thenStall,
                directive: directive, machine: machine, paid: [.devices]
            )
        case let .refreshDevicesInSystem(designation, thenStall):
            action = await resolveSystemRefresh(
                designation: designation, thenStall: thenStall,
                directive: directive, machine: machine, paid: [.devicesInSystem]
            )
        case let .refreshFleet(tag, thenStall):
            action = await resolveFleetRefresh(
                tag: tag, thenStall: thenStall,
                directive: directive, machine: machine, paid: [.fleet]
            )
        case let .refreshFootprint(nextStep, thenStall):
            action = await resolveFootprintRefresh(
                nextStep: nextStep, thenStall: thenStall,
                directive: directive, machine: machine, paid: [.footprint]
            )
        case let .refreshEvents(thenStall):
            action = await resolveEventsRefresh(
                thenStall: thenStall,
                directive: directive, machine: machine, paid: [.events]
            )
        case let .completeEvent(location, designation, nextStep):
            action = await resolveEventCompletion(
                location: location, designation: designation,
                nextStep: nextStep, directive: directive
            )
        case let .extendQueue(centre):
            let resolution = await resolveExtendQueue(
                centre: centre, directive: directive, machine: machine
            )
            action = resolution.action
            current = resolution.directive
        default:
            break
        }
        let stillRunnable = await DirectiveExecutor.apply(action, to: current, machine: machine)
        if !stillRunnable {
            // The row has left `.running`, so the next tick would retire this
            // executor anyway; dropping it here stops one more evaluation first.
            retire(directiveID)
        }
    }

    /// A resolved `action` plus the `directive` row it must be applied to.
    ///
    /// Only `.extendQueue` needs the second half. The refresh resolvers re-ask
    /// with the SAME `Directive` value because a read cannot change the directive
    /// row — but an extend appends to `targets`, and every executor path builds
    /// its write as `var updated = directive`, so applying a post-extend action
    /// to the pre-extend value writes `targets` back and rolls the append away.
    /// That is not an edge case: the action after a successful extend is normally
    /// `.assignController`, which commits the whole row.
    private struct Resolution {
        let action: MissionAction
        let directive: Directive
    }

    /// How long an idling continuous run is left alone before its planner is
    /// asked again.
    ///
    /// Only `.idle` runs pay this. `.extendQueue` reads the whole census, which
    /// is affordable once per worked system (tens of minutes apart) and absurd on
    /// the 5 s tick — and a run whose frontier is momentarily empty would ask on
    /// every single one.
    static let idlePlanBackoff: TimeInterval = 60

    /// When each idling directive's planner may next be asked. In-memory
    /// deliberately: it is a read-rate optimisation, and losing it on relaunch
    /// costs one extra census read.
    private var idlePlanUntil: [String: Date] = [:]

    /// Pick the next target for the continuous run `directive` roaming around
    /// `centre`, append it, and ask `machine` again against the EXTENDED row.
    ///
    /// The engine gathers the data and owns the write; **which** system comes
    /// back is the machine's own `plan(_:)`, so a survey roam's sliding bands and
    /// a salvage run's mesh frontier each live with their mission. A `switch` on
    /// `directive.kind` here would reintroduce exactly the coupling
    /// `MissionRegistry` exists to remove.
    ///
    /// One census read per worked system — tens of minutes apart, not on the 5 s
    /// tick — so reading the whole table is affordable and each candidate filter
    /// stays in its own unit-tested planner.
    private func resolveExtendQueue(
        centre: String,
        directive: Directive,
        machine: any MissionStepMachine
    ) async -> Resolution {
        @Dependency(\.defaultDatabase) var database
        @Dependency(\.date) var date

        if let until = idlePlanUntil[directive.id], date.now < until {
            return Resolution(action: .wait, directive: directive)
        }

        let vesselCode = directive.deviceCode
        let attempted = Set(directive.targets)

        let plan: RoamPlan
        do {
            let context = try await database.read { db -> RoamContext in
                let vessel = try Device.where { $0.deviceCode.eq(vesselCode) }.fetchOne(db)
                let vesselSystem = vessel?.location.map { SiteAssay.system(of: $0) }
                let vesselStar = try vesselSystem.flatMap { designation in
                    try Star.where { $0.designation.eq(designation) }.fetchOne(db)
                }
                return RoamContext(
                    centre: try Star.where { $0.designation.eq(centre) }.fetchOne(db),
                    vessel: vesselStar?.position,
                    stars: try Star.all.fetchAll(db),
                    assays: try SiteAssay.all.fetchAll(db),
                    devices: try Device.all.fetchAll(db),
                    attempted: attempted
                )
            }
            plan = machine.plan(context)
        } catch {
            // The run is no worse off than before the attempt; wait and let the
            // next tick try again.
            logger.error("directive \(directive.id, privacy: .public): roam census read failed: \(error)")
            return Resolution(action: .wait, directive: directive)
        }

        let planned: String
        switch plan {
        case let .target(system):
            idlePlanUntil[directive.id] = nil
            planned = system
        case .idle:
            // Nothing reachable *right now*. The machine says more may appear —
            // the survey roam keeps uncovering salvage, and each relay this run
            // plants widens the frontier — so the run idles rather than finishing
            // behind the operator's back.
            idlePlanUntil[directive.id] = date.now.addingTimeInterval(Self.idlePlanBackoff)
            logger.info("directive \(directive.id, privacy: .public): nothing reachable around \(centre, privacy: .public) — idling")
            return Resolution(action: .wait, directive: directive)
        case .exhausted:
            idlePlanUntil[directive.id] = nil
            logger.info("directive \(directive.id, privacy: .public): nothing left to plan around \(centre, privacy: .public) — finishing")
            return Resolution(action: .done, directive: directive)
        }

        // `targetIndex` already equals `targets.count` (that is what made the
        // queue exhausted), so appending alone makes the new entry the current
        // target. No index arithmetic.
        var appended = directive
        appended.targets.append(planned)
        appended.updatedAt = date.now
        // Immutable before the write closure captures it — a `var` crossing into
        // concurrently-executing code is a Sendable violation.
        let extended = appended
        do {
            try await database.write { db in
                try Directive.upsert { extended }.execute(db)
            }
        } catch {
            logger.error("directive \(directive.id, privacy: .public): roam append failed: \(error)")
            return Resolution(action: .wait, directive: directive)
        }
        logger.info("directive \(directive.id, privacy: .public): roam picked \(planned, privacy: .public) (\(extended.targets.count) aimed at so far)")

        let world: WorldSnapshot
        do {
            world = try await WorldSnapshot.read(from: database, now: date.now, directive: extended)
        } catch {
            logger.error("world snapshot after roam extend failed: \(error)")
            return Resolution(action: .wait, directive: extended)
        }

        // The re-ask gets the SAME resolution the first ask would have got. An
        // extend is not the end of the round: a mission just handed a target may
        // well need reads before it can act on one, and preflight always does —
        // `stagingFreshness` is five minutes and a survey cycle is longer, so the
        // rows backing staging are invariably past the bar by the time a queue is
        // extended. Passing such a request to the executor unresolved makes it an
        // immediate stall on its carried reason, at every single system.
        switch machine.nextAction(directive: extended, world: world) {
        case .extendQueue:
            // A target was just appended and the machine still wants one. Not
            // reachable through preflight (it would have to skip the brand-new
            // target first, which is a fresh evaluation), so this is the
            // one-round loop guard rather than an expected path.
            logger.notice("directive \(directive.id, privacy: .public): roam extend did not settle — finishing")
            return Resolution(action: .done, directive: extended)

        case let .refreshDevices(deviceCodes, thenStall):
            // Bounded: `reAsk` pays for each refresh KIND at most once per
            // evaluation and collapses anything beyond that into the carried
            // stall, so this pays for at most one round per kind — the same
            // ceiling an evaluation that never extended is held to.
            let resolved = await resolveRefresh(
                deviceCodes: deviceCodes, thenStall: thenStall,
                directive: extended, machine: machine, paid: [.devices]
            )
            return Resolution(action: resolved, directive: extended)

        case let .refreshDevicesInSystem(designation, thenStall):
            let resolved = await resolveSystemRefresh(
                designation: designation, thenStall: thenStall,
                directive: extended, machine: machine, paid: [.devicesInSystem]
            )
            return Resolution(action: resolved, directive: extended)

        case let .refreshFleet(tag, thenStall):
            let resolved = await resolveFleetRefresh(
                tag: tag, thenStall: thenStall,
                directive: extended, machine: machine, paid: [.fleet]
            )
            return Resolution(action: resolved, directive: extended)

        case let .refreshFootprint(nextStep, thenStall):
            let resolved = await resolveFootprintRefresh(
                nextStep: nextStep, thenStall: thenStall,
                directive: extended, machine: machine, paid: [.footprint]
            )
            return Resolution(action: resolved, directive: extended)

        case let .refreshEvents(thenStall):
            let resolved = await resolveEventsRefresh(
                thenStall: thenStall,
                directive: extended, machine: machine, paid: [.events]
            )
            return Resolution(action: resolved, directive: extended)

        case let .completeEvent(location, designation, nextStep):
            let resolved = await resolveEventCompletion(
                location: location, designation: designation,
                nextStep: nextStep, directive: extended
            )
            return Resolution(action: resolved, directive: extended)

        case let action:
            return Resolution(action: action, directive: extended)
        }
    }

    /// Spend authoritative reads on `directive`'s request for `deviceCodes`,
    /// then ask `machine` once more against the fresh world, collapsing an
    /// unresolved repeat onto `reason` (`paid` carries the chain's ceiling — see
    /// `reAsk`).
    ///
    /// The re-ask is what makes the action worth having: the mission gets to
    /// distinguish "genuinely not staged" from "our rows were stale", which a
    /// `WorldSnapshot` alone cannot express. It happens here rather than in
    /// `DirectiveExecutor` because it needs a second snapshot read and a second
    /// call into the machine — the executor's job is applying ONE decided action
    /// to the database.
    private func resolveRefresh(
        deviceCodes: [String],
        thenStall reason: DirectiveAttentionReason?,
        directive: Directive,
        machine: any MissionStepMachine,
        paid: Set<RefreshKind>
    ) async -> MissionAction {
        @Dependency(\.deviceRefresher) var deviceRefresher
        @Dependency(\.defaultDatabase) var database
        @Dependency(\.date) var date

        // `.high` deliberately — the alternative to these reads is a run that stops
        // dead until a human notices. `seen` keeps it to one read per device.
        var seen = Set<String>()
        for code in deviceCodes where seen.insert(code).inserted {
            guard let device = await deviceRefresher.refresh(code, .high) else { continue }
            // Containment is two-ended: the staging checks read each CHILD's stow
            // column, so refreshing the vessel alone leaves them just as stale.
            for stowed in device.stowedDeviceCodes where seen.insert(stowed).inserted {
                _ = await deviceRefresher.refresh(stowed, .high)
            }
        }
        logger.info("directive \(directive.id, privacy: .public): refreshed \(seen.count) device(s) before \(reason?.rawValue ?? "wait", privacy: .public)")

        let fresh: WorldSnapshot
        do {
            fresh = try await WorldSnapshot.read(from: database, now: date.now, directive: directive)
        } catch {
            // The reads may well have landed; we just can't see them. Surfacing
            // the stall is the honest outcome — the user's Retry now re-reads.
            logger.error("world snapshot after refresh failed: \(error)")
            return reason.map { .stall($0) } ?? .wait
        }

        return await reAsk(machine, directive, fresh, paid: paid)
    }

    /// `resolveRefresh`'s contract, paid for with ONE list request scoped to
    /// `designation` — it does not grow with the fleet. Answers PRESENCE only: a
    /// stowed device has no location and is absent entirely, so **never resolve a
    /// containment question this way**. Reconciled rather than upserted, and
    /// deliberately never pruned — a scoped walk is not the authoritative fleet.
    private func resolveSystemRefresh(
        designation: String,
        thenStall reason: DirectiveAttentionReason?,
        directive: Directive,
        machine: any MissionStepMachine,
        paid: Set<RefreshKind>
    ) async -> MissionAction {
        @Dependency(\.devicesClient) var devicesClient
        @Dependency(\.defaultDatabase) var database
        @Dependency(\.date) var date

        do {
            let devices = try await devicesClient.fetchAtLocation(designation)
            let reconciler = Reconciler()
            await reconciler.ingest(devices)
            logger.info("directive \(directive.id, privacy: .public): reconciled \(devices.count) device(s) at \(designation, privacy: .public) in one request")
        } catch {
            // The run is no worse off than before the attempt; fall through and
            // let the machine judge the rows it already has.
            logger.error("directive \(directive.id, privacy: .public): system refresh of \(designation, privacy: .public) failed: \(error)")
        }

        let fresh: WorldSnapshot
        do {
            fresh = try await WorldSnapshot.read(from: database, now: date.now, directive: directive)
        } catch {
            logger.error("world snapshot after system refresh failed: \(error)")
            return reason.map { .stall($0) } ?? .wait
        }
        return await reAsk(machine, directive, fresh, paid: paid)
    }

    /// `resolveSystemRefresh`'s contract, scoped to `tag` instead of a location.
    /// A scoped tag also reads its unscoped form, so a half-migrated fleet is
    /// fully refreshed. **Never prune after this read** — see `.refreshFleet`.
    private func resolveFleetRefresh(
        tag: FleetTag,
        thenStall reason: DirectiveAttentionReason?,
        directive: Directive,
        machine: any MissionStepMachine,
        paid: Set<RefreshKind>
    ) async -> MissionAction {
        @Dependency(\.defaultDatabase) var database
        @Dependency(\.date) var date

        let scoped = await fetchAndIngest(tag, for: directive)
        let unscoped = tag.isScoped ? await fetchAndIngest(tag.unscoped, for: directive) : nil
        let counts = "\(tag.string)=\(scoped)"
            + (unscoped.map { ", \(tag.unscoped.string)=\($0)" } ?? "")
        logger.info("directive \(directive.id, privacy: .public): fleet refresh reconciled \(counts, privacy: .public)")

        let fresh: WorldSnapshot
        do {
            fresh = try await WorldSnapshot.read(from: database, now: date.now, directive: directive)
        } catch {
            logger.error("world snapshot after fleet refresh failed: \(error)")
            return reason.map { .stall($0) } ?? .wait
        }
        return await reAsk(machine, directive, fresh, paid: paid)
    }

    /// Reads one tag and ingests what it answers, returning the count. A failure
    /// leaves the run no worse off than before the attempt, so it never throws.
    private func fetchAndIngest(_ tag: FleetTag, for directive: Directive) async -> Int {
        @Dependency(\.devicesClient) var devicesClient
        do {
            let devices = try await devicesClient.fetchByTag(tag.string)
            await Reconciler().ingest(devices)
            return devices.count
        } catch {
            logger.error("directive \(directive.id, privacy: .public): fleet refresh of \(tag.string, privacy: .public) failed: \(error)")
            return 0
        }
    }

    /// The other resolvers' contract, paid for with one stockpile-census refresh,
    /// falling back to `.advanceStep` where they fall back to `.wait`. Best-effort:
    /// a transient GET must never strand a mission, so a failure is logged and the
    /// re-ask proceeds against whatever `footprints` already holds.
    private func resolveFootprintRefresh(
        nextStep: String,
        thenStall reason: DirectiveAttentionReason?,
        directive: Directive,
        machine: any MissionStepMachine,
        paid: Set<RefreshKind>
    ) async -> MissionAction {
        @Dependency(\.locationsClient) var locationsClient
        @Dependency(\.defaultDatabase) var database
        @Dependency(\.date) var date

        do {
            try await locationsClient.refreshFootprint()
        } catch {
            logger.notice("directive \(directive.id, privacy: .public): footprint refresh failed: \(error)")
        }

        let fresh: WorldSnapshot
        do {
            fresh = try await WorldSnapshot.read(from: database, now: date.now, directive: directive)
        } catch {
            logger.error("world snapshot after footprint refresh failed: \(error)")
            return reason.map { .stall($0) } ?? .advanceStep(nextStep: nextStep)
        }
        return await reAsk(machine, directive, fresh, paid: paid)
    }

    /// `resolveFootprintRefresh`'s contract, paid for with one walk of the account
    /// event ledger, falling back to `.wait` where that one falls back to
    /// `.advanceStep` — the action carries no step of its own.
    private func resolveEventsRefresh(
        thenStall reason: DirectiveAttentionReason?,
        directive: Directive,
        machine: any MissionStepMachine,
        paid: Set<RefreshKind>
    ) async -> MissionAction {
        @Dependency(\.locationEventsClient) var locationEventsClient
        @Dependency(\.defaultDatabase) var database
        @Dependency(\.date) var date

        do {
            let count = try await locationEventsClient.refresh()
            logger.info("directive \(directive.id, privacy: .public): refreshed \(count) event(s)")
        } catch {
            logger.notice("directive \(directive.id, privacy: .public): event refresh failed: \(error)")
        }

        let fresh: WorldSnapshot
        do {
            fresh = try await WorldSnapshot.read(from: database, now: date.now, directive: directive)
        } catch {
            logger.error("world snapshot after event refresh failed: \(error)")
            return reason.map { .stall($0) } ?? .wait
        }
        return await reAsk(machine, directive, fresh, paid: paid)
    }

    /// Commit `designation` at `location`, re-read the ledger, then advance to
    /// `nextStep` UNCONDITIONALLY: a refusal is the mission's to judge from the
    /// refreshed row on its next evaluation, so retrying here would hide it.
    private func resolveEventCompletion(
        location: String,
        designation: String,
        nextStep: String,
        directive: Directive
    ) async -> MissionAction {
        @Dependency(\.locationEventsClient) var locationEventsClient

        do {
            try await locationEventsClient.complete(location, designation)
            logger.info("directive \(directive.id, privacy: .public): committed event \(designation, privacy: .public)")
        } catch {
            logger.notice("directive \(directive.id, privacy: .public): event commit for \(designation, privacy: .public) refused: \(error)")
        }
        do {
            _ = try await locationEventsClient.refresh()
        } catch {
            logger.notice("directive \(directive.id, privacy: .public): event refresh after commit failed: \(error)")
        }
        return .advanceStep(nextStep: nextStep)
    }

    /// The five refresh actions as a discriminator, and the basis of the chain
    /// bound below. Keyed on the KIND alone, never the payload: letting a changed
    /// payload buy another round restores the unbounded loop `reAsk` prevents.
    private enum RefreshKind: Hashable {
        case devices, devicesInSystem, fleet, footprint, events

        /// The kind of refresh `action` asks for, or nil for anything else.
        init?(_ action: MissionAction) {
            switch action {
            case .refreshDevices: self = .devices
            case .refreshDevicesInSystem: self = .devicesInSystem
            case .refreshFleet: self = .fleet
            case .refreshFootprint: self = .footprint
            case .refreshEvents: self = .events
            default: return nil
            }
        }
    }

    /// What `action` becomes when the engine will not pay for it, read off `action`
    /// ITSELF and never off an earlier hop — collapsing onto the reason belonging
    /// to the refresh already performed blames the wrong thing, stalling
    /// `.unreachableDevice` on a perfectly reachable device.
    private static func collapse(_ action: MissionAction, currentStep: String) -> MissionAction {
        switch action {
        case let .refreshDevices(_, reason), let .refreshDevicesInSystem(_, reason),
             let .refreshFleet(_, reason), let .refreshEvents(reason):
            // These four never advance a step of their own accord. `.wait` is
            // also the only fallback that leaves `stepStartedAt` alone.
            return reason.map { MissionAction.stall($0) } ?? .wait
        case let .refreshFootprint(nextStep, reason):
            // `HaulRun.survey`'s contract: a transient miss costs one cycle rather
            // than stranding a continuous run.
            if let reason { return .stall(reason) }
            // Same-step: nothing to advance to, so `.wait` rather than
            // `.advanceStep`, which would restamp this step's own deadline.
            return nextStep == currentStep ? .wait : .advanceStep(nextStep: nextStep)
        default:
            return action
        }
    }

    /// Ask `machine` once more against the freshly-read `fresh` world, given the
    /// kinds `paid` for so far. The loop guard, shared by all five refresh paths.
    /// A commit resolves here too; any other non-refresh answer returns untouched;
    /// a kind already paid for collapses to its own stall/fallback; a kind not yet
    /// paid for chains ONE hop into that kind's resolver (passing it through
    /// unresolved would hit the executor's bypass, which stalls instead of reading).
    ///
    /// **The bound:** `paid` grows strictly on every guarded hop over a closed
    /// five-case enum, so an evaluation performs at most one refresh round per kind
    /// — five in total — and always terminates in a non-refresh action. This
    /// depends on no read succeeding and no mission being well-behaved.
    private func reAsk(
        _ machine: any MissionStepMachine,
        _ directive: Directive,
        _ fresh: WorldSnapshot,
        paid: Set<RefreshKind>
    ) async -> MissionAction {
        let action = machine.nextAction(directive: directive, world: fresh)
        if case let .completeEvent(location, designation, nextStep) = action {
            // Terminal and non-refresh: the commit never re-asks, so it cannot
            // extend the chain and `paid` is left exactly as it was.
            return await resolveEventCompletion(
                location: location, designation: designation,
                nextStep: nextStep, directive: directive
            )
        }
        guard let kind = RefreshKind(action) else { return action }

        guard !paid.contains(kind) else {
            let collapsed = Self.collapse(action, currentStep: directive.step)
            if case let .stall(confirmed, _) = collapsed {
                logger.notice("directive \(directive.id, privacy: .public): fresh reads confirm \(confirmed.rawValue, privacy: .public)")
            } else {
                logger.debug("directive \(directive.id, privacy: .public): fresh reads still unresolved — \(String(describing: collapsed), privacy: .public)")
            }
            return collapsed
        }

        let chained = paid.union([kind])
        logger.debug("directive \(directive.id, privacy: .public): fresh reads raised a different question (\(String(describing: kind), privacy: .public)) — chaining once")
        switch action {
        case let .refreshDevices(deviceCodes, thenStall):
            return await resolveRefresh(
                deviceCodes: deviceCodes, thenStall: thenStall,
                directive: directive, machine: machine, paid: chained
            )
        case let .refreshDevicesInSystem(designation, thenStall):
            return await resolveSystemRefresh(
                designation: designation, thenStall: thenStall,
                directive: directive, machine: machine, paid: chained
            )
        case let .refreshFleet(tag, thenStall):
            return await resolveFleetRefresh(
                tag: tag, thenStall: thenStall,
                directive: directive, machine: machine, paid: chained
            )
        case let .refreshFootprint(nextStep, thenStall):
            return await resolveFootprintRefresh(
                nextStep: nextStep, thenStall: thenStall,
                directive: directive, machine: machine, paid: chained
            )
        case let .refreshEvents(thenStall):
            return await resolveEventsRefresh(
                thenStall: thenStall,
                directive: directive, machine: machine, paid: chained
            )
        default:
            // Unreachable: `RefreshKind.init` returned non-nil, so `action` is
            // one of the five above. Kept total rather than force-unwrapped.
            return action
        }
    }
}

// MARK: - Dependency

extension DirectiveEngine: DependencyKey {
    /// The one engine the app runs, over the registered machines.
    public static let liveValue = DirectiveEngine.makeLive()
}

extension DirectiveEngine: TestDependencyKey {
    /// Inert: engine tests drive `DirectiveEngineCore` directly, and no feature
    /// should be starting the engine.
    public static let testValue = DirectiveEngine(start: {}, stop: {})
}

extension DependencyValues {
    /// The directive engine's lifecycle handles, for the composition root.
    public var directiveEngine: DirectiveEngine {
        get { self[DirectiveEngine.self] }
        set { self[DirectiveEngine.self] = newValue }
    }
}
