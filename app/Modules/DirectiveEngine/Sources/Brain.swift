//
//  Brain.swift
//  Replicould — DirectiveEngine
//
//  The automation brain's evaluation entry point, ticked by
//  `DirectiveEngineCore.tickBrain()`: one tick reads the world, answers halted
//  missions of the kinds in `brainManagedKinds`, launches at most one Relay Run,
//  keeps one restock, survey, salvage, haul and mine run alive, and one pinned
//  ferry row per installed mine beside them. A PURE
//  SELECTOR — it inserts directives and drives the `retry`/`cancel` resolution
//  verbs, nothing else. STATELESS between ticks: a tick is a pure function of
//  `(WorldView, directive rows)`. Not an actor, so ranking cannot block the
//  reconciliation loop beside it.
//

import Dependencies
import Foundation
import GameModels
import GameServices
import GameSession
import OSLog
import SQLiteData
import UniverseModels

private let logger = Logger(subsystem: "name.pennig.replicould", category: "Brain")

/// One tick's worth of brain evaluation. Every stored property here is an
/// input to THIS evaluation, never state carried over from the last one.
struct Brain: Sendable {
    /// Supplied from `@Dependency(\.date)`. Sampling `Date()` below instead breaks
    /// `WorldView`'s snapshot and every `TestClock` test.
    let now: Date

    /// Opt-in with NO fallback to "any free vessel": an untagged fleet means the
    /// brain launches nothing and says so. Compare only through `Device.hasTag` —
    /// a raw `tags.contains` refuses the vessel that was just opted in.
    static let carrierTag = "auto:tendmesh"

    /// The survey fleet's own opt-in tag, disjoint from `carrierTag` — the two
    /// automations never contend over the same vessel.
    static let surveyCarrierTag = SurveyRun.defaultFleetTag

    /// How far off its road the brain will send a carrier to fetch a spare relay
    /// rather than print one. Measured from the PLANT SITE, never the hub: the
    /// triangle inequality bounds the detour by `2 · d(source, target)` wherever
    /// the hub stands, so a hub-measured cutoff caps nothing.
    static let reclaimRangeLY: Double = 2 * SalvageTargetPlanner.relayRangeLY

    /// Statuses in which a directive still OWNS its devices — a stall the operator
    /// is about to resolve must find its fleet intact. `DirectiveRow.owningStatuses`
    /// is a verbatim copy; neither module can import the other's, so they drift.
    static let owningStatuses: Set<DirectiveStatus> = [.running, .needsAttention, .paused]

    /// Read the world, decide what is worth doing, and do it. Reporting priority
    /// when a tick did several things: a launch outranks an escalation, which
    /// outranks idling. Every irreversible act re-checks `Task.isCancelled`
    /// immediately before itself, since each has its own suspension in front of it
    /// and `stop()` cancels this task without awaiting it.
    func report() async -> BrainReport {
        @Dependency(\.defaultDatabase) var database

        let snapshot: Snapshot
        do {
            snapshot = try await database.read { db in
                let directives = try Directive.all.fetchAll(db)
                // Scoped to the brain's own halted missions on the existing
                // `(directiveID, occurredAt)` index — the table is never pruned.
                // `[String?]` matches the nullable column; `IN` never matches NULL.
                let stalled: [String?] = directives
                    .filter { Self.brainManagedStall($0) != nil }
                    .map(\.id)
                let log = stalled.isEmpty ? [:] : Dictionary(
                    grouping: try DirectiveLogEntry
                        .where { $0.directiveID.in(stalled) }
                        .order { $0.occurredAt }
                        .fetchAll(db),
                    by: { $0.directiveID ?? "" }
                )
                let view = try WorldView.read(from: db, now: now)
                return Snapshot(
                    view: view,
                    directives: directives,
                    log: log,
                    // Same transaction as everything else: a stock figure from a
                    // different instant than the devices describes no real world.
                    hubFootprint: try view.hubLocation.flatMap { hub in
                        try LocationFootprint.where { $0.location.eq(hub) }.fetchOne(db)
                    }
                )
            }
        } catch {
            logger.error("world read failed: \(error)")
            // The governor is process-local and still readable, and a tick that
            // could not reach the database is exactly when an operator wants to
            // know whether we are rate-limited.
            return await BrainReport(
                decision: .idle(reason: "world unavailable"),
                ranked: [],
                hubLocation: nil,
                limits: Self.limits(hubFootprint: nil),
                survey: .idle(reason: "world unavailable"),
                salvage: .idle(reason: "world unavailable"),
                haul: .idle(reason: "world unavailable"),
                mine: .idle(reason: "world unavailable"),
                observedAt: now
            )
        }

        // Read before `ensureSurvey` acts, mirroring `ranked`/`hubLocation`:
        // the report states the tick's SNAPSHOT, not its write. A verdict of
        // `.ready` here launches inside `ensureSurvey` below on this very
        // tick — the next tick's fresh read is what turns it `.launched`.
        let survey = Self.surveyStatus(directives: snapshot.directives, view: snapshot.view)
        let salvage = Self.salvageStatus(directives: snapshot.directives, view: snapshot.view)
        let haul = Self.haulStatus(directives: snapshot.directives, view: snapshot.view)
        let mine = Self.mineStatus(directives: snapshot.directives, view: snapshot.view)
        let mines = Self.mineHealth(view: snapshot.view, directives: snapshot.directives)

        let escalated = await respondToStalls(snapshot)
        let plan = Self.plan(view: snapshot.view, directives: snapshot.directives)
        let decision = await decide(plan, escalated: escalated, database: database)
        await tendRestock(plan: plan, snapshot: snapshot, decision: decision, database: database)
        await ensureSurvey(snapshot: snapshot, database: database)
        await ensureSalvage(snapshot: snapshot, database: database)
        await ensureHaul(snapshot: snapshot, database: database)
        await ensureMine(snapshot: snapshot, database: database)
        await ensureMineFerries(snapshot: snapshot, database: database)

        return await BrainReport(
            decision: decision,
            ranked: plan.ranked,
            hubLocation: snapshot.view.hubLocation,
            limits: Self.limits(hubFootprint: snapshot.hubFootprint),
            prune: Self.pruneReport(
                plan: plan, decision: decision, directives: snapshot.directives
            ),
            survey: survey,
            salvage: salvage,
            haul: haul,
            mine: mine,
            mines: mines,
            observedAt: now
        )
    }

    /// Keep exactly one restock run alive at the hub, writing `plan`'s ranked
    /// first hops minus anything in flight onto its `targets`. The brain writes
    /// the DEMAND, the run does the printing. **Never hosted on a carrier** — a
    /// persistent directive reserves its device, which would park that vessel out
    /// of the fleet forever and no grow could launch.
    private func tendRestock(
        plan: Plan, snapshot: Snapshot, decision: BrainDecision, database: any DatabaseWriter
    ) async {
        guard !Task.isCancelled else { return }
        guard let host = Self.restockHost(in: snapshot.view) else { return }

        // Targets the brain still wants meshed and nothing is already flying to.
        let inFlight = Self.inFlightTargets(snapshot.directives)
        let demand = plan.ranked.map(\.firstHop).filter { !inFlight.contains($0) }

        let existing = snapshot.directives.first {
            $0.kind == .restockRun && Self.owningStatuses.contains($0.status)
        }
        // No targets, nothing to print FOR, so no run is created. An existing
        // one is left alone rather than cancelled: demand comes and goes as
        // systems mesh, and a row that deleted itself every quiet tick would
        // churn the list and lose its timeline.
        guard existing != nil || !demand.isEmpty else { return }
        // One action per tick, the discipline `plan` and `respondToStalls` keep.
        // Creating this row is an action, so a tick that has just committed a
        // launch does not also take it; the next tick creates restock against a
        // ledger that contains the launch. Updating an EXISTING row's demand
        // below is bookkeeping, not an action, and is not deferred.
        if existing == nil, case .dispatch = decision { return }
        if let existing {
            // Only write when the list actually moved — a row rewritten every
            // tick would churn the timeline and every `@FetchAll` observing it.
            guard existing.targets != demand else { return }
            do {
                try await database.write { db in
                    guard var row = try Directive.where({ $0.id.eq(existing.id) }).fetchOne(db) else { return }
                    row.targets = demand
                    row.updatedAt = self.now
                    try Directive.upsert { row }.execute(db)
                }
            } catch {
                logger.error("restock demand update failed: \(error)")
            }
            return
        }

        @Dependency(\.uuid) var uuid
        let directive = Directive(
            id: uuid().uuidString,
            kind: .restockRun,
            status: .running,
            deviceCode: host.deviceCode,
            controllerCode: nil, roamCentre: nil, fleetTag: nil, sourceRelayCode: nil,
            targets: demand, targetIndex: 0,
            step: RestockRun().firstStep,
            stepStartedAt: now,
            returnToOrigin: false,
            originDesignation: host.location.map { SiteAssay.system(of: $0) },
            attentionReason: nil,
            createdAt: now, updatedAt: now
        )
        do {
            try await database.write { db in
                // Re-check inside the transaction: the read and the write are
                // separate steps, so a restock created by the previous tick
                // could have landed in between.
                let live = try Directive
                    .where { $0.kind.eq(DirectiveKind.restockRun) }
                    .fetchAll(db)
                    .contains { Self.owningStatuses.contains($0.status) }
                guard !live else { return }
                try Directive.insert { directive }.execute(db)
                logger.info(
                    "restock \(directive.id, privacy: .public) launched on \(host.deviceCode, privacy: .public)"
                )
            }
        } catch {
            logger.error("restock launch failed: \(error)")
        }
    }

