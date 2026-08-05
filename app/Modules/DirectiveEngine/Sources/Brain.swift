//
//  Brain.swift
//  Replicould — DirectiveEngine
//
//  The automation brain's evaluation entry point, ticked by
//  `DirectiveEngineCore.tickBrain()` alongside the supervisor: one tick reads
//  the world, answers its own halted missions, launches at most one Relay Run,
//  and keeps the hub's restock run stocked against current demand.
//
//  A PURE SELECTOR (`brain-robustness-bar` clause 1). Its whole write
//  vocabulary is inserting a directive and driving the sanctioned
//  `retry`/`cancel` resolution verbs as an automated operator; it never
//  hand-edits a running directive's step/target/status, never issues a command
//  outside the executor → `CommandGovernor` path, and never drives
//  `skipTarget`/`pause`/`resume`, which stay the operator's. It touches only
//  the `relayRun` and `restockRun` rows it writes itself.
//
//  STATELESS between ticks (clause 2): a tick is a pure function of
//  `(WorldView, directive rows)` — no lease table, no cache, no memory, so the
//  ranking, the path-union behind it and the reservation set are recomputed
//  from scratch every tick and a relaunch mid-plan costs nothing.
//  `Directive.sourceRelayCode` is a plan hint on the ROW, not brain memory.
//
//  Ranking runs on a best-effort `WorldView`; every irreversible commitment is
//  gated on a just-in-time `.high` confirm-read (clause 4c), which may only
//  proceed or defer, never re-rank.
//
//  Not an actor: a plain type's `async` methods are nonisolated, so ranking
//  called from `DirectiveEngineCore` (actor-isolated) runs off that actor's
//  serial executor and cannot block the reconciliation loop beside it.
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
    /// The tick's clock reading, supplied by the caller from
    /// `@Dependency(\.date)`. Sampling `Date()` anywhere below instead breaks
    /// `WorldView`'s snapshot and every test built on `TestClock`.
    let now: Date

    /// The device type a grow launch flies: the relay is printed at the hub and
    /// taken aboard a vessel already standing there.
    static let carrierDeviceType = "heaven_vessel"

    /// The tag a vessel must wear before the brain may fly it.
    ///
    /// Opt-in, with no fallback to "any free vessel of the right type": an
    /// untagged fleet means the brain launches NOTHING and says so
    /// (`carrierBlocker`) rather than idling silently, so a fleet the operator
    /// has not opted in stays untouched.
    ///
    /// Spelled in the normalised (lowercase) form the server stores and the
    /// device inspector shows. Compare it only through `Device.hasTag`, which
    /// normalises both sides; a raw `tags.contains` refuses the very vessel that
    /// was just opted in.
    static let carrierTag = "auto:tendmesh"

    /// How far off its road the brain will send a carrier to fetch a spare
    /// relay it could otherwise print.
    ///
    /// Measured from the PLANT SITE (the grow candidate's first hop), never
    /// from the hub: reclaim flies `hub → source → target` against print's
    /// `hub → target`, and the triangle inequality bounds that extra distance
    /// by `2 · d(source, target)` wherever the hub stands, where a cutoff taken
    /// from the hub caps nothing.
    ///
    /// Stated in the mesh's own length scale (`SalvageTargetPlanner
    /// .relayRangeLY`, one relay hop) so it keeps its meaning if that range
    /// changes.
    static let reclaimRangeLY: Double = 2 * SalvageTargetPlanner.relayRangeLY

    /// The statuses in which a directive still OWNS its devices. `paused` and
    /// `needsAttention` keep ownership — the mission is still in force and a
    /// stall the operator is about to resolve must find its fleet intact — so
    /// only a finished mission (`completed`/`cancelled`) gives its devices back.
    ///
    /// `DirectiveRow.owningStatuses` (DirectivesFeature) is a verbatim second
    /// copy of this set. `DirectivesFeature` depends on `DirectiveEngine` and
    /// not the reverse, so neither can import the other's; changing one without
    /// the other drifts the reservation pass from the list row's display join.
    static let owningStatuses: Set<DirectiveStatus> = [.running, .needsAttention, .paused]

    /// Read the world, decide what — if anything — is worth doing, and do it:
    /// one `database.read`, then stall response, the grow plan and restock,
    /// returning everything the why-view needs to explain the tick.
    ///
    /// Stall response runs first, and the two layers do not contend: a
    /// `.needsAttention` directive still OWNS its carrier (`owningStatuses`),
    /// so the reservation pass excludes it either way and a tick may do both.
    ///
    /// **What gets REPORTED, when the tick did more than one thing:** a launch
    /// outranks an escalation, and an escalation outranks idling. `.stall` is
    /// therefore what the tick says when it had nothing better to do AND
    /// something needs a human, which is exactly `BrainWhy`'s `isEscalated`
    /// (`brain-robustness-bar` clause 6: idle is surfaced-calm, a stall is
    /// surfaced-AND-escalated). An auto-retry is not reported through
    /// `BrainDecision` at all — it is an action taken rather than a plan
    /// formed, and is logged instead.
    ///
    /// **Cancellation.** `DirectiveEngineCore.stop()` runs on logout,
    /// immediately before the directive tables are wiped, and cancels the brain
    /// task WITHOUT awaiting it, so a tick suspended in any of the `await`s
    /// below resumes inside a stopped engine and against the previous account.
    /// Every irreversible act therefore re-checks `Task.isCancelled`
    /// immediately before itself rather than once at the top, because each has
    /// its own suspension in front of it.
    func report() async -> BrainReport {
        @Dependency(\.defaultDatabase) var database

        let snapshot: Snapshot
        do {
            snapshot = try await database.read { db in
                let directives = try Directive.all.fetchAll(db)
                // `directiveLogEntries` is append-only and never pruned, so the
                // read is scoped to the brain's own halted missions on the
                // existing `(directiveID, occurredAt)` index rather than
                // sweeping the table every tick.
                //
                // `directiveID` is nullable — a built-in AMI directive's entry
                // keys off `deviceCode` instead — so the bound list is
                // `[String?]` to match the column's type. SQL's `IN` never
                // matches NULL, so a built-in's entry cannot be caught by this
                // however the list is typed.
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
                    // Read in the SAME transaction as everything else: a stock
                    // figure from a different instant than the devices it is
                    // meant to explain describes no world that ever existed.
                    // Only the hub's own row — the rail judges one location.
                    hubFootprint: try view.hubLocation.flatMap { hub in
                        try LocationFootprint.where { $0.location.eq(hub) }.fetchOne(db)
                    }
                )
            }
        } catch {
            logger.error("world read failed: \(error)")
            // No snapshot means no hub reading, but the governor is a separate
            // process-local fact that is still readable — and a tick that could
            // not reach the database is exactly when an operator wants to know
            // whether we are being rate-limited.
            return await BrainReport(
                decision: .idle(reason: "world unavailable"),
                ranked: [],
                hubLocation: nil,
                limits: Self.limits(hubFootprint: nil),
                observedAt: now
            )
        }

        let escalated = await respondToStalls(snapshot)
        let plan = Self.plan(view: snapshot.view, directives: snapshot.directives)
        let decision = await decide(plan, escalated: escalated, database: database)
        await tendRestock(plan: plan, snapshot: snapshot, decision: decision, database: database)

        return await BrainReport(
            decision: decision,
            ranked: plan.ranked,
            hubLocation: snapshot.view.hubLocation,
            limits: Self.limits(hubFootprint: snapshot.hubFootprint),
            prune: Self.pruneReport(
                plan: plan, decision: decision, directives: snapshot.directives
            ),
            observedAt: now
        )
    }

    /// Keep exactly one restock run alive at the hub, printing against current
    /// demand: `plan`'s ranked first hops minus anything already in flight,
    /// written onto the row's `targets`. `snapshot` supplies the world and the
    /// directive ledger, `decision` is this tick's grow outcome, and `database`
    /// takes the write.
    ///
    /// **The brain writes the DEMAND, the run does the printing.** Demand is a
    /// galaxy-wide judgement over `GrowRanking` and needs a `WorldView`, where a
    /// mission only ever gets a target-scoped `WorldSnapshot` (see
    /// `RestockRun.desiredIdle`). Writing the list onto the row it owns is
    /// bookkeeping, not enactment — the print command still comes from the
    /// executor, so `brain-robustness-bar` clause 1 holds.
    ///
    /// **Never hosted on a carrier.** A persistent directive RESERVES its device
    /// (`reservedDevices`), so putting this on a print-capable HEAVEN vessel
    /// would park that vessel out of the fleet forever and no grow could ever
    /// launch. With no dedicated printer at the hub there is simply no restock.
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

    /// The device a restock run may be hosted on: the lowest-coded print-capable
    /// device at `view`'s hub that is NOT a carrier. Hosting it on a carrier
    /// would reserve that vessel out of the fleet permanently.
    static func restockHost(in view: WorldView) -> Device? {
        guard let hub = view.hubLocation else { return nil }
        return view.devices.values
            .filter { $0.isPrintHub && $0.location == hub && $0.deviceType != carrierDeviceType }
            .min { $0.deviceCode < $1.deviceCode }
    }

    /// The prune half of the report: what `plan`'s predicate found, partitioned
    /// against `directives`, plus the reclaim `decision` actually committed to.
    ///
    /// **The reclaim is reported only on a tick that COMMITTED.** `plan` chooses
    /// a source before the confirm-fresh gate runs, and a gate that defers
    /// leaves the relay standing exactly where it was — so reporting the choice
    /// unconditionally would put "reclaiming R9" in front of an operator on a
    /// tick that reclaimed nothing.
    ///
    /// **A relay already spoken for by an in-force run is reported as CLAIMED,
    /// never as spare.** A source stays deployed and `relaying` for the whole
    /// outbound leg of the run coming to fetch it, and stateless prune keeps
    /// returning it for every tick that takes; `inFlightSources` is the same
    /// authority the sourcing side consults, so the card and the selection
    /// cannot disagree about who owns what.
    ///
    /// The tick's own `reclaimed` is subtracted from both lists so no relay is
    /// described twice.
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
            // `respondToStalls` has already logged this escalation with its
            // directive id; a second line would double the per-tick noise.
            if let escalated { return .stall(escalated) }
            // Per-tick, so `.debug` — a 5-second heartbeat at any louder level
            // would bury the launches this file exists to make visible.
            logger.debug("idle — \(reason, privacy: .public)")
            return .idle(reason: reason)

        case let .grow(goal, ranked, carrier, hub, origin, source, _):
            // The confirm-fresh gate (clause 4c), in two halves that cannot be
            // collapsed into one: the AUTHORITATIVE half is a network read and
            // so cannot happen inside a database transaction, and the LOCAL
            // half must happen inside the very transaction that inserts, or it
            // is advice rather than a guarantee. So: read the server, carry the
            // answer into `launch`, and re-check ownership there.
            //
            // Cancelled first — the confirm is a live `.high` read and a
            // logged-out session has no business spending one.
            guard !Task.isCancelled else { return .idle(reason: "engine stopped") }
            switch await confirmCarrier(carrier) {
            case let .deferred(reason):
                // Same precedence as the idle arm: a deferred tick did nothing,
                // so a run already waiting on a human outranks it.
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

    /// The rails as they stand at this tick: the process-shared actions budget
    /// (what is left, and whether the server has recently said 429), and
    /// `hubFootprint` judged against `BrainCeiling`'s reserve floor.
    ///
    /// Reports, never gates. The rails are enforced where they already were —
    /// `CommandGovernor` for the budget, `RelayRun.printStockIsShort` for the
    /// floor — and nothing here can change what a tick does. Read via
    /// `@Dependency(\.gameClient)` so the figure shown is the one every
    /// dispatch throttles on, not a second copy.
    private static func limits(hubFootprint: LocationFootprint?) async -> BrainLimits {
        @Dependency(\.gameClient) var gameClient
        let budget = await gameClient.budget(.actions)
        return BrainLimits(
            actionsRemaining: budget.remaining,
            actionsLimit: budget.limit,
            actionsFloor: CommandGovernorClient.actionFloor,
            hubStock: hubFootprint?.resources,
            // Carried, not dropped: the rail vetoes on the reading's AGE as
            // well as its value, so a figure without its timestamp cannot say
            // what the rail is doing.
            hubStockFetchedAt: hubFootprint?.fetchedAt,
            spendFloor: BrainCeiling.aggregateSpendFloor,
            rateLimitedAt: budget.rateLimitedAt
        )
    }

    /// One consistent read: the galaxy the brain ranks over, the directive
    /// rows that say which of it is already spoken for, and the timelines the
    /// retry budget is derived from. ONE transaction — a carrier freed between
    /// two separate reads would look free to the ranking and reserved to the
    /// reservation pass, and a timeline read after its own row could show a
    /// retry the row hasn't taken.
    ///
    /// `Directive.all`, not a status-filtered query: which statuses own their
    /// devices is a RULE (`owningStatuses`), and splitting it between a SQL
    /// predicate here and the pure pass below is how the two halves drift.
    private struct Snapshot: Sendable {
        let view: WorldView
        let directives: [Directive]
        /// Timeline entries, oldest first, for each brain-managed stall — and
        /// for nothing else.
        let log: [String: [DirectiveLogEntry]]
        /// The print hub's census row, when there is a hub and the census has
        /// one for it. Read for the why-view's reserve-floor line only; the
        /// rail itself is enforced by `RelayRun`, on that mission's own
        /// snapshot, at the moment it would print.
        let hubFootprint: LocationFootprint?
    }

    // MARK: - The greedy pass

    /// What a tick decided to do, before anything is written — a PURE function
    /// of the snapshot: no clock, no database, no dependencies.
    enum Plan {
        /// Nothing to launch, for `reason`. `ranked` is still the whole field
        /// this pass saw and is NOT always empty: a tick that idles because
        /// every grow candidate is already in flight ranked a full field and
        /// chose none of it, and an operator reading that gate needs to see
        /// what "every candidate" means. `prune` rides this arm too — the ticks
        /// an operator most needs to hear that a relay is standing idle are the
        /// ticks that did nothing about it.
        case idle(reason: String, ranked: [GrowCandidate], prune: PruneAnalysis?)
        /// Launch a Relay Run for `goal` on `carrier`, which stands at `hub`
        /// and so sets off from `origin` (the hub's system); `ranked` is the
        /// whole field the choice was made against and `prune` what the
        /// predicate saw, both carried through for the why-view.
        ///
        /// `hub` rides along beside `origin` rather than being re-derived from
        /// it: `origin` is `SiteAssay.system(of: hub)`, a lossy projection
        /// ("SOL-3" → "SOL"), and re-widening the confirm-fresh gate's
        /// co-location test to the system would let a vessel that had crossed
        /// to another location in the same system confirm as free.
        ///
        /// `source` is where the relay comes from: nil PRINTS one at the hub
        /// (370 units, ~800 s), non-nil RECLAIMS the spare relay it names for
        /// nothing at all. See `reclaimSource`.
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

    /// A reclaim the brain chose, carried with the graph fact that makes it
    /// checkable against the map rather than as a bare device code. Same
    /// discipline as `Goal.rationale` — a graph fact, never a score.
    struct ReclaimChoice: Equatable, Sendable {
        let relay: ReclaimableRelay
        /// Straight-line light-years from the relay's system to the plant site.
        let distanceLY: Double
    }

    /// The greedy pass, grow-only: rank `view`'s grow candidates, drop the ones
    /// `directives` says are already in flight, and take the single best
    /// still-available one.
    ///
    /// **One launch per tick.** There is no second allocation within a pass to
    /// double-book with, so in-tick double allocation is structurally
    /// impossible rather than merely guarded; a multi-launch pass would have to
    /// thread a growing reserved set through each allocation.
    ///
    /// The gates are ordered for the why-view's sake: "nothing worth reaching"
    /// and "nothing free to send" are genuinely different states and an
    /// operator needs to be told which one they are in.
    static func plan(view: WorldView, directives: [Directive]) -> Plan {
        guard !view.meshSystems.isEmpty else {
            // No mesh means no graph and nothing deployed to judge, so prune
            // has not declined — it has not been asked. Nil, not an empty
            // partition: the why-view must say nothing rather than claim a tidy
            // mesh.
            return .idle(reason: "no mesh yet", ranked: [], prune: nil)
        }

        let graph = MeshGraph(positions: view.starPositions)
        // ONCE per tick, and BEFORE the gates below, so every arm of this pass
        // carries it: a spare relay is most worth surfacing on the ticks that
        // do nothing with it. `reclaimSource` is handed this result rather than
        // recomputing it, so selection and the report cannot disagree.
        let prune = PrunePredicate.analyse(view: view, graph: graph)

        let ranked = GrowRanking.rank(view: view, graph: graph)
        guard !ranked.isEmpty else {
            return .idle(reason: "no grow or prune work", ranked: [], prune: prune)
        }

        let inFlight = inFlightTargets(directives)
        guard let candidate = ranked.first(where: { !inFlight.contains($0.firstHop) }) else {
            return .idle(reason: "every grow candidate is already in flight", ranked: ranked, prune: prune)
        }

        // The relay has to come from somewhere. `WorldView.hubLocation` is
        // already nil for an OFF-MESH hub, so this one guard covers both "no
        // printer" and "a printer we cannot reach".
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

    /// Where this grow's relay should come from: the nearest spare relay in
    /// `analysis` within `reclaimRangeLY` of `target` (the plant site), or nil
    /// to print a fresh one. `view` and `graph` supply the mesh and its
    /// distances, `carrier` is the vessel that would fetch it, and `directives`
    /// says which relays are already spoken for.
    ///
    /// Nothing is reclaimed speculatively: a relay leaves the mesh only at the
    /// moment a grow has somewhere better to put it, which is what keeps the
    /// brain stateless — `sourceRelayCode` is a plan hint on the ROW, and the
    /// whole judgement is re-derived next tick.
    ///
    /// **`PrunePredicate` is the sole authority on usefulness** and nothing
    /// here second-guesses it. The four filters are about something else:
    ///
    ///   1. **The carrier must host a replicant.** The reclaim sequence
    ///      deactivates the source, taking its system off the mesh, so the
    ///      `stow` that must follow is commandable only under
    ///      `ftl-authority-rule` rule (1) — a replicant physically present.
    ///      Sending a carrier without one costs a run and holds the vessel out
    ///      of the fleet through three retries and an escalation. Print works
    ///      on any hull, so the fallback is to print rather than to pick a
    ///      different carrier.
    ///   2. **A declined analysis sources a print, never a guess.** `declined`
    ///      means the predicate refused to judge this world, so its empty
    ///      `reclaimable` list is a consequence of the refusal rather than a
    ///      finding.
    ///   3. **A relay another run is already fetching is not offered twice.** A
    ///      source stays deployed and `relaying` for the whole flight of the run
    ///      coming to collect it, so stateless prune keeps returning it and
    ///      without this a second carrier is sent to deactivate the same relay.
    ///      Re-checked at commit time, for the reason `inFlightTargets` is.
    ///   4. **The source must not be the plant site's own way onto the mesh** —
    ///      see `sourceWouldStrandTheHop`.
    ///
    /// Ties break on device code after distance, so the same world produces the
    /// same choice every tick.
    ///
    /// **The carrier-host fact is SNAPSHOT-ONLY and nothing re-confirms it.**
    /// `confirmCarrier` spends its `.high` read on the DEVICE row, nothing
    /// re-reads `replicants`, and `RelayRun.carrierRetainsAuthority` only fires
    /// AFTER the `deactivate` — so a replicant that changed hulls since the last
    /// account sync produces exactly the case gate 1 exists to prevent. It is
    /// recoverable (the source is load-bearing for nothing by construction) but
    /// open.
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

    /// The meshed systems the plant site `hop` could link to: every system in
    /// `view`'s mesh within one `graph` hop of it.
    static func meshNeighbours(
        of hop: String, view: WorldView, graph: MeshGraph
    ) -> Set<String> {
        Set(graph.neighbours(of: hop)).intersection(view.meshSystems)
    }

    /// Would reclaiming `relay` take away the very mesh node the new relay is
    /// about to link to? True when `meshLinksAtHop` — the plant site's meshed
    /// neighbours — holds nothing but the relay's own system.
    ///
    /// **The one hazard `PrunePredicate` structurally cannot see.** Grow's
    /// `MeshGraph.reach` seeds every mesh system and keys on
    /// distance-from-the-mesh while prune's `pathUnion` seeds the anchor alone
    /// and keys on distance-from-the-hub, so on chains that tie on relay count
    /// the two searches leave the mesh by DIFFERENT exits and a relay standing
    /// at grow's exit is genuinely on no anchor→target path. Reclaim it and the
    /// run deactivates the source, plants at the hop, meshes nothing, and stalls
    /// at `settling` with the fleet one node down. `reclaimRangeLY` aims
    /// straight at the hazard: the relays nearest the plant site are precisely
    /// its candidate links.
    ///
    /// It subtracts the whole SYSTEM rather than the one relay, so it also
    /// rejects a source whose system holds a second relay. That error costs a
    /// print; the other direction costs the grow AND a mesh node.
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

    /// How many auto-retries the brain will spend on ONE stall episode before
    /// it stops and leaves the run for a human.
    ///
    /// Each attempt costs at most one API-driving evaluation (a `.high`
    /// confirm-read, a census refresh, or a re-issued command), so this is a
    /// direct budget of live-API spend per stalled directive per episode: a
    /// condition that survives three re-evaluations spread over `retryInterval`
    /// each is structural rather than transient, and retrying past that pays
    /// forever on a run that will never self-correct while holding its carrier
    /// out of the fleet.
    static let retryBudget = 3

    /// The minimum gap between two auto-retries of the SAME directive, measured
    /// off the timeline (the last resolution in the episode) so it costs the
    /// stateless brain no memory between ticks.
    ///
    /// **Floored by what a retry can learn.** `RelayRun.acquire` believes the
    /// hub's row for `hubFreshness` (5 min) before re-reading it, and
    /// `footprintCensusIsStale` gates the census the same way, so a retry
    /// sooner than that re-reads numbers the run itself considers current and
    /// can only burn an attempt — any floor below 5 minutes makes a
    /// `printStockShort` budget unspendable by construction. Anchored on the
    /// work: one relay print is ~800 s and the resupply that clears a shortage
    /// is at least one delivery cycle, so `retryBudget` attempts span ~30
    /// minutes (the first is unspaced — at the first stall there is no
    /// `.resolved` entry to measure an interval from).
    ///
    /// **Erring long is the safe direction.** The row sits in `.needsAttention`
    /// with its reason and guidance throughout, so a longer floor delays only
    /// the moment the BRAIN gives up; erring short escalates permanently,
    /// because a halted run cannot move step and so its `attempts` never falls
    /// back below the budget.
    static let retryInterval: TimeInterval = 15 * 60

    /// What the brain does about one halted mission of its own.
    enum StallResponse: Equatable, Sendable {
        /// Drive `retry` on this directive; `attempt` of `retryBudget`.
        /// `lastAttemptAt` is when this directive was last resolved (nil if
        /// never) — how long it has been waiting, which is what decides who
        /// gets the tick's one retry when several are eligible.
        case retry(
            directiveID: String, reason: DirectiveAttentionReason, attempt: Int, lastAttemptAt: Date?
        )
        /// Budget left, but the last attempt is still inside `retryInterval`.
        /// Handled, not escalated — an operator must not be told to look at a
        /// run the brain is about to try again.
        case waiting(directiveID: String, reason: DirectiveAttentionReason)
        /// Left surfaced and untouched for a human.
        case escalated(directiveID: String, reason: DirectiveAttentionReason)

        /// The retry this response asks for, or nil if it asks for none, so the
        /// one-action-per-tick pass can take the FIRST of them.
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

    /// The reason `directive` is halted on, when the brain is allowed to answer
    /// it: its OWN missions, halted and surfaced. Nil for anything else.
    ///
    /// `kind == .relayRun` is the whole membership rule. A Survey Run or a
    /// Salvage Run the operator launched belongs to the operator — a
    /// `.retry`-disposition reason on one of those is not an invitation, and
    /// answering it would be the brain quietly taking over missions nobody
    /// gave it.
    static func brainManagedStall(_ directive: Directive) -> DirectiveAttentionReason? {
        guard directive.kind == .relayRun, directive.status == .needsAttention else { return nil }
        return directive.attentionReason
    }

    /// How many resolutions `directive` has taken since it last moved to a
    /// different step, and when the most recent of them landed, read off `log`
    /// (that directive's timeline, oldest first).
    ///
    /// **The retry budget lives in the timeline rather than in the brain**,
    /// which holds no state between ticks (`brain-robustness-bar` clause 2).
    /// Every resolution writes a `.resolved` entry
    /// (`DirectiveResolutionClient.apply`) and every stall a `.stalled` one
    /// (`DirectiveExecutor.stall`), in the same transaction as the row change,
    /// so a count read back off them survives a relaunch and can never disagree
    /// with what actually happened.
    ///
    /// **The episode boundary is the STEP.** Walking back from the newest
    /// entry, the first one naming a step other than the directive's current
    /// one ends the walk: everything before it belongs to an earlier visit and
    /// buys a fresh budget. Entries naming the current step are transparent,
    /// `.commandDispatched` included — a step that re-issues its command and
    /// stalls again has not progressed, it has looped, and treating the dispatch
    /// as progress would reset the budget on exactly the loop it bounds.
    ///
    /// **`.opCompleted` is exempt from the boundary test entirely**, not merely
    /// uncounted: `DirectiveExecutor.recordCompletedOps` stamps it with the step
    /// the command was ISSUED from and back-dates `occurredAt`, so an audit
    /// entry naming an OLD step can legitimately sort AFTER the step move that
    /// followed it. Letting it end the walk would discard resolutions genuinely
    /// taken on the current step and hand the directive a fresh budget — and
    /// the audit pass is audit-only by contract, so it must not be able to
    /// change what the brain does in either direction.
    ///
    /// **Every `.resolved` entry counts, not just the brain's own retries.** A
    /// resolution of any kind followed by no progress is an attempt that did
    /// not work, and string-matching the display `summary` instead errs toward
    /// reading an unrecognised entry as "not an attempt" and handing the brain
    /// more retries.
    static func retryEpisode(_ directive: Directive, log: [DirectiveLogEntry]) -> RetryEpisode {
        var attempts = 0
        var lastAttemptAt: Date?
        walk: for entry in log.reversed() {
            // `.opCompleted` never ends the walk — see the doc above.
            if entry.kind != .opCompleted, let step = entry.step, step != directive.step { break walk }
            guard entry.kind == .resolved else { continue }
            attempts += 1
            // Walking newest-first, so the first one seen is the latest.
            if lastAttemptAt == nil { lastAttemptAt = entry.occurredAt }
        }
        return RetryEpisode(attempts: attempts, lastAttemptAt: lastAttemptAt)
    }

    /// The current stall episode's spend, read off the timeline.
    struct RetryEpisode: Equatable, Sendable {
        let attempts: Int
        let lastAttemptAt: Date?
    }

    /// The pure decision for ONE `directive`, against its `log` and the tick's
    /// `now`. Nil for anything that isn't a brain-managed stall.
    ///
    /// The switch over `brainDisposition` is exhaustive with no `default:` — a
    /// disposition added later must force this open rather than silently
    /// inheriting whichever branch happened to be the fallthrough.
    ///
    /// **`.decisionRequest` shares the `.escalate` branch.** A decision request
    /// is by definition the human-in-the-loop seam (`brain-executor-seam`): the
    /// CHOICE is the operator's, and retrying is not a neutral option either —
    /// it re-runs the step that asked the question and gets asked it again. So:
    /// surface it, touch nothing.
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

    /// Drive at most one auto-`retry` over `snapshot`, and report the first
    /// stall left needing a human (nil if none is).
    ///
    /// **One retry per tick**, the same discipline `plan` applies to launches.
    /// With N free carriers in a resource-short world the brain can put N Relay
    /// Runs into `.needsAttention` with the same reason, and without this rule a
    /// single tick would fire N retries at once; combined with the per-directive
    /// `retryInterval`, the stall-driven API rate is bounded both per-directive
    /// and per-tick.
    ///
    /// **The tick's one retry goes to whichever candidate has WAITED LONGEST**
    /// (never-attempted counts as longest), with the directive id as tie-break.
    /// Ordering by id alone starves the tail: a low-id directive that has just
    /// become eligible again always outranks the highest-id one, which is then
    /// never retried, never spends budget, never reaches `.escalated`, and so is
    /// held silently and reported to nobody.
    ///
    /// Escalations are reported lowest-id-first instead — they are a report
    /// rather than an action, and `BrainDecision.stall` carries one reason.
    private func respondToStalls(_ snapshot: Snapshot) async -> DirectiveAttentionReason? {
        // A `stop()` landing while the snapshot read was in flight leaves this
        // tick running against an account whose directive rows are about to be
        // wiped — driving `retry` on one is a write with nothing to write to.
        guard !Task.isCancelled else { return nil }

        let responses = snapshot.directives
            .sorted { $0.id < $1.id }
            .compactMap { Self.stallResponse(for: $0, log: snapshot.log[$0.id] ?? [], now: now) }
        guard !responses.isEmpty else { return nil }

        let candidates = responses.compactMap(\.retryAttempt).sorted {
            // `.distantPast` for a never-attempted candidate: it has been
            // waiting since the stall itself, which is longer than anyone the
            // brain has already served.
            ($0.lastAttemptAt ?? .distantPast, $0.directiveID)
                < ($1.lastAttemptAt ?? .distantPast, $1.directiveID)
        }
        if let attempt = candidates.first {
            @Dependency(\.directiveResolution) var resolution
            // `.notice`, like a launch and unlike everything else per-tick: an
            // auto-retry is a real action taken on the operator's behalf, and
            // it is bounded by construction (at most `retryBudget` per
            // episode), so it can never become a heartbeat.
            logger.notice(
                """
                auto-retry \(attempt.attempt, privacy: .public)/\(Self.retryBudget, privacy: .public) on relay run \
                \(attempt.directiveID, privacy: .public) — \(attempt.reason.rawValue, privacy: .public)
                """
            )
            // `retry` and `cancel` are the brain's ENTIRE operator vocabulary;
            // `skipTarget`, `pause` and `resume` are the operator's,
            // permanently.
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

    /// Every device code an in-force directive in `directives` owns — the set a
    /// launch must not allocate out of. `devices` must be the UNFILTERED fleet:
    /// a tagged device is usually stowed, and only `WorldView.read`'s
    /// `Device.all` makes it visible here at all.
    ///
    /// The running directive ROWS are the lease ledger (`brain-executor-seam`);
    /// there is no separate lease table. Four fields seed the set:
    ///
    ///   1. `deviceCode` — the mission's carrier.
    ///   2. Everything transitively stowed inside it (see the closure below).
    ///   3. `controllerCode` — the AMI the mission is driving.
    ///   4. `fleetTag` — every device wearing it, because a tag is how a Haul
    ///      Run names a working set no column points at.
    ///
    /// The seed is then closed to a fixpoint over three containment relations,
    /// because the seed alone is not "every device an in-force directive owns":
    ///
    ///   - **Stow, downward** (`parent → children`). A relay aboard a carrier,
    ///     a drone aboard a controller aboard a carrier: the whole subtree
    ///     travels with the mission.
    ///   - **Stow, upward** (`child → its hull`). Directive D owns device X, X
    ///     is stowed inside vessel V, and V is named by no directive. Without
    ///     this edge V reads as free, `freeCarrier` picks it, and the Relay Run
    ///     flies away with another mission's device in the hold.
    ///   - **Adoption** (`controller → adopted drones`), read from BOTH ends
    ///     exactly as `AMIFleet.adoptedDrones(of:in:)` does — the drone's
    ///     `controllerDeviceCode` column AND the controller's
    ///     `controlledDeviceCodes`. `controlled_devices` ships only in the
    ///     single-device payload and a routine fleet sync ERASES it
    ///     (`controlled-devices-detail-only`), so the column is the reliable end
    ///     and the blob is the bonus. A deployed drone adopted by a reserved
    ///     controller is owned even though it is stowed nowhere.
    ///
    /// Every stow read is through the CHILD's own `stowedInDeviceCode` column,
    /// never the parent's `stowed_devices` blob, which is not a reliable
    /// inverse — the same reason `RelayRun.confirmStow` reads the child end.
    ///
    /// **Deliberately over-reserving rather than under-.** The closure spreads
    /// through a containment component, so one owned drone can reserve a hull
    /// and its other contents. That direction of error costs a tick of
    /// patience; the other direction strands somebody's fleet.
    ///
    /// **Terminates** on any input, including corrupt ones: a code joins the
    /// frontier only on the pass that first inserts it into `reserved`, so a
    /// stow cycle (A aboard B aboard A) closes instead of looping.
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

        // `code → everything reserving `code` also reserves`.
        //
        // Every edge TARGET must be a device the fleet actually holds. A
        // dangling reference — a hull we have no row for, an adoption list
        // naming a device a sync has not brought in — names nothing this brain
        // could allocate anyway, and admitting it would put phantom codes in a
        // set whose whole meaning is "real devices, spoken for".
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

    /// A carrier this tick may spend, chosen out of `devices`: the right type,
    /// tagged, standing WITH the print `hub`, at rest, and in neither
    /// `reserved` nor busy.
    ///
    /// Co-location is the composition, not a preference — `RelayRun.acquire`
    /// looks for a print-capable device at the CARRIER's own location because
    /// the printed clone materialises at the printer, so a vessel anywhere else
    /// stalls `unreachableDevice` on its first evaluation.
    ///
    /// `isBusy` is checked beside `reserved` because it answers a different
    /// question: a vessel mid-travel belongs to no directive, so reservation
    /// cannot see it, but it is just as unavailable.
    ///
    /// `min(by:)` on the code, matching `RelayRun.hub(near:)`: dictionary
    /// iteration order is not guaranteed, and a stateless brain that re-ranks
    /// every tick must pick the SAME carrier every tick or its own decisions
    /// stop being reproducible.
    static func freeCarrier(
        at hub: String, devices: [String: Device], reserved: Set<String>
    ) -> Device? {
        devices.values
            .filter { isFreeCarrier($0, at: hub, reserved: reserved) }
            .min { $0.deviceCode < $1.deviceCode }
    }

    /// Why there is no free carrier at `hub` — the sentence the why-view shows
    /// when `freeCarrier` comes back nil, naming for each tagged candidate in
    /// `devices` which of `directives` holds it (through `reserved`) and in
    /// what state.
    ///
    /// A holder the brain may not touch must read differently from a healthy
    /// run that will give the vessel back: a `needsAttention` mission of a kind
    /// `brainManagedStall` refuses holds its carrier FOREVER, and rendering
    /// that as the same calm idle is the confusion `brain-robustness-bar`
    /// clause 6 forbids. It stays a graph fact — who holds what, and in what
    /// state — never a recommendation.
    ///
    /// **No candidate at all keeps the bare sentence.** With nothing of the
    /// carrier type standing at the hub there is no holder to name and no state
    /// to disambiguate.
    ///
    /// Candidates are named in device-code order, matching `freeCarrier`'s
    /// `min(by:)`, so the sentence a stateless brain produces is the same every
    /// tick. Two are named and the rest counted.
    static func carrierBlocker(
        at hub: String, devices: [String: Device], reserved: Set<String>, directives: [Directive]
    ) -> String {
        let hulls = devices.values
            .filter { $0.deviceType == carrierDeviceType && $0.location == hub }
            .sorted { $0.deviceCode < $1.deviceCode }
        guard !hulls.isEmpty else { return "no free carrier at \(hub)" }

        // Untagged is its own state, not folded into the per-vessel clauses
        // below: those explain why a vessel the brain MAY fly is unavailable,
        // where "the operator has not opted this fleet in" has a different
        // remedy and would otherwise read as "all busy".
        let candidates = hulls.filter { $0.hasTag(carrierTag) }
        guard !candidates.isEmpty else {
            let names = hulls.prefix(2).map(\.deviceCode).joined(separator: ", ")
            let rest = hulls.count > 2 ? " +\(hulls.count - 2) more" : ""
            return "no vessel at \(hub) is tagged \(carrierTag) — \(names)\(rest) \(hulls.count == 1 ? "is" : "are") untagged"
        }

        let clauses = candidates.map {
            carrierClause($0, reserved: reserved, directives: directives, devices: devices)
        }
        let rest = clauses.count > 2 ? " +\(clauses.count - 2) more" : ""
        return "no free carrier at \(hub) — \(clauses.prefix(2).joined(separator: "; "))\(rest)"
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
    /// fact that waiting will not help. `brainManagedStall` is the authority on
    /// that second half rather than a re-typed `kind == .relayRun`, so the
    /// sentence cannot promise something the brain will not do.
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

    /// Every first hop a Relay Run in `directives` is already flying to; a hop
    /// in this set is not a candidate. Reserving the CARRIER alone does not
    /// cover it: with two free carriers, every tick between launch and arrival
    /// would print a second relay (370 units, ~800 s) for a system already being
    /// meshed, and the loser would find the target meshed on arrival.
    ///
    /// Shared by the selection pass and the commit-time re-check for the same
    /// reason `isFreeCarrier` is: a commitment must be re-tested against the
    /// predicate that admitted it, not against a re-typed cousin of it.
    static func inFlightTargets(_ directives: [Directive]) -> Set<String> {
        Set(
            directives
                .filter { $0.kind == .relayRun && owningStatuses.contains($0.status) }
                .flatMap(\.targets)
        )
    }

    /// The freedom test itself, over ONE `device` at `hub` against `reserved` —
    /// extracted so the confirm-fresh gate applies exactly the predicate the
    /// ranking applied. A gate that re-tested "free" more loosely would wave
    /// through the very carrier selection would now reject; one that tested it
    /// more strictly would defer ticks with nothing wrong with them.
    static func isFreeCarrier(_ device: Device, at hub: String, reserved: Set<String>) -> Bool {
        device.deviceType == carrierDeviceType
            && device.hasTag(carrierTag)
            && device.location == hub
            && !device.isBusy
            && !reserved.contains(device.deviceCode)
    }

    // MARK: - The rationale

    /// Why `candidate`'s hop, in terms an operator can check against the map.
    ///
    /// A GRAPH FACT, never a scalar — "meshing VEGA — 3,200 units, 1 hop", not
    /// "score 0.82". `Goal.rationale` is read by a human (it is the why-view's
    /// headline and the launch log line), and collapsing `GrowRanking`'s
    /// field-by-field key back into a number here would throw that away.
    ///
    /// The served-systems clause names where the VALUE is when it is not at
    /// the hop itself; without it a two-hop grow reads as a hop toward nothing,
    /// at a system with no value of its own.
    ///
    /// Composed from `GrowCandidate`'s own vocabulary (`magnitudeSummary`,
    /// `hopSummary`, `targetsBeyondFirstHop`) rather than restating it, so
    /// this sentence and the why-view's per-candidate rows describe the same
    /// candidate the same way by construction.
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

    /// The gate's two — and only two — answers. There is no third case for
    /// "confirm again", "try the next candidate", or "take a different
    /// carrier": the confirm is not a second selection pass, and re-ranking on
    /// it would make WHICH system the brain meshes depend on the timing of a
    /// network read, which is precisely the dependence the gate exists to
    /// remove.
    enum Confirmation: Equatable, Sendable {
        /// Proceed to commit, carrying the AUTHORITATIVE row the server just
        /// gave — the commit-time re-check judges that, not the local copy it
        /// may or may not have been reconciled into.
        case proceed(carrier: Device)
        /// Write nothing; report this. The string is the why-view's line, so
        /// it names the carrier and reads as a sentence.
        case deferred(reason: String)
    }

    /// The AUTHORITATIVE half of the gate: what the server says about
    /// `carrier`, right now, immediately before we commit to it.
    ///
    /// `plan` ranks over a `WorldView` that may be seconds old and nothing
    /// refreshes an idle vessel's row by itself, so whether the carrier has left
    /// the hub or picked up an errand is the one question the local database
    /// structurally cannot answer, and it is the one this read is spent on.
    ///
    /// It does not also check ownership, and cannot do so safely: this is an
    /// `async` network read, so anything it learned about the directive ledger
    /// would be stale by the time the insert opened its own transaction. That
    /// half lives inside the write transaction (`commitBlocker`, in `launch`).
    ///
    /// **A failed confirm defers** — fail-closed. A `.high` refresh is
    /// suppressed by neither the TTL nor the read-budget floor
    /// (`PollCoordinator.refresh` applies both to `.low` only), so nil here
    /// means the authoritative read genuinely did not land, and "we could not
    /// confirm" is not "it is fine". It reports its own distinct reason so an
    /// operator can tell an API problem from a carrier that was taken.
    ///
    /// Called only from the `.grow` arm — a tick that has already decided to
    /// commit — which is what keeps a 5-second loop from becoming a `.high`
    /// read every 5 seconds. The ceiling is one `.high` read per tick for ONE
    /// device, sustained only while a launchable candidate keeps being refused;
    /// remembering the refusal instead would be state between ticks (clause 2).
    private func confirmCarrier(_ carrier: String) async -> Confirmation {
        @Dependency(\.deviceRefresher) var deviceRefresher

        guard let fresh = await deviceRefresher.refresh(carrier, .high) else {
            // `.error`, not `.notice`: an authoritative read that did not land
            // is a fault, and this line is the only place it is visible. It can
            // repeat per tick, but the condition is itself the fault rather
            // than chatter about a healthy world.
            logger.error("confirm-read of carrier \(carrier, privacy: .public) failed — deferring launch")
            return .deferred(reason: "\(BrainDecision.deferralPrefix)carrier \(carrier) could not be confirmed")
        }
        return .proceed(carrier: fresh)
    }

    /// The LOCAL half of the gate, as a pure function of one consistent set of
    /// rows: is there any reason `carrier` must not take `target` at `hub`,
    /// sourced from `source`, given `directives` and `devices`? Nil means
    /// commit.
    ///
    /// It re-applies the predicates the SELECTION applied, against rows read
    /// inside the insert's own transaction:
    ///
    ///   - `isFreeCarrier`, over the reservation closure — the half that closes
    ///     the operator race. A UI launcher (`NewDirectiveFeature`) writes a
    ///     `directives` row on a vessel the operator picked and touches no
    ///     device row at all, so a gate that re-read only the vessel would see
    ///     an idle heaven vessel standing at the hub and commit straight into a
    ///     collision — two directives owning one carrier.
    ///   - `inFlightTargets` — latent while nothing else writes a `.relayRun`,
    ///     live the moment a second brain-side launcher lands. Missing it costs
    ///     the same 370-unit, ~800 s duplicate print the selection-side filter
    ///     exists to prevent.
    ///   - `inFlightSources` — the same argument for the RECLAIM half, where
    ///     losing the race is worse: two carriers converge on one relay, the
    ///     second finds it already stowed aboard somebody else and stalls
    ///     (`RelayRun.reclaimDiagnosis`), and the mesh has lost a node for one
    ///     grow instead of two.
    ///
    /// A blocked commit DEFERS the whole tick rather than falling back to a
    /// print: the decision was made outside this transaction, and the gate's
    /// contract is to let it through or stop it, never to substitute a
    /// different, resource-spending one.
    ///
    /// All three are the SAME functions the selection used, never re-typed
    /// copies: a commit-time check that drifted looser than selection would
    /// wave through exactly the case selection would now reject.
    static func commitBlocker(
        carrier: Device, at hub: String, target: String, source: String?,
        directives: [Directive], devices: [String: Device]
    ) -> String? {
        // The freshly-read row is OVERLAID rather than trusted to have landed:
        // `deviceRefresher` reconciles what it reads, but the reconciler
        // applies event-time guards we do not control here, and the answer this
        // acts on must be the one the server just gave.
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
    /// enactment on the grow side. `ranked` rides into the returned decision for
    /// the why-view, `hub` and `origin` say where the run sets off from,
    /// `source` decides whether the relay is printed or reclaimed, and
    /// `database` takes the write.
    ///
    /// The fields below are the whole interface between the brain and the
    /// mission, and each is a decision:
    ///
    ///   - `sourceRelayCode` — where the relay comes from, and the one field
    ///     here that is a JUDGEMENT rather than a constant. Nil prints a fresh
    ///     one at the hub (370 units, ~800 s); non-nil sends the carrier to
    ///     reclaim the spare relay it names, for no resources at all. See
    ///     `reclaimSource` for how it is chosen and `RelayRun.acquire` for the
    ///     two branches it selects between.
    ///   - `fleetTag: nil` / `controllerCode: nil` — ownership is the carrier
    ///     and nothing else; the relay is held by transitive stow.
    ///   - `roamCentre: nil` — a Relay Run is one-shot (`RelayRun.plan`
    ///     answers `.exhausted`); the brain launches a fresh directive per
    ///     target rather than asking one run to roam.
    ///   - `targets: [goal.target]` — the first HOP, not the value system. The
    ///     chain beyond it is re-derived next tick from the grown mesh, which
    ///     is what keeps the brain stateless.
    ///
    /// A failed write degrades to `.idle`, never to `.dispatch`: the decision
    /// reports what the tick DID, and claiming a launch that did not land
    /// would put a lie in the why-view and in the log.
    ///
    /// **The confirm-fresh gate's local half runs HERE, inside the insert's own
    /// transaction, and that placement is the whole guarantee.** Checking
    /// ownership beforehand — in a transaction that commits and returns — only
    /// narrows the window: a UI launcher committing in the gap between that
    /// read and this write is not seen, and the tick inserts a second directive
    /// owning the same carrier, which is the exact failure this gate exists to
    /// prevent. Every writer in the app goes through this one `DatabaseWriter`,
    /// so a re-check taken inside the write transaction cannot be interleaved
    /// with: it either sees the racing row or the racing row waits for us.
    ///
    /// The residual window is the one nothing local can close: the carrier's
    /// SERVER state at the instant the confirm-read returned — measured in
    /// milliseconds since that read rather than in seconds since the snapshot.
    private func launch(
        goal: Goal, ranked: [GrowCandidate], carrier: Device, hub: String, origin: String,
        source: ReclaimChoice?, database: any DatabaseWriter
    ) async -> BrainDecision {
        // A `stop()` can have landed while the confirm-read above was in
        // flight. Inserting here would write a directive for an account that is
        // logging out, on a carrier the next session may not even own — and the
        // row would be wiped moments later, after the executor had possibly
        // already dispatched off it.
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
            // Where the run set off from, for the row's own record. Read off
            // the same snapshot the carrier was chosen from rather than a
            // second database read, which would open a gap between the two.
            //
            // **Not the return leg's destination.** This is
            // `SiteAssay.system(of: hub)` — a lossy projection that names the
            // SYSTEM, and travelling to a bare designation lands at the entry
            // point (an L4), not at the hub's own location. `RelayRun.returnHome`
            // re-derives the hub location instead; this stays a record.
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