    /// Keep exactly one live directive of `kind` that `matching` accepts,
    /// building one through `build` when none is. `matching` narrows liveness
    /// past kind alone — the general haul drainer is one row among its siblings.
    func ensureOne(
        _ kind: DirectiveKind,
        matching: @escaping @Sendable (Directive) -> Bool = { _ in true },
        snapshot: Snapshot,
        database: any DatabaseWriter,
        build: () -> Directive?
    ) async {
        guard !Task.isCancelled else { return }
        let live = snapshot.directives.contains {
            $0.kind == kind && Self.owningStatuses.contains($0.status) && matching($0)
        }
        guard !live else { return }
        guard let directive = build() else { return }

        do {
            try await database.write { db in
                // Rows AND devices read in-transaction: the snapshot predates
                // this tick's own earlier launches, and a stale device map
                // would under-reserve the stow closure.
                let rows = try Directive.all.fetchAll(db)
                let devices = try Device.all.fetchAll(db)
                    .reduce(into: [String: Device]()) { $0[$1.deviceCode] = $1 }
                let live = rows.contains {
                    $0.kind == kind && Self.owningStatuses.contains($0.status) && matching($0)
                }
                guard !live else { return }
                // A device another directive of ANY kind already owns is not
                // this one's to commit — kind-scoped liveness cannot see that.
                let reserved = Self.reservedDevices(directives: rows, devices: devices)
                guard !reserved.contains(directive.deviceCode) else {
                    logger.notice(
                        """
                        \(kind.rawValue, privacy: .public) declined: \
                        \(directive.deviceCode, privacy: .public) is already committed
                        """
                    )
                    return
                }
                try Directive.insert { directive }.execute(db)
                logger.info(
                    """
                    \(kind.rawValue, privacy: .public) \(directive.id, privacy: .public) \
                    launched on \(directive.deviceCode, privacy: .public)
                    """
                )
            }
        } catch {
            logger.error("\(kind.rawValue, privacy: .public) launch failed: \(error)")
        }
    }

    /// Keep exactly one Survey Run roaming — `tendRestock`'s sibling. Nothing
    /// preempts it: `.needsAttention`/`.paused` count as live so the brain
    /// never relaunches around a halted run or an operator's own pause.
    private func ensureSurvey(snapshot: Snapshot, database: any DatabaseWriter) async {
        guard case let .launch(carrier, roamCentre) = Self.surveyReadiness(view: snapshot.view) else { return }
        @Dependency(\.uuid) var uuid
        await ensureOne(.surveyRun, snapshot: snapshot, database: database) {
            Directive(
                id: uuid().uuidString,
                kind: .surveyRun,
                status: .running,
                deviceCode: carrier,
                controllerCode: nil, roamCentre: roamCentre,
                fleetTag: SurveyRun.defaultFleetTag, sourceRelayCode: nil,
                targets: [], targetIndex: 0,
                step: SurveyRun().firstStep,
                stepStartedAt: now,
                returnToOrigin: false,
                originDesignation: snapshot.view.devices[carrier]?.location.map { SiteAssay.system(of: $0) },
                attentionReason: nil,
                createdAt: now, updatedAt: now
            )
        }
    }

    /// Keep exactly one Salvage Run working — `ensureSurvey`'s sibling. The run
    /// is continuous and picks its own targets, so liveness is the whole job.
    private func ensureSalvage(snapshot: Snapshot, database: any DatabaseWriter) async {
        guard case let .launch(carrier, roamCentre) = Self.salvageReadiness(
            view: snapshot.view, directives: snapshot.directives
        ) else { return }

        @Dependency(\.uuid) var uuid
        await ensureOne(.salvageRun, snapshot: snapshot, database: database) {
            Directive(
                id: uuid().uuidString,
                kind: .salvageRun,
                status: .running,
                deviceCode: carrier,
                controllerCode: nil,
                roamCentre: roamCentre,
                fleetTag: SalvageRun.defaultFleetTag,
                sourceRelayCode: nil,
                targets: [], targetIndex: 0,
                step: SalvageRun().firstStep,
                stepStartedAt: now,
                returnToOrigin: false,
                originDesignation: snapshot.view.devices[carrier]?.location.map { SiteAssay.system(of: $0) },
                attentionReason: nil,
                createdAt: now, updatedAt: now
            )
        }
    }

    /// Keep exactly one GENERAL haul run alive. Scoped by fleet tag, not kind:
    /// `mine`'s future per-site rows carry their own tags, so they neither
    /// satisfy this rule nor get relaunched around by it.
    private func ensureHaul(snapshot: Snapshot, database: any DatabaseWriter) async {
        guard case let .launch(controller) = Self.haulReadiness(view: snapshot.view, directives: snapshot.directives) else { return }

        @Dependency(\.uuid) var uuid
        await ensureOne(
            .haulRun, matching: Self.isGeneralHaul, snapshot: snapshot, database: database
        ) {
            Directive(
                id: uuid().uuidString,
                kind: .haulRun,
                status: .running,
                deviceCode: controller,
                controllerCode: nil,
                roamCentre: nil,
                fleetTag: HaulRun.defaultFleetTag,
                sourceRelayCode: nil,
                targets: [], targetIndex: 0,
                step: HaulRun().firstStep,
                stepStartedAt: now,
                returnToOrigin: false,
                originDesignation: snapshot.view.hubLocation.map { SiteAssay.system(of: $0) },
                attentionReason: nil,
                createdAt: now, updatedAt: now
            )
        }
    }

    /// Install one mine fleet at a time — a second install would contend for the
    /// same free fleet members standing at the hub.
    private func ensureMine(snapshot: Snapshot, database: any DatabaseWriter) async {
        guard case let .launch(carrier, belt) = Self.mineReadiness(
            view: snapshot.view, directives: snapshot.directives
        ) else { return }

        @Dependency(\.uuid) var uuid
        await ensureOne(.mineRun, snapshot: snapshot, database: database) {
            Directive(
                id: uuid().uuidString,
                kind: .mineRun,
                status: .running,
                deviceCode: carrier,
                controllerCode: nil,
                roamCentre: nil,
                fleetTag: MineRecipe.fleetTag,
                sourceRelayCode: nil,
                targets: [belt], targetIndex: 0,
                step: MineRun().firstStep,
                stepStartedAt: now,
                returnToOrigin: false,
                originDesignation: snapshot.view.hubLocation.map { SiteAssay.system(of: $0) },
                attentionReason: nil,
                createdAt: now, updatedAt: now
            )
        }
    }

    /// Keep one PINNED haul row draining each installed mine, beside the general
    /// drainer. A belt a live `mineRun` still targets is skipped — that run arms
    /// the same transport controller, from the other side.
    private func ensureMineFerries(snapshot: Snapshot, database: any DatabaseWriter) async {
        let view = snapshot.view
        let belts = MineRecipe.installedBelts(in: view.devices.values, hub: view.hubLocation)
            .subtracting(Self.liveMineBelts(snapshot.directives))
            .sorted()
        guard !belts.isEmpty else { return }

        @Dependency(\.uuid) var uuid
        for belt in belts {
            await ensureOne(
                .haulRun,
                matching: { $0.targets.first == belt },
                snapshot: snapshot,
                database: database
            ) {
                guard let controller = Self.mineFerryController(
                    for: belt, view: view, directives: snapshot.directives
                ) else { return nil }
                return Directive(
                    id: uuid().uuidString,
                    kind: .haulRun,
                    status: .running,
                    deviceCode: controller,
                    controllerCode: nil,
                    roamCentre: nil,
                    fleetTag: Self.mineFerryTag(for: belt),
                    sourceRelayCode: nil,
                    targets: [belt], targetIndex: 0,
                    step: HaulRun().firstStep,
                    stepStartedAt: now,
                    returnToOrigin: false,
                    originDesignation: view.hubLocation.map { SiteAssay.system(of: $0) },
                    attentionReason: nil,
                    createdAt: now, updatedAt: now
                )
            }
        }
    }

    /// The device a restock run may be hosted on: the lowest-coded print-capable
    /// device at `view`'s hub that is NOT a carrier hull. Hosting it on a carrier
    /// would reserve that vessel out of the fleet permanently.
    static func restockHost(in view: WorldView) -> Device? {
        guard let hub = view.hubLocation else { return nil }
        return view.devices.values
            .filter { $0.isPrintHub && $0.location == hub && !$0.isCarrierHull }
            .min { $0.deviceCode < $1.deviceCode }
    }

    /// What `plan`'s prune predicate found, partitioned against `directives`.
    /// Reports the reclaim only on a tick that COMMITTED — the source is chosen
    /// before the confirm-fresh gate, and a deferred gate leaves the relay
    /// standing. A relay an in-force run already claims is never reported spare.
    static func pruneReport(
        plan: Plan, decision: BrainDecision, directives: [Directive]
    ) -> BrainPrune? {
        guard let analysis = plan.prune else { return nil }

        var reclaimed: BrainReclaim?
        if case let .dispatch(goal, _) = decision, let choice = plan.reclaim {
            reclaimed = BrainReclaim(
                deviceCode: choice.relay.deviceCode,
                fromSystem: choice.relay.system,
                toSystem: goal.target,
                distanceLY: choice.distanceLY
            )
        }

        let claimedCodes = inFlightSources(directives)
        let unreclaimed = analysis.reclaimable.filter { $0.deviceCode != reclaimed?.deviceCode }
        return BrainPrune(
            reclaimed: reclaimed,
            claimed: unreclaimed.filter { claimedCodes.contains($0.deviceCode) },
            spare: unreclaimed.filter { !claimedCodes.contains($0.deviceCode) },
            pinnedCount: analysis.pinned.count,
            declined: analysis.declined
        )
    }

    /// Carry out `plan` and say what the tick did: `escalated` is the stall left
    /// needing a human, `database` takes the launch write. The precedence
    /// between a launch, an escalation and idling is `report()`'s, and is
    /// applied here.
    private func decide(
        _ plan: Plan,
        escalated: DirectiveAttentionReason?,
        database: any DatabaseWriter
    ) async -> BrainDecision {
        switch plan {
        case let .idle(reason, _, _):
            if let escalated { return .stall(escalated) }
            // Per-tick, so `.debug` — a 5s heartbeat any louder buries the
            // launches this file exists to make visible.
            logger.debug("idle — \(reason, privacy: .public)")
            return .idle(reason: reason)

        case let .grow(goal, ranked, carrier, hub, origin, source, _):
            // The confirm-fresh gate, in two halves that cannot collapse: the
            // authoritative half is a network read and cannot sit in a transaction,
            // the local half must sit in the very transaction that inserts or it is
            // advice rather than a guarantee.
            guard !Task.isCancelled else { return .idle(reason: "engine stopped") }
            switch await confirmCarrier(carrier) {
            case let .deferred(reason):
                if let escalated { return .stall(escalated) }
                return .idle(reason: reason)
            case let .proceed(fresh):
                let decision = await launch(
                    goal: goal, ranked: ranked, carrier: fresh, hub: hub, origin: origin,
                    source: source, database: database
                )
                if case .idle = decision, let escalated { return .stall(escalated) }
                return decision
            }
        }
    }

    /// The rails as they stand at this tick. Reports, never gates — the budget is
    /// enforced by `CommandGovernor` and the floor by `RelayRun.printStockIsShort`.
    /// Read through `@Dependency(\.gameClient)` so this is the figure every dispatch
    /// throttles on, not a second copy.
    private static func limits(hubFootprint: LocationFootprint?) async -> BrainLimits {
        @Dependency(\.gameClient) var gameClient
        let budget = await gameClient.budget(.actions)
        return BrainLimits(
            actionsRemaining: budget.remaining,
            actionsLimit: budget.limit,
            actionsFloor: CommandGovernorClient.actionFloor,
            hubStock: hubFootprint?.resources,
            // The rail vetoes on the reading's AGE as well as its value, so a
            // figure without its timestamp cannot say what the rail is doing.
            hubStockFetchedAt: hubFootprint?.fetchedAt,
            spendFloor: BrainCeiling.aggregateSpendFloor,
            rateLimitedAt: budget.rateLimitedAt
        )
    }

    /// ONE transaction — a carrier freed between two separate reads would look
    /// free to the ranking and reserved to the reservation pass. Holds
    /// `Directive.all` rather than a status filter, because which statuses own
    /// their devices is a rule (`owningStatuses`) that must not live in two places.
    struct Snapshot: Sendable {
        let view: WorldView
        let directives: [Directive]
        /// Oldest first, for each brain-managed stall and nothing else.
        let log: [String: [DirectiveLogEntry]]
        /// Read for the why-view's reserve-floor line only; the rail itself is
        /// enforced by `RelayRun` at the moment it would print.
        let hubFootprint: LocationFootprint?
    }

    // MARK: - The greedy pass

    /// What a tick decided to do, before anything is written — a PURE function
    /// of the snapshot: no clock, no database, no dependencies.
    enum Plan {
        /// Nothing to launch, for `reason`. `ranked` is NOT always empty — a tick
        /// idling because every candidate is in flight ranked a full field.
        case idle(reason: String, ranked: [GrowCandidate], prune: PruneAnalysis?)
        /// Launch a Relay Run for `goal` on `carrier`, standing at `hub` and
        /// setting off from `origin`. `hub` rides beside `origin` rather than being
        /// re-derived — `origin` is a lossy projection ("SOL-3" → "SOL"), and
        /// widening the gate's co-location test to the system would let a vessel
        /// that crossed to another location confirm as free. A nil `source` PRINTS
        /// a relay at the hub; non-nil RECLAIMS the one it names.
        case grow(
            goal: Goal, ranked: [GrowCandidate], carrier: String, hub: String, origin: String,
            source: ReclaimChoice?, prune: PruneAnalysis?
        )

        /// The field this pass ranked, whichever way it went — the why-view's
        /// candidate list.
        var ranked: [GrowCandidate] {
            switch self {
            case let .idle(_, ranked, _): ranked
            case let .grow(_, ranked, _, _, _, _, _): ranked
            }
        }

        /// What `PrunePredicate` made of this world, or nil if the pass never
        /// got far enough to ask (no mesh, so no graph and nothing deployed).
        var prune: PruneAnalysis? {
            switch self {
            case let .idle(_, _, prune): prune
            case let .grow(_, _, _, _, _, _, prune): prune
            }
        }

        /// The reclaim this pass CHOSE — not necessarily one that happened; the
        /// confirm-fresh gate runs after this. See `pruneReport`.
        var reclaim: ReclaimChoice? {
            switch self {
            case .idle: nil
            case let .grow(_, _, _, _, _, source, _): source
            }
        }
    }

    /// A reclaim the brain chose, carrying the graph fact that makes it checkable
    /// against the map. A graph fact, never a score.
    struct ReclaimChoice: Equatable, Sendable {
        let relay: ReclaimableRelay
        /// Straight-line light-years from the relay's system to the plant site.
        let distanceLY: Double
    }

    /// Rank `view`'s grow candidates, drop the ones `directives` says are in
    /// flight, take the best remaining. ONE launch per tick, so in-tick double
    /// allocation is structurally impossible rather than guarded. The gates are
    /// ordered so the why-view can distinguish "nothing worth reaching" from
    /// "nothing free to send".
    static func plan(view: WorldView, directives: [Directive]) -> Plan {
        guard !view.meshSystems.isEmpty else {
            // Nil, not an empty partition — prune has not declined, it has not
            // been asked, and the why-view must not claim a tidy mesh.
            return .idle(reason: "no mesh yet", ranked: [], prune: nil)
        }

        let graph = MeshGraph(positions: view.starPositions)
        // Once per tick and BEFORE the gates, so every arm carries it — a spare
        // relay is most worth surfacing on ticks that do nothing with it.
        let prune = PrunePredicate.analyse(view: view, graph: graph)

        let ranked = GrowRanking.rank(view: view, graph: graph)
        guard !ranked.isEmpty else {
            return .idle(reason: "no grow or prune work", ranked: [], prune: prune)
        }

        let inFlight = inFlightTargets(directives)
        guard let candidate = ranked.first(where: { !inFlight.contains($0.firstHop) }) else {
            return .idle(reason: "every grow candidate is already in flight", ranked: ranked, prune: prune)
        }

        // `hubLocation` is already nil for an OFF-MESH hub, so this one guard
        // covers both "no printer" and "a printer we cannot reach".
        guard let hub = view.hubLocation else {
            return .idle(reason: "no print hub on the mesh", ranked: ranked, prune: prune)
        }

        let reserved = reservedDevices(directives: directives, devices: view.devices)
        guard let carrier = freeCarrier(at: hub, devices: view.devices, reserved: reserved) else {
            return .idle(
                reason: carrierBlocker(
                    at: hub, devices: view.devices, reserved: reserved, directives: directives
                ),
                ranked: ranked,
                prune: prune
            )
        }

        return .grow(
            goal: Goal(kind: .tendMesh, target: candidate.firstHop, rationale: rationale(for: candidate)),
            ranked: ranked,
            carrier: carrier.deviceCode,
            hub: hub,
            origin: SiteAssay.system(of: hub),
            source: reclaimSource(
                analysis: prune, view: view, graph: graph, target: candidate.firstHop,
                carrier: carrier, directives: directives
            ),
            prune: prune
        )
    }

    // MARK: - Sourcing the relay

    /// The nearest spare relay in `analysis` within `reclaimRangeLY` of `target`,
    /// or nil to print a fresh one. `PrunePredicate` is the sole authority on
    /// usefulness; the four filters here guard the reclaim FLIGHT — the carrier
    /// must host a replicant (the sequence deactivates the source, so the `stow`
    /// needs a replicant physically present), a declined analysis prints rather
    /// than guesses, a relay another run is fetching is not offered twice, and the
    /// source must not be the plant site's own way onto the mesh. Ties break on
    /// device code after distance.
    ///
    /// **Open gap:** the carrier-host fact is snapshot-only and nothing
    /// re-confirms it, so a replicant that changed hulls since the last account
    /// sync produces exactly the case filter 1 prevents. Recoverable, not fixed.
    static func reclaimSource(
        analysis: PruneAnalysis, view: WorldView, graph: MeshGraph, target: String,
        carrier: Device, directives: [Directive]
    ) -> ReclaimChoice? {
        guard view.replicantHostDevices.contains(carrier.deviceCode) else { return nil }
        guard analysis.declined == nil else { return nil }

        let claimed = inFlightSources(directives)
        let meshLinks = meshNeighbours(of: target, view: view, graph: graph)
        return analysis.reclaimable
            .filter { !claimed.contains($0.deviceCode) }
            .filter { !sourceWouldStrandTheHop($0, meshLinksAtHop: meshLinks) }
            .compactMap { relay -> ReclaimChoice? in
                guard let distance = graph.separation(relay.system, target),
                      distance <= reclaimRangeLY
                else { return nil }
                return ReclaimChoice(relay: relay, distanceLY: distance)
            }
            .min { ($0.distanceLY, $0.relay.deviceCode) < ($1.distanceLY, $1.relay.deviceCode) }
    }

    /// Every system in `view`'s mesh within one `graph` hop of the plant site.
    static func meshNeighbours(
        of hop: String, view: WorldView, graph: MeshGraph
    ) -> Set<String> {
        Set(graph.neighbours(of: hop)).intersection(view.meshSystems)
    }

    /// Would reclaiming `relay` take away the very mesh node the new relay is about
    /// to link to? The one hazard `PrunePredicate` structurally cannot see: grow
    /// and prune leave the mesh by different exits, so a relay at grow's exit sits
    /// on no anchor→target path and reads as spare. Subtracts the whole SYSTEM, so
    /// it over-rejects — that error costs a print, the other costs a mesh node.
    static func sourceWouldStrandTheHop(
        _ relay: ReclaimableRelay, meshLinksAtHop: Set<String>
    ) -> Bool {
        meshLinksAtHop.subtracting([relay.system]).isEmpty
    }

    /// Every relay an in-force directive in `directives` has already been told
    /// to reclaim. Not filtered by `kind`, unlike `inFlightTargets`: a row of
    /// any kind naming a source is a row claiming that relay.
    static func inFlightSources(_ directives: [Directive]) -> Set<String> {
        Set(
            directives
                .filter { owningStatuses.contains($0.status) }
                .compactMap(\.sourceRelayCode)
        )
    }

    // MARK: - Stall response

    /// Auto-retries the brain spends on ONE stall episode before leaving the run
    /// for a human. Each attempt costs at most one API-driving evaluation, so this
    /// is a direct budget of live-API spend per stalled directive per episode.
    static let retryBudget = 3

    /// Minimum gap between two auto-retries of the SAME directive, measured off the
    /// timeline so it costs the stateless brain no memory. **Floored at 5 minutes**
    /// by `hubFreshness` — a retry sooner re-reads numbers the run already
    /// considers current, which makes a `printStockShort` budget unspendable.
    static let retryInterval: TimeInterval = 15 * 60

    /// What the brain does about one halted mission of its own.
    enum StallResponse: Equatable, Sendable {
        /// Drive `retry`; `attempt` of `retryBudget`. `lastAttemptAt` decides who
        /// gets the tick's one retry when several are eligible.
        case retry(
            directiveID: String, reason: DirectiveAttentionReason, attempt: Int, lastAttemptAt: Date?
        )
        /// Budget left, last attempt still inside `retryInterval`. Handled, not
        /// escalated — an operator must not be sent to a run about to retry itself.
        case waiting(directiveID: String, reason: DirectiveAttentionReason)
        /// Left surfaced and untouched for a human.
        case escalated(directiveID: String, reason: DirectiveAttentionReason)

        /// The retry this response asks for, or nil — so the one-action-per-tick
        /// pass can take the FIRST of them.
        var retryAttempt:
            (directiveID: String, reason: DirectiveAttentionReason, attempt: Int, lastAttemptAt: Date?)?
        {
            guard case let .retry(directiveID, reason, attempt, lastAttemptAt) = self else { return nil }
            return (directiveID, reason, attempt, lastAttemptAt)
        }

        /// The escalation this response reports, or nil.
        var escalation: (directiveID: String, reason: DirectiveAttentionReason)? {
            guard case let .escalated(directiveID, reason) = self else { return nil }
            return (directiveID, reason)
        }
    }

    /// The kinds the brain launches and may therefore answer for. `surveyRun`
    /// and `restockRun` stay out: a survey verdict has no stall case at all, and
    /// a restock stall is the hub's, not a mission the brain can retry into.
    static let brainManagedKinds: Set<DirectiveKind> = [
        .relayRun, .salvageRun, .haulRun, .mineRun,
    ]

    /// The reason `directive` is halted on, when the brain may answer it. Kind is
    /// the whole membership rule — the brain adopts every row of a kind it
    /// launches, including one the operator started by hand.
    static func brainManagedStall(_ directive: Directive) -> DirectiveAttentionReason? {
        guard brainManagedKinds.contains(directive.kind), directive.status == .needsAttention else {
            return nil
        }
        return directive.attentionReason
    }

    /// Resolutions `directive` has taken since it last moved step, and when the
    /// latest landed, read off `log` (oldest first). **The episode boundary is the
    /// STEP** — the first entry naming a different step ends the walk, and entries
    /// naming the current step are transparent, `.commandDispatched` included: a
    /// step that re-issues and stalls again has looped, not progressed. Every
    /// `.resolved` counts, whoever drove it.
    static func retryEpisode(_ directive: Directive, log: [DirectiveLogEntry]) -> RetryEpisode {
        var attempts = 0
        var lastAttemptAt: Date?
        walk: for entry in log.reversed() {
            // `.opCompleted` is exempt from the boundary test: it is stamped with
            // the step the command ISSUED from and back-dated, so it can sort after
            // a later step move and would hand out a fresh budget.
            if entry.kind != .opCompleted, let step = entry.step, step != directive.step { break walk }
            guard entry.kind == .resolved else { continue }
            attempts += 1
            if lastAttemptAt == nil { lastAttemptAt = entry.occurredAt }
        }
        return RetryEpisode(attempts: attempts, lastAttemptAt: lastAttemptAt)
    }

    /// The current stall episode's spend, read off the timeline.
    struct RetryEpisode: Equatable, Sendable {
        let attempts: Int
        let lastAttemptAt: Date?
    }

    /// The pure decision for ONE `directive`. Nil for anything that isn't a
    /// brain-managed stall. `.decisionRequest` shares the `.escalate` branch: the
    /// choice is the operator's, and a retry only re-asks the same question. The
    /// switch is exhaustive with no `default:` so a new disposition forces it open.
    static func stallResponse(
        for directive: Directive, log: [DirectiveLogEntry], now: Date
    ) -> StallResponse? {
        guard let reason = brainManagedStall(directive) else { return nil }

        switch reason.brainDisposition {
        case .escalate, .decisionRequest:
            return .escalated(directiveID: directive.id, reason: reason)

        case .retry:
            let episode = retryEpisode(directive, log: log)
            guard episode.attempts < retryBudget else {
                return .escalated(directiveID: directive.id, reason: reason)
            }
            if let last = episode.lastAttemptAt, now.timeIntervalSince(last) < retryInterval {
                // Also catches a stamp in the FUTURE (a clock that moved
                // backwards, an SSE-sourced time we don't control): a negative
                // interval waits rather than retrying, and the tick after the
                // clock catches up retries.
                return .waiting(directiveID: directive.id, reason: reason)
            }
            return .retry(
                directiveID: directive.id, reason: reason,
                attempt: episode.attempts + 1, lastAttemptAt: episode.lastAttemptAt
            )
        }
    }

    /// Drive at most ONE auto-`retry` over `snapshot` and report the first stall
    /// left needing a human. The tick's one retry goes to whichever candidate has
    /// WAITED LONGEST, never-attempted counting as longest — ordering by id alone
    /// starves the tail, leaving the highest-id run held silently forever.
    private func respondToStalls(_ snapshot: Snapshot) async -> DirectiveAttentionReason? {
        // A `stop()` landing mid-read leaves this tick running against rows about
        // to be wiped, where a `retry` is a write with nothing to write to.
        guard !Task.isCancelled else { return nil }

        let responses = snapshot.directives
            .sorted { $0.id < $1.id }
            .compactMap { Self.stallResponse(for: $0, log: snapshot.log[$0.id] ?? [], now: now) }
        guard !responses.isEmpty else { return nil }

        let candidates = responses.compactMap(\.retryAttempt).sorted {
            // `.distantPast` for a never-attempted candidate — it has waited since
            // the stall itself, longer than anyone the brain has already served.
            ($0.lastAttemptAt ?? .distantPast, $0.directiveID)
                < ($1.lastAttemptAt ?? .distantPast, $1.directiveID)
        }
        if let attempt = candidates.first {
            @Dependency(\.directiveResolution) var resolution
            // `.notice` like a launch: a real action on the operator's behalf,
            // bounded by `retryBudget`, so it can never become a heartbeat.
            logger.notice(
                """
                auto-retry \(attempt.attempt, privacy: .public)/\(Self.retryBudget, privacy: .public) on relay run \
                \(attempt.directiveID, privacy: .public) — \(attempt.reason.rawValue, privacy: .public)
                """
            )
            // `retry` and `cancel` are the brain's ENTIRE operator vocabulary.
            await resolution.retry(attempt.directiveID)
        }

        guard let escalation = responses.compactMap(\.escalation).first else { return nil }
        logger.debug(
            """
            relay run \(escalation.directiveID, privacy: .public) left escalated \
            — \(escalation.reason.rawValue, privacy: .public)
            """
        )
        return escalation.reason
    }

    // MARK: - Reservation

    /// Every device code an in-force directive owns — the set a launch must not
    /// allocate out of. `devices` must be the UNFILTERED fleet, since a tagged
    /// device is usually stowed. Seeded from each row's carrier, controller and
    /// fleet tag, then closed to a fixpoint over stow (both directions) and
    /// adoption. Over-reserves by design: spreading through a containment
    /// component costs a tick of patience, the other direction strands a fleet.
    static func reservedDevices(directives: [Directive], devices: [String: Device]) -> Set<String> {
        let owning = directives.filter { owningStatuses.contains($0.status) }
        guard !owning.isEmpty else { return [] }

        var reserved = Set<String>()
        for directive in owning {
            reserved.insert(directive.deviceCode)
            if let controller = directive.controllerCode { reserved.insert(controller) }
            if let tag = directive.fleetTag {
                for device in devices.values where device.hasTag(tag) {
                    reserved.insert(device.deviceCode)
                }
            }
        }

        // `code → everything reserving `code` also reserves`. Every edge TARGET
        // must be a device the fleet holds — a dangling reference names nothing
        // allocatable, and admitting it puts phantom codes in the set.
        var drags: [String: [String]] = [:]
        func link(_ from: String, _ to: String) {
            guard devices[to] != nil else { return }
            drags[from, default: []].append(to)
        }
        for device in devices.values {
            if let hull = device.stowedInDeviceCode {
                link(hull, device.deviceCode)   // downward: the cargo aboard it
                link(device.deviceCode, hull)   // upward: the hull it rides in
            }
            if let controller = device.controllerDeviceCode {
                link(controller, device.deviceCode)
            }
            for adopted in device.controlledDeviceCodes {
                link(device.deviceCode, adopted)
            }
        }

        var frontier = Array(reserved)
        while let code = frontier.popLast() {
            for next in drags[code] ?? [] where reserved.insert(next).inserted {
                frontier.append(next)
            }
        }
        return reserved
    }

    /// A carrier this tick may spend: right type, tagged, standing WITH the print
    /// `hub`, at rest, in neither `reserved` nor busy. Co-location is structural —
    /// the printed clone materialises at the printer, so a vessel elsewhere stalls
    /// on its first evaluation. `min(by:)` on the code, because a stateless brain
    /// must pick the same carrier every tick to stay reproducible.
    static func freeCarrier(
        at hub: String, devices: [String: Device], reserved: Set<String>
    ) -> Device? {
        devices.values
            .filter { isFreeCarrier($0, at: hub, reserved: reserved) }
            .min { $0.deviceCode < $1.deviceCode }
    }

    /// Why there is no free carrier at `hub`, naming which of `directives` holds
    /// each candidate and in what state. A holder the brain may not touch must
    /// read differently from a healthy run that will give the vessel back. Names
    /// two in device-code order and counts the rest, so the sentence is stable.
    static func carrierBlocker(
        at hub: String, devices: [String: Device], reserved: Set<String>, directives: [Directive]
    ) -> String {
        let hulls = devices.values
            .filter { $0.isCarrierHull && $0.location == hub }
            .sorted { $0.deviceCode < $1.deviceCode }
        // A tag on a non-carrier hull is a misapplied opt-in, not an untagged
        // fleet. Moving the tag is location-independent, so the scan is fleet-wide.
        let mistagged = devices.values
            .filter { !$0.isCarrierHull && $0.hasTag(carrierTag) }
            .sorted { $0.deviceCode < $1.deviceCode }
        guard !hulls.isEmpty else {
            guard let clause = mistaggedClause(mistagged, tag: carrierTag) else {
                return "no free carrier at \(hub)"
            }
            return "no free carrier at \(hub) — \(clause)"
        }

        // Untagged is its own state, not folded into the per-vessel clauses
        // below: those explain why a vessel the brain MAY fly is unavailable,
        // where "the operator has not opted this fleet in" has a different
        // remedy and would otherwise read as "all busy".
        let candidates = hulls.filter { $0.hasTag(carrierTag) }
        guard !candidates.isEmpty else {
            let untagged = "no carrier hull at \(hub) is tagged \(carrierTag) — \(list(hulls.map(\.deviceCode))) \(hulls.count == 1 ? "is" : "are") untagged"
            guard let clause = mistaggedClause(mistagged, tag: carrierTag) else { return untagged }
            return "\(untagged); \(clause)"
        }

        let clauses = candidates.map {
            carrierClause($0, reserved: reserved, directives: directives, devices: devices)
        }
        let rest = clauses.count > 2 ? " +\(clauses.count - 2) more" : ""
        return "no free carrier at \(hub) — \(clauses.prefix(2).joined(separator: "; "))\(rest)"
    }

    /// Devices wearing `tag` that are not carrier hulls, as one clause: two
    /// named in device-code order, the rest counted. Nil when there are none.
    private static func mistaggedClause(_ mistagged: [Device], tag: String) -> String? {
        guard !mistagged.isEmpty else { return nil }
        let predicate = mistagged.count == 1
            ? "is tagged \(tag) but is not a carrier hull"
            : "are tagged \(tag) but are not carrier hulls"
        return "\(list(mistagged.map(\.deviceCode))) \(predicate)"
    }

    /// What is wrong with ONE candidate carrier `device`, tested against
    /// `reserved` and then named against `directives` and `devices`. Ownership
    /// is tested before business: a reserved vessel sitting idle at the hub is
    /// the case an operator cannot otherwise explain, where "V1 is travelling"
    /// explains itself.
    private static func carrierClause(
        _ device: Device, reserved: Set<String>, directives: [Directive], devices: [String: Device]
    ) -> String {
        if reserved.contains(device.deviceCode),
           let holder = holdingDirective(of: device.deviceCode, directives: directives, devices: devices)
        {
            return """
                \(device.deviceCode) is held by \(holder.kind.title.lowercased()) \
                \(holder.id) (\(holdDescription(holder)))
                """
        }
        if device.isBusy { return "\(device.deviceCode) is \(device.statusBase)" }
        // Reserved by a directive the fleet cannot explain: its owner names a
        // device we hold no row for.
        return "\(device.deviceCode) is spoken for"
    }

    /// The `holder`'s state, and — when the brain has no power over it — the
    /// fact that waiting will not help. The clause keys on `brainManagedStall`,
    /// so it appears for a kind the brain does not answer for at all.
    private static func holdDescription(_ holder: Directive) -> String {
        switch holder.status {
        case .needsAttention:
            let reason = holder.attentionReason.map { " — \($0.displayName)" } ?? ""
            let orphan = brainManagedStall(holder) == nil ? ", not the brain's to resolve" : ""
            return "needs attention\(reason)\(orphan)"
        case .paused:
            return "paused"
        default:
            return "running"
        }
    }

    /// Which in-force directive in `directives` reserves `code`, by the SAME
    /// closure over `devices` that reserved it — a carrier holding another
    /// run's cargo is reserved by that run through the upward stow edge, and
    /// naming the directive that actually did it is the point.
    ///
    /// Lowest id wins when several own the same device, so the sentence is
    /// reproducible tick to tick.
    static func holdingDirective(
        of code: String, directives: [Directive], devices: [String: Device]
    ) -> Directive? {
        directives
            .filter { owningStatuses.contains($0.status) }
            .sorted { $0.id < $1.id }
            .first { reservedDevices(directives: [$0], devices: devices).contains(code) }
    }

    /// Every first hop a Relay Run is already flying to. Reserving the CARRIER
    /// alone does not cover it: with two free carriers, every tick between launch
    /// and arrival prints a second relay for a system already being meshed.
    static func inFlightTargets(_ directives: [Directive]) -> Set<String> {
        Set(
            directives
                .filter { $0.kind == .relayRun && owningStatuses.contains($0.status) }
                .flatMap(\.targets)
        )
    }

    /// The freedom test over ONE `device`, extracted so the confirm-fresh gate
    /// applies exactly the predicate the ranking applied rather than a cousin of it.
    static func isFreeCarrier(_ device: Device, at hub: String, reserved: Set<String>) -> Bool {
        device.isCarrierHull
            && device.hasTag(carrierTag)
            && device.location == hub
            && !device.isBusy
            && !reserved.contains(device.deviceCode)
    }

    // MARK: - Survey readiness

    /// Whether the brain should launch a Survey Run: a carrier and roam centre,
    /// or a named idle reason. Pure, so the launch path and the why-view read
    /// the same verdict.
    enum SurveyReadiness: Equatable, Sendable {
        case launch(carrier: String, roamCentre: String)
        case idle(reason: String)
    }

    /// The survey verdict for `view`. Staging is judged through `SurveyRun`'s
    /// own fleet queries so the brain and the mission can never disagree about
    /// what "staged" means.
    static func surveyReadiness(view: WorldView) -> SurveyReadiness {
        guard let carrier = surveyCarrier(devices: view.devices) else {
            return .idle(reason: surveyCarrierBlocker(devices: view.devices))
        }

        let world = WorldSnapshot(devices: view.devices, openOperations: [:], now: view.now)
        guard let controller = SurveyRun.controller(aboard: carrier, in: world) else {
            return .idle(reason: "\(carrier.deviceCode) has no survey controller aboard")
        }
        let drones = SurveyRun.adoptedDrones(of: controller, aboard: carrier, in: world)
        guard !drones.isEmpty else {
            return .idle(
                reason: "\(carrier.deviceCode)'s controller \(controller.deviceCode) has adopted no drone aboard"
            )
        }

        // The anchor replicant and the print hub are co-located by construction
        // (nothing enforces it), so the hub's location stands in for the anchor's.
        guard let hub = view.hubLocation else {
            return .idle(reason: "the anchor has no resolvable location")
        }
        let centre = SiteAssay.system(of: hub)
        guard view.starPositions[centre] != nil else {
            return .idle(reason: "roam centre \(centre) is not in the census")
        }

        return .launch(carrier: carrier.deviceCode, roamCentre: centre)
    }

    /// A salvage carrier to launch on, or a named idle reason. No stall case:
    /// launching at an unstaged fleet only manufactures `noMiningControllerAboard`
    /// for a human, so declining is the correct answer.
    enum SalvageReadiness: Equatable, Sendable {
        case launch(carrier: String, roamCentre: String)
        case idle(reason: String)
    }

    /// The salvage vessel wears its FLEET's tag — one string, so a fleet opted
    /// in through the tag can never disagree with the vessel carrying it.
    static let salvageCarrierTag = SalvageRun.defaultFleetTag

    /// The salvage verdict for `view`. Takes `directives` as well, unlike
    /// `surveyReadiness`: the carrier must be free of any OTHER kind's hold, and
    /// an empty list would make that gate vacuous rather than lenient.
    static func salvageReadiness(view: WorldView, directives: [Directive]) -> SalvageReadiness {
        let reserved = reservedDevices(directives: directives, devices: view.devices)
        guard let carrier = view.devices.values
            .filter({ $0.isCarrierHull && $0.hasTag(salvageCarrierTag) })
            .filter({ !reserved.contains($0.deviceCode) })
            .min(by: { $0.deviceCode < $1.deviceCode })
        else {
            // A tag on a non-carrier hull is named — its remedy is moving the
            // tag, not tagging the fleet.
            let mistagged = view.devices.values
                .filter { !$0.isCarrierHull && $0.hasTag(salvageCarrierTag) }
                .sorted { $0.deviceCode < $1.deviceCode }
            guard let clause = mistaggedClause(mistagged, tag: salvageCarrierTag) else {
                return .idle(reason: "no \(salvageCarrierTag) vessel")
            }
            return .idle(reason: "no \(salvageCarrierTag) vessel — \(clause)")
        }

        // Judged through `SalvageRun`'s own queries, so the brain and the
        // mission can never disagree about what staged means.
        let world = WorldSnapshot(devices: view.devices, openOperations: [:], now: view.now)
        guard let controller = SalvageRun.controller(aboard: carrier, in: world) else {
            return .idle(reason: "\(carrier.deviceCode) has no mining controller aboard")
        }
        guard !SalvageRun.adoptedDrones(of: controller, aboard: carrier, in: world).isEmpty else {
            return .idle(
                reason: "\(carrier.deviceCode)'s controller \(controller.deviceCode) has adopted no drone aboard"
            )
        }

        guard let hub = view.hubLocation else {
            return .idle(reason: "the anchor has no resolvable location")
        }
        let centre = SiteAssay.system(of: hub)
        guard view.starPositions[centre] != nil else {
            return .idle(reason: "roam centre \(centre) is not in the census")
        }
        // `tendMesh` is the sole mesh authority, so unmeshed salvage is not this
        // goal's to reach — it waits rather than planting its own relay.
        guard view.salvageUnits.contains(where: { view.meshSystems.contains($0.key) && $0.value > 0 })
        else {
            return .idle(reason: "no meshed salvage system with units left")
        }

        return .launch(carrier: carrier.deviceCode, roamCentre: centre)
    }

    /// A haul controller to launch the general drainer on, or a named idle.
    enum HaulReadiness: Equatable, Sendable {
        case launch(controller: String)
        case idle(reason: String)
    }

    /// Whether `directive` is THE general drainer rather than a per-site row.
    /// A nil tag counts — `HaulRun.fleetTag(of:)` falls back to the default.
    static func isGeneralHaul(_ directive: Directive) -> Bool {
        (directive.fleetTag ?? HaulRun.defaultFleetTag) == HaulRun.defaultFleetTag
    }

    /// The haul verdict for `view`. `HaulRun.controllers` already sorts by code,
    /// so the choice is reproducible across ticks. Takes `directives` for the
    /// same reason `salvageReadiness` does — without it the verdict reports
    /// ready for a controller `ensureOne` will decline every tick, forever.
    static func haulReadiness(view: WorldView, directives: [Directive]) -> HaulReadiness {
        let reserved = reservedDevices(directives: directives, devices: view.devices)
        guard let controller = HaulRun.controllers(
            in: view.devices.values, tag: HaulRun.defaultFleetTag
        ).first(where: { !reserved.contains($0.deviceCode) }) else {
            return .idle(reason: "no free \(HaulRun.defaultFleetTag) controller offering ferry")
        }
        guard view.hubLocation != nil else {
            return .idle(reason: "no print hub on the mesh")
        }
        return .launch(controller: controller.deviceCode)
    }

    // MARK: - Mine readiness

    /// A carrier and the belt to install a permanent mine at, or a named idle.
    enum MineReadiness: Equatable, Sendable {
        case launch(carrier: String, belt: String)
        case idle(reason: String)
    }

    /// The device type that drives a mine's freighter. Matched on TYPE, since a
    /// freshly printed controller carries no directive vocabulary yet.
    static let mineTransportType = "ami_transport_controller"

    /// The mine verdict for `view`. Takes `directives` for `haulReadiness`'s
    /// reason — a carrier another row holds must not be reported ready — and to
    /// keep a belt a live install already targets out of the siting.
    static func mineReadiness(view: WorldView, directives: [Directive]) -> MineReadiness {
        guard let hub = view.hubLocation else { return .idle(reason: "no recognised hub") }

        let fleet = view.devices.values
        let shortfall = MineRecipe.shortfall(at: hub, in: fleet)
        guard shortfall.isEmpty else {
            return .idle(reason: mineFleetBlocker(shortfall, at: hub, in: fleet))
        }

        let reserved = reservedDevices(directives: directives, devices: view.devices)
        guard let carrier = MineRecipe.idleCarrier(
            at: hub, in: fleet.filter { !reserved.contains($0.deviceCode) }
        ) else {
            return .idle(reason: "no idle \(MineRecipe.carrierTag) surge carrier")
        }

        // The hub's own belt is a legal site the estate cannot see: every
        // installed query filters `location != hub`, so a mine there is invisible.
        let unsitable: Set<String> = [hub]
        let occupied = unsitable
            .union(MineRecipe.installedBelts(in: fleet, hub: hub))
            .union(liveMineBelts(directives))
        guard let site = MineSitePlanner.site(view: view, occupiedBelts: occupied) else {
            let anyBelt = MineSitePlanner.site(view: view, occupiedBelts: unsitable) != nil
            return .idle(reason: anyBelt ? "every candidate belt taken" : "no meshed candidate belt")
        }
        return .launch(carrier: carrier.deviceCode, belt: site.belt)
    }

    /// The belts a live `mineRun` is installing at.
    static func liveMineBelts(_ directives: [Directive]) -> Set<String> {
        Set(
            directives
                .filter { $0.kind == .mineRun && owningStatuses.contains($0.status) }
                .flatMap(\.targets)
        )
    }

    /// Nothing printed reads differently from a fleet part-way printed.
    private static func mineFleetBlocker(
        _ shortfall: [String: Int], at hub: String, in devices: some Sequence<Device>
    ) -> String {
        let standing = MineRecipe.unassignedFleet(at: hub, in: devices)
            .values
            .reduce(0) { $0 + $1.count }
        guard standing > 0 else { return "no printed mine fleet" }
        let missing = shortfall.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }
        return "mine fleet incomplete — missing \(missing.joined(separator: ", "))"
    }

    /// The fleet tag a per-mine ferry row wears. Per BELT, never the bare
    /// `MineRecipe.fleetTag`: `reservedDevices` closes over a row's tag, so a
    /// fleet-wide one would reserve every other mine's controller forever.
    static func mineFerryTag(for belt: String) -> String { "\(MineRecipe.fleetTag):\(belt)" }

    /// The transport controller to drain `belt` through: the one already ferrying
    /// it, else the lowest-coded free one. Both arms skip a controller another
    /// live row holds, so this never offers one `ensureOne` would decline.
    static func mineFerryController(
        for belt: String, view: WorldView, directives: [Directive]
    ) -> String? {
        guard let hub = view.hubLocation else { return nil }
        let reserved = reservedDevices(directives: directives, devices: view.devices)
        let candidates = view.devices.values
            .filter {
                $0.deviceType == mineTransportType && $0.hasTag(MineRecipe.fleetTag)
                    && $0.location == hub && !reserved.contains($0.deviceCode)
            }
            .sorted { $0.deviceCode < $1.deviceCode }
        let collecting = { (device: Device) -> String? in
            guard device.currentDirective == HaulTargetPlanner.ferry else { return nil }
            return device.currentDirectiveConfig?["collect"]?.stringValue
        }
        let chosen = candidates.first { collecting($0) == belt }
            ?? candidates.first { collecting($0) == nil }
        return chosen?.deviceCode
    }

    /// The why-view's salvage line. Reads an already-live row FIRST: once a run
    /// owns the fleet its own tag reserves the carrier, so re-deriving would
    /// report "no vessel" about the vessel the operator is looking at.
    static func salvageStatus(directives: [Directive], view: WorldView) -> BrainGoalStatus {
        if let live = directives.first(where: {
            $0.kind == .salvageRun && owningStatuses.contains($0.status)
        }) {
            return .launched(
                vessel: live.deviceCode,
                focus: live.currentTarget,
                status: launchedGoalStatus(live.status)
            )
        }
        switch salvageReadiness(view: view, directives: directives) {
        case let .launch(carrier, _): return .ready(vessel: carrier)
        case let .idle(reason): return .idle(reason: reason)
        }
    }

    /// The why-view's haul line, for the GENERAL drainer only — a per-site row
    /// is a different goal and must not stand in for this one.
    static func haulStatus(directives: [Directive], view: WorldView) -> BrainGoalStatus {
        if let live = directives.first(where: {
            $0.kind == .haulRun && owningStatuses.contains($0.status) && isGeneralHaul($0)
        }) {
            return .launched(
                vessel: live.deviceCode,
                focus: view.hubLocation,
                status: launchedGoalStatus(live.status)
            )
        }
        switch haulReadiness(view: view, directives: directives) {
        case let .launch(controller): return .ready(vessel: controller)
        case let .idle(reason): return .idle(reason: reason)
        }
    }

    /// The why-view's mine line: a live `mineRun` FIRST — an installing fleet
    /// is attached/stowed, so `mineReadiness` would misreport its own blocker
    /// mid-install — else the readiness verdict, exactly as `haulStatus`.
    static func mineStatus(directives: [Directive], view: WorldView) -> BrainGoalStatus {
        if let live = directives.first(where: {
            $0.kind == .mineRun && owningStatuses.contains($0.status)
        }) {
            return .launched(
                vessel: live.deviceCode,
                focus: live.currentTarget,
                status: launchedGoalStatus(live.status)
            )
        }
        switch mineReadiness(view: view, directives: directives) {
        case let .launch(carrier, _): return .ready(vessel: carrier)
        case let .idle(reason): return .idle(reason: reason)
        }
    }

    /// One health reading per installed belt: whether the mining and survey
    /// controllers are actively directed, and whether a tagged transport
    /// controller is ferrying it. A belt a live `mineRun` still targets is
    /// excluded — `MineRun` lands the fleet before arming any directive.
    static func mineHealth(view: WorldView, directives: [Directive]) -> [BrainMineHealth] {
        MineRecipe.installedBelts(in: view.devices.values, hub: view.hubLocation)
            .subtracting(liveMineBelts(directives))
            .sorted()
            .map { belt in
                let mining = mineBeltController(at: belt, type: "ami_mining_controller", in: view)
                let survey = mineBeltController(at: belt, type: "ami_survey_controller", in: view)
                return BrainMineHealth(
                    belt: belt,
                    miningActive: mining?.currentDirective == MineRun.miningDirective
                        && mining?.currentDirectiveStatus == "active",
                    surveyActive: survey?.currentDirective == MineRun.surveyDirective
                        && survey?.currentDirectiveStatus == "active",
                    ferryInForce: view.devices.values.contains {
                        $0.deviceType == mineTransportType && $0.hasTag(MineRecipe.fleetTag)
                            && $0.currentDirectiveConfig?["collect"]?.stringValue == belt
                    }
                )
            }
    }

    /// The tagged controller of `type` standing at `belt` — one per installed
    /// mine by construction.
    private static func mineBeltController(at belt: String, type: String, in view: WorldView) -> Device? {
        view.devices.values.first {
            $0.deviceType == type && $0.hasTag(MineRecipe.fleetTag) && $0.location == belt
        }
    }

    private static func launchedGoalStatus(_ status: DirectiveStatus) -> BrainGoalStatus.LaunchedStatus {
        switch status {
        case .running: .running
        case .needsAttention: .needsAttention
        case .paused: .paused
        case .completed, .cancelled: .running
        }
    }

    /// The why-view's survey line: `.launched` off an already-live row —
    /// never re-deriving carrier, centre or status — otherwise
    /// `surveyReadiness`'s own verdict, carried through for `.launch`/`.idle`.
    static func surveyStatus(directives: [Directive], view: WorldView) -> BrainSurveyStatus {
        if let live = directives.first(where: {
            $0.kind == .surveyRun && owningStatuses.contains($0.status)
        }) {
            return .launched(carrier: live.deviceCode, roamCentre: live.roamCentre, status: launchedStatus(live.status))
        }
        switch surveyReadiness(view: view) {
        case let .launch(carrier, roamCentre): return .ready(carrier: carrier, roamCentre: roamCentre)
        case let .idle(reason): return .idle(reason: reason)
        }
    }

    /// `owningStatuses`' three members, narrowed from the column's five — the
    /// other two never reach here, since the caller above only matches rows
    /// `owningStatuses.contains` already accepted.
    private static func launchedStatus(_ status: DirectiveStatus) -> BrainSurveyStatus.LaunchedStatus {
        switch status {
        case .running: .running
        case .needsAttention: .needsAttention
        case .paused: .paused
        case .completed, .cancelled: .running
        }
    }

    /// The lowest-coded vessel tagged `surveyCarrierTag`, wherever it stands —
    /// survey never co-locates at a hub the way `freeCarrier` requires.
    private static func surveyCarrier(devices: [String: Device]) -> Device? {
        devices.values
            .filter { $0.isCarrierHull && $0.hasTag(surveyCarrierTag) }
            .min { $0.deviceCode < $1.deviceCode }
    }

    /// Mirrors `carrierBlocker`'s register: names the candidates and that they
    /// are untagged (or tagged on a non-carrier), never a bare "unavailable".
    private static func surveyCarrierBlocker(devices: [String: Device]) -> String {
        let hulls = devices.values
            .filter(\.isCarrierHull)
            .sorted { $0.deviceCode < $1.deviceCode }
        let mistagged = devices.values
            .filter { !$0.isCarrierHull && $0.hasTag(surveyCarrierTag) }
            .sorted { $0.deviceCode < $1.deviceCode }
        guard !hulls.isEmpty else {
            guard let clause = mistaggedClause(mistagged, tag: surveyCarrierTag) else {
                return "no vessel is tagged \(surveyCarrierTag)"
            }
            return "no carrier hull — \(clause)"
        }
        let untagged = "no carrier hull is tagged \(surveyCarrierTag) — \(list(hulls.map(\.deviceCode))) \(hulls.count == 1 ? "is" : "are") untagged"
        guard let clause = mistaggedClause(mistagged, tag: surveyCarrierTag) else { return untagged }
        return "\(untagged); \(clause)"
    }

    // MARK: - The rationale

    /// Why `candidate`'s hop, in terms an operator can check against the map. A
    /// GRAPH FACT, never a scalar — "meshing VEGA — 3,200 units, 1 hop", not
    /// "score 0.82". The served-systems clause names where the value is when it is
    /// not at the hop itself.
    static func rationale(for candidate: GrowCandidate) -> String {
        let beyond = candidate.targetsBeyondFirstHop
        let served = beyond.isEmpty ? "" : " at \(list(beyond))"
        return "meshing \(candidate.firstHop) — \(candidate.magnitudeSummary)\(served), \(candidate.hopSummary)"
    }

    /// How this run's relay is being sourced, as a clause for the launch line:
    /// a nil `source` prints, non-nil reclaims. Both arms name their cost,
    /// which is the whole difference between them.
    static func sourcing(_ source: ReclaimChoice?) -> String {
        guard let source else { return "printing a fresh relay at the hub (370 units)" }
        return """
            reclaiming \(source.relay.deviceCode) from \(source.relay.system) \
            (\(String(format: "%.1f", source.distanceLY)) ly out, no resources spent)
            """
    }

    /// Names the first two of `names` and counts the rest — a hop can serve a
    /// large group, and an unbounded list in a log line helps nobody.
    private static func list(_ names: [String]) -> String {
        guard names.count > 2 else { return names.joined(separator: ", ") }
        return "\(names[0]), \(names[1]) +\(names.count - 2) more"
    }

    // MARK: - The confirm-fresh gate

    /// The gate's two — and only two — answers. No third case for "confirm again"
    /// or "try the next candidate": re-ranking on the confirm would make which
    /// system the brain meshes depend on the timing of a network read.
    enum Confirmation: Equatable, Sendable {
        /// Carries the AUTHORITATIVE row the server just gave — the commit-time
        /// re-check judges that, not the local copy.
        case proceed(carrier: Device)
        /// Write nothing; report this. The string is the why-view's line.
        case deferred(reason: String)
    }

    /// The AUTHORITATIVE half of the gate: what the server says about `carrier`
    /// immediately before we commit. Whether the carrier has left the hub is the
    /// one question the local database structurally cannot answer. Ownership is
    /// NOT checked here — anything an async read learned would be stale by the
    /// time the insert opened its transaction, so that half is `commitBlocker`.
    /// A failed confirm defers, fail-closed.
    private func confirmCarrier(_ carrier: String) async -> Confirmation {
        @Dependency(\.deviceRefresher) var deviceRefresher

        guard let fresh = await deviceRefresher.refresh(carrier, .high) else {
            // `.error`: an authoritative read that did not land is a fault, and
            // this line is the only place it is visible.
            logger.error("confirm-read of carrier \(carrier, privacy: .public) failed — deferring launch")
            return .deferred(reason: "\(BrainDecision.deferralPrefix)carrier \(carrier) could not be confirmed")
        }
        return .proceed(carrier: fresh)
    }

    /// The LOCAL half of the gate: any reason `carrier` must not take `target` at
    /// `hub` sourced from `source`? Nil means commit. Re-applies the SAME
    /// `isFreeCarrier`/`inFlightTargets`/`inFlightSources` the selection used —
    /// never re-typed copies — against rows read inside the insert's transaction,
    /// which is what closes the race with the UI launcher. A blocked commit DEFERS
    /// rather than falling back to a print.
    static func commitBlocker(
        carrier: Device, at hub: String, target: String, source: String?,
        directives: [Directive], devices: [String: Device]
    ) -> String? {
        // The freshly-read row is OVERLAID rather than trusted to have landed: the
        // reconciler applies event-time guards we do not control here.
        var fleet = devices
        fleet[carrier.deviceCode] = carrier
        let reserved = reservedDevices(directives: directives, devices: fleet)
        guard isFreeCarrier(carrier, at: hub, reserved: reserved) else {
            return "\(BrainDecision.deferralPrefix)carrier \(carrier.deviceCode) unavailable on confirm"
        }
        guard !inFlightTargets(directives).contains(target) else {
            return "\(BrainDecision.deferralPrefix)\(target) already in flight on confirm"
        }
        if let source, inFlightSources(directives).contains(source) {
            return "\(BrainDecision.deferralPrefix)relay \(source) already claimed on confirm"
        }
        return nil
    }

    // MARK: - The launch

    /// Create the Relay Run row for `goal` on `carrier` — the brain's ONE
    /// enactment on the grow side. A nil `source` prints a relay at the hub,
    /// non-nil reclaims the one it names. `targets` holds the first HOP, not the
    /// value system; the chain beyond is re-derived next tick, which is what keeps
    /// the brain stateless. A failed write degrades to `.idle`, never `.dispatch`.
    ///
    /// **`commitBlocker` runs inside this insert's own transaction, and that
    /// placement is the whole guarantee** — every writer shares one
    /// `DatabaseWriter`, so the re-check either sees a racing row or that row
    /// waits. Checking beforehand would only narrow the window.
    private func launch(
        goal: Goal, ranked: [GrowCandidate], carrier: Device, hub: String, origin: String,
        source: ReclaimChoice?, database: any DatabaseWriter
    ) async -> BrainDecision {
        // A `stop()` can have landed while the confirm-read was in flight, and the
        // row would be wiped moments after the executor dispatched off it.
        guard !Task.isCancelled else { return .idle(reason: "engine stopped") }

        // Resolved out here, never inside the write closure: GRDB runs that
        // closure on its own writer thread, where the task-local dependency
        // scope this tick is running in does not reach.
        @Dependency(\.uuid) var uuid

        let directive = Directive(
            id: uuid().uuidString,
            kind: .relayRun,
            status: .running,
            deviceCode: carrier.deviceCode,
            controllerCode: nil,
            roamCentre: nil,
            fleetTag: nil,
            sourceRelayCode: source?.relay.deviceCode,
            targets: [goal.target],
            targetIndex: 0,
            step: RelayRun().firstStep,
            stepStartedAt: now,
            // The carrier comes home; without it the run leaves the vessel
            // parked at the target until a human flies it back.
            returnToOrigin: true,
            // A record, NOT the return leg's destination: this names the SYSTEM,
            // and travelling to a bare designation lands at the entry point (an
            // L4). `RelayRun.returnHome` re-derives the hub location instead.
            originDesignation: origin,
            attentionReason: nil,
            createdAt: now,
            updatedAt: now
        )
        let blocker: String?
        do {
            blocker = try await database.write { db -> String? in
                let directives = try Directive.all.fetchAll(db)
                let devices = Dictionary(
                    try Device.all.fetchAll(db).map { ($0.deviceCode, $0) },
                    uniquingKeysWith: { _, last in last }
                )
                if let blocker = Self.commitBlocker(
                    carrier: carrier, at: hub, target: goal.target,
                    source: source?.relay.deviceCode,
                    directives: directives, devices: devices
                ) {
                    return blocker
                }
                try Directive.insert { directive }.execute(db)
                return nil
            }
        } catch {
            logger.error("launch of \(directive.id, privacy: .public) failed: \(error)")
            return .idle(reason: "launch failed")
        }
        if let blocker {
            // `.debug`, not `.notice`: this line can repeat every tick (the
            // negative answer only clears once the next snapshot agrees, which
            // a declined reconcile can delay), and the caught race is already
            // reported to the operator through the why-view.
            logger.debug(
                """
                deferred launch on \(carrier.deviceCode, privacy: .public) \
                at \(hub, privacy: .public) — \(blocker, privacy: .public)
                """
            )
            return .idle(reason: blocker)
        }
        // `.notice`: a launch is rare, irreversible in resource terms (it ends
        // either in a 370-unit print or in a live relay torn out of the mesh),
        // and the one brain event an operator reading the log after the fact
        // needs to find. The rationale and the sourcing ride along so the line
        // explains itself without a second lookup.
        logger.notice(
            """
            launched relay run \(directive.id, privacy: .public) on \(carrier.deviceCode, privacy: .public) \
            — \(goal.rationale, privacy: .public), \(Self.sourcing(source), privacy: .public)
            """
        )
        return .dispatch(goal, ranked: ranked)
    }
}
