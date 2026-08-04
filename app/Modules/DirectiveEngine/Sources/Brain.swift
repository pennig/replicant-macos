//
//  Brain.swift
//  Replicould — DirectiveEngine
//
//  The automation brain's evaluation entry point. `DirectiveEngineCore` ticks
//  a `Brain` alongside its existing supervisor (`tickBrain()` in
//  `DirectiveEngine.swift`) — this is the real seam every later brain task
//  (stall response, the confirm-read gate, prune) tests end-to-end through
//  (`brain-executor-seam`).
//
//  Task 16 is where the brain stops observing and starts acting: a tick that
//  finds unmeshed value, a print hub on the mesh, and a free carrier LAUNCHES
//  a Relay Run. That is the brain's whole enactment vocabulary on the grow
//  side — ONE `Directive.insert`, which the executor then picks up and runs.
//  It remains a PURE SELECTOR (`brain-robustness-bar` clause 1): it never
//  hand-edits a running directive's step/target/status, never issues a command
//  outside the executor → `CommandGovernor` path, and never drives
//  `skipTarget`/`pause`/`resume`, which are operator-only, permanently.
//
//  Task 17 adds the other half: when one of those runs halts and surfaces, the
//  brain answers it as an AUTOMATED OPERATOR — with a bounded auto-`retry` on
//  a reason that self-corrects, and with nothing at all on one that doesn't.
//  Its whole operator vocabulary is `{retry, cancel}`; the three verbs above
//  stay the operator's, and `BrainStallResponseTests` arms them with
//  `unimplemented(...)` so that rule is enforced by the test suite rather than
//  merely written down here.
//
//  Task 18 is the rule that makes the whole thing safe to rank on stale data:
//  ranking runs on a best-effort `WorldView`, but every irreversible
//  commitment is gated on a just-in-time `.high` confirm-read (clause 4c).
//  Staleness may cost a tick of efficiency; it may never cost safety. The
//  confirm can only PROCEED or DEFER — it never re-ranks — and a confirm that
//  fails defers exactly like one that comes back negative.
//
//  Task 23 joins the two halves of `tendMesh`. A launch no longer always means
//  a print: before committing, the brain asks `PrunePredicate` which deployed
//  relays are spare and, if the nearest one is within `reclaimRangeLY` of the
//  plant site, sources the run from it instead (`reclaimSource`). That is
//  ticket 06's "prefer redeploy over print", realised as DEMAND-TIME sourcing —
//  there is no idle-relay pool and no `N` buffer cap, because ticket 10 retired
//  both in favour of this. The brain only SELECTS the source; `RelayRun`
//  confirms it against a fresh read before anything irreversible happens, and
//  `PrunePredicate` remains the sole authority on what "spare" means.
//
//  STATELESS between ticks (clause 2). A tick is a pure function of
//  `(WorldView, directive rows)`: no lease table, no cache, no memory. The
//  ranking, the path-union behind it, and the reservation set are all
//  recomputed from scratch every 5 seconds, which is why a relaunch mid-plan
//  costs nothing and why nothing here can drift out of step with the fleet.
//  `Directive.sourceRelayCode` is a plan hint on the ROW, not brain memory.
//
//  Not an actor, and deliberately so: a plain, non-actor-isolated type's
//  `async` methods are nonisolated by default, so calling `evaluateOnce()`
//  from `DirectiveEngineCore.tickBrain()` (actor-isolated) hops the ranking
//  work off `DirectiveEngineCore`'s serial executor rather than running it
//  inline — the ranking pass can never block the executor-reconciliation loop
//  ticking alongside it.
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

/// One tick's worth of brain evaluation. Stateless between ticks by design
/// (`brain-robustness-bar` clause 2): every field here is an input to THIS
/// evaluation, never state carried over from the last one.
struct Brain: Sendable {
    /// The tick's clock reading, bridged in by the caller via
    /// `@Dependency(\.date)` rather than sampled here — keeps `WorldView`'s
    /// snapshot, and every test built on `TestClock`, deterministic. Never
    /// `Date()` directly.
    let now: Date

    /// The device type this build's grow launch flies. The composition
    /// (`RelayRun`'s file header, ticket 05) is autofactory + co-located
    /// HEAVEN vessel: the relay is printed at the hub and taken aboard a
    /// vessel already standing there.
    static let carrierDeviceType = "heaven_vessel"

    /// The tag a vessel must wear before the brain may fly it.
    ///
    /// **Opt-in, with no fallback to "any free vessel of the right type".** The
    /// type check alone made every idle HEAVEN vessel standing at the hub fair
    /// game, and the brain launched one run per vessel — three vessels, three
    /// Relay Runs, all competing for one shared print queue. Which vessels the
    /// automation may spend is an operator's decision, and there is no column
    /// that records it; a tag is how this codebase already names a working set
    /// no column points at (`Directive.fleetTag`, the Haul Run).
    ///
    /// Untagged therefore means the brain launches NOTHING, and says so
    /// (`carrierBlocker`) rather than idling silently — the distinction
    /// `brain-robustness-bar` clause 6 requires. That is the safe direction: a
    /// fleet the operator has not opted in stays untouched.
    ///
    /// **Spelled lowercase because that is what the fleet actually carries** —
    /// the server normalises tags, so a vessel tagged `auto:tendMesh` reads
    /// back `auto:tendmesh`. Every comparison still goes through
    /// `Device.hasTag`, which normalises both sides; the spelling here is what
    /// the operator sees quoted back at them in `carrierBlocker`, so it should
    /// match what they will see in the device inspector.
    static let carrierTag = "auto:tendmesh"

    /// How far off its road the brain will send a carrier to fetch a spare
    /// relay it could otherwise print — measured from the PLANT SITE (the grow
    /// candidate's first hop), not from the hub.
    ///
    /// **Measured from the plant site because that is what bounds the detour.**
    /// Print flies `hub → target`; reclaim flies `hub → source → target`. The
    /// extra distance is `d(hub,source) + d(source,target) − d(hub,target)`,
    /// and the triangle inequality bounds that by `2 · d(source,target)`
    /// regardless of where the hub happens to be. One number about the source
    /// and the target therefore caps the whole detour, where a cutoff measured
    /// from the hub would cap nothing.
    ///
    /// **Two relay hops (15 ly), and here is the trade behind it.** What a
    /// reclaim BUYS is fixed and known: the entire 370-unit relay bill (carbon
    /// 20, silicates 100, structural 80, rares 40, conductive 120, volatiles
    /// 10) and the ~800 s print that spends it. What it COSTS grows with
    /// distance — at most `2 · d` of extra travel, plus a deactivate/stow
    /// round the print path does not pay.
    ///
    ///   - **The time side.** The fastest read we have on travel is the live
    ///     one (`travel-is-cheap-vs-survey`): ETAs of 1–3 minutes, 467 s the
    ///     worst observed, over a mesh whose own extent is ~16 ly — call it
    ///     ~30 s/ly at the pessimistic end. At `d = 15` the detour bound is
    ///     30 ly ≈ 870 s, which is the same order as the 800 s print it
    ///     replaces. Past that the time cost keeps growing while the saving
    ///     stays fixed, so this is where the trade stops being clearly
    ///     favourable — and the bound is pessimistic twice over, since the
    ///     factor of two is only attained when the source lies directly behind
    ///     the carrier.
    ///   - **The resource side breaks the tie in reclaim's favour**, which is
    ///     why 15 rather than something tighter. `BrainCeiling
    ///     .aggregateSpendFloor` sits at ~47% of the live hub's total stock, so
    ///     units are the scarcer half of the bill by some margin; a reclaim
    ///     that costs a few extra minutes and no units is a good trade almost
    ///     everywhere inside this range.
    ///
    /// **Stated in the graph's own unit** (`SalvageTargetPlanner.relayRangeLY`,
    /// 7.5) rather than as a bare 15.0, because that is the only length scale
    /// this whole subsystem has: one hop is the distance a relay can bridge, so
    /// two hops is "in the same neighbourhood as the plant site" said in the
    /// vocabulary the mesh is built from. It also keeps the cutoff meaningful
    /// if the range ever changes. As a sanity check against being dead code or
    /// unbounded: the live 15-relay mesh fits inside a ~16 ly ball, so 15 ly is
    /// roughly "anywhere on today's mesh".
    static let reclaimRangeLY: Double = 2 * SalvageTargetPlanner.relayRangeLY

    /// The statuses in which a directive still OWNS its devices.
    ///
    /// `paused` and `needsAttention` keep ownership: the mission is still in
    /// force, its devices are still where it left them, and a stall the
    /// operator is about to resolve must find its fleet intact. Only a
    /// finished mission (`completed`/`cancelled`) gives its devices back.
    ///
    /// `DirectiveRow.owningStatuses` (DirectivesFeature) states the same rule
    /// for the list row's display join. It is deliberately NOT imported here
    /// and this one is not exported there: `DirectivesFeature` depends on
    /// `DirectiveEngine`, so the dependency can only run one way, and lifting
    /// the set into `GameModels` would be a schema-module change this task is
    /// not scoped to make. If a third caller ever needs it, that lift is the
    /// right move — two copies of a three-case set is the ceiling.
    static let owningStatuses: Set<DirectiveStatus> = [.running, .needsAttention, .paused]

    /// Read the world, decide what — if anything — is worth doing, and do it.
    /// One `database.read` (a consistent snapshot of the galaxy, the directive
    /// rows that reserve it, and the timelines of the brain's own halted
    /// missions), then two pure decisions and at most one action of each kind.
    ///
    /// **Order of the two layers.** Stall response runs first, because it is
    /// the cheap one: an auto-`retry` flips a row the executor already owns,
    /// where a launch commits to a 370-unit print. They do not contend — a
    /// `.needsAttention` directive still OWNS its carrier (`owningStatuses`),
    /// so the reservation pass excludes it either way — which is why a tick
    /// may do both.
    ///
    /// **What gets REPORTED, when the tick did more than one thing:** a launch
    /// outranks an escalation, and an escalation outranks idling. An
    /// escalated Relay Run does not block the brain (it holds one carrier, not
    /// the fleet), so freezing growth to report it would be a worse answer
    /// than growing and reporting the growth; the escalated row is surfaced in
    /// the Directives list regardless of what this returns. `.stall` is
    /// therefore what the tick says when it had nothing better to do AND
    /// something needs a human — which is exactly `BrainWhy`'s
    /// `isEscalated` (`brain-robustness-bar` clause 6: idle is surfaced-calm,
    /// a stall is surfaced-AND-escalated).
    ///
    /// An auto-retry is deliberately NOT reported through `BrainDecision`:
    /// there is no case for it, and adding one would force open the why-view's
    /// exhaustive projection for a state that is an ACTION taken rather than a
    /// plan formed. It is logged at `.notice` instead — the same level a
    /// launch gets, for the same reason.
    ///
    /// **Why this returns a `BrainReport` and not just the `BrainDecision`.**
    /// Everything the why-view needs to EXPLAIN the tick — the ranked field
    /// the decision was made against, the hub, the rails — is already known
    /// here and used to be discarded. Gathering it changes nothing about what
    /// the brain DOES; the decision and the actions are identical either way.
    /// (`Brain.evaluateOnce()`, the decision-only seam most of the test suite
    /// drives, lives in the test target — `BrainTestSupport.swift` — rather
    /// than here, so production source carries no test-only API.)
    ///
    /// **Cancellation: a tick can be torn down half-way through, and every act
    /// it has left to take is re-guarded.** `DirectiveEngineCore.stop()` runs on
    /// logout, immediately before the directive tables are wiped, and it cancels
    /// the brain task WITHOUT awaiting it. Cancellation is cooperative, so a
    /// tick suspended in any of the four `await`s below resumes inside a
    /// stopped engine and finishes its work against the previous account. There
    /// is nothing else to test: `Brain` is stateless and holds no engine
    /// reference, and the task flag is exact because this code runs INSIDE the
    /// very task `stop()` cancels.
    ///
    /// The check therefore sits immediately before each irreversible act rather
    /// than once at the top, because each act has its own suspension in front of
    /// it: the auto-`retry` (`respondToStalls`, behind the snapshot read), the
    /// `.high` confirm-read and the directive insert (`decide`/`launch`, behind
    /// each other), and — in `DirectiveEngineCore.tickBrain()` — the publish,
    /// behind this whole function. Nothing downstream of a cancelled tick is
    /// worth doing: `tickBrain()` discards the report, and the rows are about to
    /// be wiped.
    ///
    /// Until this was written the two WRITES were held back only by GRDB
    /// throwing `CancellationError` out of its async accessors — real, but
    /// undocumented, unasserted, and a property of a dependency rather than of
    /// this file.
    func report() async -> BrainReport {
        @Dependency(\.defaultDatabase) var database

        let snapshot: Snapshot
        do {
            snapshot = try await database.read { db in
                let directives = try Directive.all.fetchAll(db)
                // Only the brain's OWN halted missions need a timeline, and
                // only they get one: `directiveLogEntries` is append-only and
                // never pruned, so the read is scoped to those ids on the
                // existing `(directiveID, occurredAt)` index rather than
                // sweeping the table every five seconds. One `IN` round-trip
                // for the whole set, grouped in memory — the alternative, a
                // query per stalled run, is the same index work spread over N
                // round-trips.
                //
                // `directiveID` is nullable (a built-in AMI directive's entry
                // keys off `deviceCode` instead), so the bound list is
                // `[String?]` to match the column's own type — SQL's `IN`
                // never matches NULL, so a built-in's entry cannot be caught
                // by this however the list is typed.
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
                    // Read in the SAME transaction as everything else, for the
                    // same reason the rest of the snapshot is: a stock figure
                    // from a different instant than the devices it is meant to
                    // explain is a fact about no world that ever existed. Only
                    // the hub's own row — the census table is whole-galaxy and
                    // the rail only judges one location.
                    hubFootprint: try view.hubLocation.flatMap { hub in
                        try LocationFootprint.where { $0.location.eq(hub) }.fetchOne(db)
                    }
                )
            }
        } catch {
            logger.error("world read failed: \(error)")
            // No snapshot means no hub reading — but the governor is a
            // separate, process-local fact that is still perfectly readable,
            // and a tick that couldn't reach the database is exactly when an
            // operator wants to know whether we are being rate-limited.
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
    /// demand.
    ///
    /// **Restock is the production half of the relay pool.** `RelayRun` claims a
    /// standing spare and only prints when the pool cannot cover it, so without
    /// something stocking the hub the pool drains once and every run afterwards
    /// waits out a print. Printing is the fleet's bottleneck, so the printer
    /// should be busy whenever there is work for what it makes.
    ///
    /// **The brain writes the DEMAND, the run does the printing.** That split is
    /// forced rather than chosen: demand is a galaxy-wide judgement over
    /// `GrowRanking`, which needs a `WorldView`, and a mission only ever gets a
    /// target-scoped `WorldSnapshot` (see `RestockRun.desiredIdle`). Writing the
    /// list onto the row it owns is bookkeeping, not enactment — the print
    /// command still comes from the executor, so `brain-robustness-bar` clause 1
    /// holds.
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
        // No targets, nothing to print FOR — so no run is created. An existing
        // one is left alone rather than cancelled: demand comes and goes as
        // systems mesh and new value is surveyed, and a row that deleted itself
        // every quiet tick would churn the list and lose its timeline.
        guard existing != nil || !demand.isEmpty else { return }
        // **One action per tick**, the discipline `plan` and `respondToStalls`
        // already keep. Creating this row is an action, so a tick that has just
        // committed a launch does not also take it — the brain re-reads the
        // world five seconds later against a ledger that now contains the
        // launch, and creates restock then. Updating an EXISTING row's demand
        // below is bookkeeping, not an action, and is not deferred.
        if existing == nil, case .dispatch = decision { return }
        if let existing {
            // Only write when the list actually moved — a directive row rewritten
            // every five seconds would churn the timeline and every `@FetchAll`
            // observing it.
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
                // Re-check inside the transaction: `report()` reads and writes in
                // separate steps, so a restock created by the previous tick could
                // have landed in between. The directive rows are the ledger.
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

    /// The device a restock run may be hosted on: a print-capable device at the
    /// hub that is NOT a carrier. See `tendRestock` for why the exclusion is
    /// load-bearing rather than tidy.
    static func restockHost(in view: WorldView) -> Device? {
        guard let hub = view.hubLocation else { return nil }
        return view.devices.values
            .filter { $0.isPrintHub && $0.location == hub && $0.deviceType != carrierDeviceType }
            .min { $0.deviceCode < $1.deviceCode }
    }

    /// The prune half of the report: what the predicate found, and which of it
    /// the tick actually acted on.
    ///
    /// **The reclaim is reported only on a tick that COMMITTED.** `plan` chooses
    /// a source before the confirm-fresh gate runs, and a gate that defers
    /// leaves the relay standing exactly where it was — so reporting the choice
    /// unconditionally would put "reclaiming R9" in front of an operator on a
    /// tick that reclaimed nothing. Same discipline as `launch`'s degrade-to
    /// -`.idle`: the report says what HAPPENED.
    ///
    /// **`reclaimable` is partitioned three ways, not read as one "available"
    /// list.** A source relay stays deployed and `relaying` for the whole
    /// outbound leg of the run coming to fetch it, and prune — stateless, and
    /// answering a question about the mesh rather than about the fleet's plans
    /// — keeps returning it for every one of the hundreds of ticks that takes.
    /// So a relay already spoken for by an in-force run is reported as CLAIMED,
    /// never as spare: `inFlightSources` is the same authority the sourcing side
    /// consults before offering one relay to a second carrier, so the card and
    /// the selection cannot disagree about who owns what.
    ///
    /// The tick's own `reclaimed` is subtracted from both, so no relay is ever
    /// described twice. It cannot in fact appear in `inFlightSources` here —
    /// `directives` was read before the launch that claims it — but the
    /// subtraction is written over both lists rather than relying on that read
    /// ordering, because the cost of being wrong is a card that says
    /// "reclaiming R9" directly above "R9 is spoken for".
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

    /// Carry out `plan`, and say what the tick did. Split out of `report()` so
    /// the gathering of what to REPORT sits in one place and the enactment in
    /// another; the precedence rule between a launch, an escalation, and
    /// idling is documented on `evaluateOnce()` above and lives here.
    private func decide(
        _ plan: Plan,
        escalated: DirectiveAttentionReason?,
        database: any DatabaseWriter
    ) async -> BrainDecision {
        switch plan {
        case let .idle(reason, _, _):
            // `respondToStalls` has already logged the escalation (with the
            // directive id, which is the part worth having); a second line for
            // the same fact here would just double the per-tick noise.
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
            // Cancellation first: the confirm is a live `.high` read, and a
            // logged-out session has no business spending one. See `report()`'s
            // cancellation note.
            guard !Task.isCancelled else { return .idle(reason: "engine stopped") }
            switch await confirmCarrier(carrier) {
            case let .deferred(reason):
                // Same precedence as the idle arm above: a deferred tick did
                // nothing, so a run already waiting on a human still outranks
                // it as the thing worth reporting.
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

    /// The rails, as they stand at this tick. Two independent readings: the
    /// process-shared actions budget (which knows both what is left and
    /// whether the server has recently said 429), and the hub's census row
    /// judged against `BrainCeiling`'s reserve floor.
    ///
    /// Reports, never gates. The rails themselves are enforced where they
    /// already were — `CommandGovernor` for the budget,
    /// `RelayRun.printStockIsShort` for the floor — and nothing here can
    /// change what a tick does. Read via `@Dependency(\.gameClient)` so the
    /// figure shown is the one the governor every dispatch throttles on, not
    /// a second copy.
    private static func limits(hubFootprint: LocationFootprint?) async -> BrainLimits {
        @Dependency(\.gameClient) var gameClient
        let budget = await gameClient.budget(.actions)
        return BrainLimits(
            actionsRemaining: budget.remaining,
            actionsLimit: budget.limit,
            actionsFloor: CommandGovernorClient.actionFloor,
            hubStock: hubFootprint?.resources,
            // Carried, not dropped: the rail vetoes on the reading's AGE as
            // well as its value, so a figure without its timestamp cannot
            // express what the rail is actually doing.
            hubStockFetchedAt: hubFootprint?.fetchedAt,
            spendFloor: BrainCeiling.aggregateSpendFloor,
            rateLimitedAt: budget.rateLimitedAt
        )
    }

    /// One consistent read: the galaxy the brain ranks over, the directive
    /// rows that say which of it is already spoken for, and the timelines the
    /// retry budget is derived from. Read in ONE transaction on purpose — a
    /// carrier freed between two separate reads would look free to the ranking
    /// and reserved to the reservation pass (or worse, the reverse), and a
    /// timeline read after its own row could show a retry the row hasn't taken.
    ///
    /// `Directive.all`, not a status-filtered query, deliberately: which
    /// statuses own their devices is a RULE (`owningStatuses`), and splitting
    /// it between a SQL predicate here and the pure pass below is how the two
    /// halves drift. The table is a mission ledger — tens of rows, not the
    /// unbounded `operations` log — so reading it whole every tick is cheap.
    private struct Snapshot: Sendable {
        let view: WorldView
        let directives: [Directive]
        /// Timeline entries, oldest first, for each brain-managed stall — and
        /// for nothing else.
        let log: [String: [DirectiveLogEntry]]
        /// The print hub's census row, when there is a hub and the census has
        /// one for it. Read for the why-view's reserve-floor line only — the
        /// rail itself is still enforced by `RelayRun`, on that mission's own
        /// snapshot, at the moment it would print.
        let hubFootprint: LocationFootprint?
    }

    // MARK: - The greedy pass

    /// What a tick decided to do, before anything is written. Split from
    /// `evaluateOnce` so the whole judgement is a PURE function of the
    /// snapshot — no clock, no database, no dependencies.
    enum Plan {
        /// Nothing to launch. `ranked` is still the whole field this pass saw
        /// — usually empty (there was nothing to rank), but NOT always: a tick
        /// that idles because "every grow candidate is already in flight"
        /// ranked a full field and chose none of it, and an operator reading
        /// that gate needs to see what "every candidate" means.
        ///
        /// `prune` rides on the IDLE arm as well as the grow one, and that is
        /// the point of carrying it here at all: the ticks on which an operator
        /// most needs to know a relay is standing idle are the ticks that did
        /// nothing about it.
        case idle(reason: String, ranked: [GrowCandidate], prune: PruneAnalysis?)
        /// Launch a Relay Run for `goal` on `carrier`, which stands at `hub`
        /// and so sets off from `origin` (the hub's system). `ranked` is the
        /// whole field the choice was made against, carried through for the
        /// why-view.
        ///
        /// `hub` rides along beside `origin` rather than being re-derived from
        /// it: `origin` is `SiteAssay.system(of: hub)`, a lossy projection
        /// ("SOL-3" → "SOL"), and the confirm-fresh gate has to re-test
        /// co-location against the LOCATION the carrier was chosen at. Passing
        /// the system and re-widening the test to it would let a vessel that
        /// had crossed to another location in the same system confirm as free.
        ///
        /// `source` is where the relay comes from: nil PRINTS one at the hub
        /// (370 units, ~800 s), non-nil RECLAIMS the spare relay it names for
        /// nothing at all. See `reclaimSource`.
        case grow(
            goal: Goal, ranked: [GrowCandidate], carrier: String, hub: String, origin: String,
            source: ReclaimChoice?, prune: PruneAnalysis?
        )

        /// The field this pass ranked, whichever way it went — the why-view's
        /// candidate list. One accessor rather than two matches at the call
        /// site, so the two arms can never be read inconsistently.
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

    /// A reclaim the brain chose, carried with the graph fact that justifies it
    /// rather than as a bare device code.
    ///
    /// The distance rides along because it is what makes the choice CHECKABLE:
    /// "sourced by reclaiming R9 at DEADEND, 7.1 ly from VEGA" is a statement
    /// an operator can hold against the map, where "sourceRelayCode = R9" is
    /// one they have to take on trust. Same discipline as `Goal.rationale` —
    /// a graph fact, never a score.
    struct ReclaimChoice: Equatable, Sendable {
        let relay: ReclaimableRelay
        /// Straight-line light-years from the relay's system to the plant site.
        let distanceLY: Double
    }

    /// The greedy pass, grow-only.
    ///
    /// **One launch per tick, deliberately.** The pass takes the single
    /// best still-available candidate and stops; the next tick, five seconds
    /// later, re-ranks from scratch against a world that now contains the row
    /// it just wrote. That makes in-tick double allocation structurally
    /// impossible rather than merely guarded — there is no second allocation
    /// within a pass to double-book with — and it keeps the whole tick a pure
    /// function of its snapshot. (It is also the shape the task brief
    /// specifies. A multi-launch pass would have to thread a growing reserved
    /// set through each allocation; when prune lands and a tick can allocate
    /// twice, that threading is what must be added, and this doc is the note
    /// saying so.)
    ///
    /// Order of the gates is chosen for the why-view's sake: "nothing worth
    /// reaching" and "nothing free to send" are genuinely different states and
    /// an operator needs to be told which one they are in.
    static func plan(view: WorldView, directives: [Directive]) -> Plan {
        guard !view.meshSystems.isEmpty else {
            // No mesh means no graph and nothing deployed to judge, so prune
            // has not declined — it has not been asked. Nil, not an empty
            // partition: the why-view must say nothing rather than claim a
            // tidy mesh.
            return .idle(reason: "no mesh yet", ranked: [], prune: nil)
        }

        let graph = MeshGraph(positions: view.starPositions)
        // ONCE per tick, and BEFORE the gates below, so every arm of this pass
        // carries it. Hoisted out of `reclaimSource` (which used to run it, and
        // only on a launching tick) for the why-view's sake: a spare relay is
        // most worth surfacing precisely on the ticks that do nothing with it,
        // and reporting the mesh's shape only when it changes would leave an
        // idling brain unexplained. The cost is one more multi-source Dijkstra
        // over the census per tick — the same order as `GrowRanking.rank`
        // beside it, single-digit milliseconds at full census scale
        // (`MeshGraph.reach`) against a 5-second budget. `reclaimSource` is
        // handed the result rather than recomputing it, so the SOURCING
        // judgement is byte-identical to what it was.
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

    /// Where this grow's relay should come from: the nearest spare relay within
    /// `reclaimRangeLY` of the plant site, or nil to print a fresh one.
    ///
    /// **This is ticket 06's "prefer redeploy over print", and it is realised
    /// as DEMAND-TIME sourcing.** There is deliberately no idle-relay pool and
    /// no `N` buffer cap — ticket 10 retired both in favour of exactly this:
    /// nothing is reclaimed speculatively, and a relay is only pulled out of
    /// the mesh at the moment a grow has somewhere better to put it. That keeps
    /// the brain stateless (clause 2): `sourceRelayCode` is a plan hint written
    /// on the ROW, and the whole judgement is re-derived from the world next
    /// tick.
    ///
    /// **`PrunePredicate` is the sole authority on usefulness** and nothing
    /// here second-guesses it. The three filters below are all about something
    /// else — whether the CARRIER may do this, whether the relay is already
    /// spoken for, and whether it is close enough to be worth the trip.
    ///
    ///   1. **The carrier must host a replicant.** The reclaim sequence
    ///      deactivates the source, which takes its system off the mesh; the
    ///      `stow` that must follow is then commandable only under
    ///      `ftl-authority-rule` rule (1), a replicant physically present. The
    ///      executor's `RelayRun.carrierRetainsAuthority` turns a carrier
    ///      without one into a loud stall rather than a permanent strand, but a
    ///      stall is still a wasted run and a carrier held out of the fleet
    ///      through three retries and an escalation. So the brain does not send
    ///      one. Checked first here because it vetoes the whole question in one
    ///      set lookup. (It does not pick a DIFFERENT carrier: carrier selection
    ///      is `freeCarrier`'s job and print works on any hull, so the fallback
    ///      is simply to print.)
    ///   2. **A declined analysis sources a print, never a guess.** `declined`
    ///      means the predicate refused to judge this world, and its
    ///      `reclaimable` list is empty as a consequence of the refusal rather
    ///      than as a finding. Reading it as "nothing spare" happens to give the
    ///      right answer here, but only by accident, and the accident is not
    ///      worth relying on — the check is explicit.
    ///   3. **A relay another run is already fetching is not offered twice.**
    ///      Prune is stateless and re-derives `reclaimable` from the world every
    ///      tick, and a source relay stays deployed and `relaying` for the whole
    ///      flight of the run coming to collect it — so without this it stays on
    ///      the list and a second carrier is sent to deactivate the same relay.
    ///      The exact mirror of `inFlightTargets` on the sourcing side, and it
    ///      is re-checked at commit time for the same reason that one is.
    ///   4. **The source must not be the plant site's own way onto the mesh.**
    ///      See `sourceWouldStrandTheHop` — this is the one hazard `PrunePredicate`
    ///      structurally cannot see, and the cutoff aims selection straight at it.
    ///
    /// Ties break on device code after distance, so the same world produces the
    /// same choice every tick — the reproducibility a stateless brain that
    /// re-decides from scratch depends on (`freeCarrier`'s `min(by:)` records
    /// the argument).
    ///
    /// **The carrier-host fact is SNAPSHOT-ONLY and nothing re-confirms it.**
    /// `confirmCarrier` spends its `.high` read on the DEVICE row; nothing
    /// re-reads `replicants`, and the executor's own authority gate
    /// (`RelayRun.carrierRetainsAuthority`) only fires AFTER the `deactivate`.
    /// A replicant that changed hulls between the last account sync and this
    /// launch therefore produces exactly the case gate 1 exists to prevent. It
    /// needs an operator action to arise, and it is recoverable — the source is
    /// by construction load-bearing for nothing, so the stall costs a run and a
    /// carrier's time rather than authority — but it is not closed, and a
    /// second `.high` read per launching tick is not obviously the right price.
    ///
    /// `analysis` is computed once per tick by `plan` and handed in, rather
    /// than run here, so the why-view can report what prune saw on ticks that
    /// source nothing. The judgement below is unchanged by that: it reads the
    /// same partition it used to compute for itself.
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

    /// The meshed systems the plant site could link to — every mesh system
    /// within one relay hop of it.
    static func meshNeighbours(
        of hop: String, view: WorldView, graph: MeshGraph
    ) -> Set<String> {
        Set(graph.neighbours(of: hop)).intersection(view.meshSystems)
    }

    /// Would reclaiming this relay take away the very mesh node the new relay
    /// is about to link to?
    ///
    /// **The one hazard `PrunePredicate` structurally cannot see, and the
    /// cutoff aims selection straight at it.** Grow and prune read the same
    /// graph with different roots: `MeshGraph.reach` seeds EVERY mesh system at
    /// zero cost and keys on distance-from-the-mesh, while `pathUnion` seeds the
    /// ANCHOR alone and keys on distance-from-the-hub. When two chains to a
    /// target tie on relay count — which is the common case, since relay count
    /// is the primary key and the distances only break ties — the two searches
    /// can leave the mesh by DIFFERENT exits: grow takes the exit nearest the
    /// target, prune the exit cheapest from the hub. A relay standing at grow's
    /// exit that prune routed around is genuinely on no anchor→target path, so
    /// prune correctly calls it spare — and then the plant site's only way onto
    /// the mesh is the thing we are about to tear down.
    ///
    /// Worse, `reclaimRangeLY` points at it: the relays nearest the plant site
    /// are precisely its candidate links, and the nearest-first rule prefers
    /// them. The failure is silent and expensive — the run deactivates the
    /// source, stows it, flies to the hop, deploys, and the new relay meshes
    /// nothing; the run stalls at `settling` and the fleet is one node down for
    /// nothing gained.
    ///
    /// **The test is local and exact:** the hop must retain at least one meshed
    /// neighbour after the source's system leaves the mesh. One extra 27-cell
    /// grid probe on a launching tick, no new state, no second search.
    ///
    /// **It subtracts the whole SYSTEM, not the one relay**, which is
    /// deliberately conservative: two relays standing in one system would keep
    /// it meshed after one is reclaimed, and this rejects the source anyway.
    /// The error costs a print; the other direction costs the grow AND a mesh
    /// node.
    ///
    /// **One-hop grows are safe by construction** and this simply never fires
    /// for them: a 1-relay prune path must enter the target from a mesh node
    /// within `hopRange`, so that node is on the union, pinned, and never
    /// offered — leaving a second link alive. This bites on frontier-extending
    /// MULTI-hop grows, which is exactly where the mesh is thinnest.
    static func sourceWouldStrandTheHop(
        _ relay: ReclaimableRelay, meshLinksAtHop: Set<String>
    ) -> Bool {
        meshLinksAtHop.subtracting([relay.system]).isEmpty
    }

    /// Every relay an in-force directive has already been told to reclaim.
    ///
    /// Not filtered by `kind`, unlike `inFlightTargets`: `sourceRelayCode` is a
    /// `relayRun` field today, but a row of any kind naming a source is a row
    /// claiming that relay, and the safe reading of an unexpected one is that
    /// somebody owns it.
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
    /// **Three, and here is the arithmetic behind it.** Each attempt costs at
    /// most one API-driving evaluation (a `.high` confirm-read, a census
    /// refresh, or a re-issued command), so the number is a direct budget of
    /// live-API spend per stalled directive per episode. Attempt 1 covers a
    /// genuine one-off — a lost write, a governor deferral, a row the sync
    /// hadn't reached. Attempt 2 covers a slow-but-real recovery: a confirm-read
    /// landing, a census refresh arriving. By attempt 3 the same condition has
    /// survived three independent re-evaluations spread over `retryInterval`
    /// each, and the evidence has flipped from "transient" to "structural" —
    /// the marginal chance a fourth clears it is small, while the marginal cost
    /// is unbounded, because a brain that keeps retrying keeps paying forever
    /// on a run that will never self-correct AND keeps its carrier held out of
    /// the fleet where nobody is looking at it.
    ///
    /// Being wrong in the other direction is the reason it isn't 1: escalation
    /// spends the operator's attention, which is the scarcest resource in this
    /// whole system, and a budget of one would spend it on every transient the
    /// second attempt would have cleared silently.
    static let retryBudget = 3

    /// The minimum gap between two auto-retries of the SAME directive.
    ///
    /// **Scaled to this capability's own clock, not to the tick rate.** The
    /// budget above is only meaningful if each attempt can actually see
    /// something the last one couldn't, and everything a Relay Run waits on
    /// runs in minutes-to-tens-of-minutes: the live relay print is ~800 s,
    /// `RelayRun.printDeadline` is 30 min, `RelayRun.hubFreshness` and
    /// `RelayRun.stowDeadline` are 5 min each, and a hub's stock is refilled by
    /// a whole Haul Run delivery cycle. Against that, a floor measured in
    /// seconds spends the entire budget inside a single print's duration.
    ///
    /// Two anchors fix the value:
    ///
    ///   - **A lower bound from INFORMATION.** `RelayRun.acquire` believes the
    ///     hub's row for `hubFreshness` (5 min) before it re-reads it, and
    ///     `footprintCensusIsStale` gates the census the reserve rail reads the
    ///     same way. A retry sooner than that re-reads numbers the run itself
    ///     considers current, so it is *structurally* incapable of producing a
    ///     different answer — it can only burn an attempt. Any floor below
    ///     5 min makes a `printStockShort` budget unspendable by construction.
    ///   - **An anchor from the WORK.** The unit of progress here is one relay
    ///     print (~800 s), and the thing that clears a stock shortage — ore
    ///     mined, salvaged, and ferried in — is at least one delivery cycle of
    ///     the same order. One print cycle, rounded up, is 15 minutes.
    ///
    /// So three attempts span ~30 minutes, which covers at least one full
    /// resupply cycle and sits inside `printDeadline`'s own 30-min-per-step
    /// scale. **Thirty, not forty-five**: the FIRST attempt is unspaced, because
    /// at the first stall there is no `.resolved` entry to measure an interval
    /// from (`retryEpisode` returns `lastAttemptAt == nil`), so the attempts
    /// land at roughly t, t+15 and t+30 with escalation following the third.
    /// `RelayRun.confirmSource`'s doc already recorded this correction and
    /// pointed here; `BrainDegradationTests.autoRetriesAreSpacedByTheRetryInterval`
    /// now measures the gaps off the timeline the retries actually wrote.
    /// A shortage still unresolved after that is not a lull — it is a
    /// supply-chain problem (nothing mining, no hauler tagged, a reserve floor
    /// set too high) that genuinely needs the operator, which is exactly what
    /// escalation says.
    ///
    /// **Waiting costs the operator nothing they can't already see.** Between
    /// attempts the row sits in `.needsAttention` with its reason and guidance,
    /// surfaced in the Directives list the whole time — the operator can act at
    /// any point. The only thing a longer floor delays is the moment the BRAIN
    /// gives up. That asymmetry is why erring long is right: erring short
    /// escalates permanently (a `.needsAttention` run cannot move step, so its
    /// `attempts` never falls back below the budget and the brain will not
    /// touch it again on any future tick), while erring long merely leaves a
    /// visible row visible for longer.
    ///
    /// Derived from the timeline like the count itself — the timestamp of the
    /// last resolution in the episode — so it costs the stateless brain no
    /// memory between ticks.
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

        /// The retry this response asks for, or nil if it asks for none —
        /// so the one-action-per-tick pass can take the FIRST of them.
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

    /// The stalls the brain is allowed to answer, and the reason it answers
    /// them with: its OWN missions, halted and surfaced.
    ///
    /// `kind == .relayRun` is the whole membership rule. A Survey Run or a
    /// Salvage Run the operator launched belongs to the operator — a
    /// `.retry`-disposition reason on one of those is not an invitation, and
    /// answering it would be the brain quietly taking over missions nobody
    /// gave it. (Every `relayRun` row in existence was written by
    /// `Brain.launch`: no UI launches one.)
    static func brainManagedStall(_ directive: Directive) -> DirectiveAttentionReason? {
        guard directive.kind == .relayRun, directive.status == .needsAttention else { return nil }
        return directive.attentionReason
    }

    /// How many resolutions this directive has taken since it last moved to a
    /// different step, and when the most recent of them landed.
    ///
    /// **This is the retry budget, and it lives in the timeline rather than in
    /// the brain.** The brain is stateless between ticks (`brain-robustness-bar`
    /// clause 2) — there is no counter to hold a count in, and adding a column
    /// would be inventing state the ledger already carries. Every resolution
    /// writes a `.resolved` entry (`DirectiveResolutionClient.apply`) and every
    /// stall writes a `.stalled` one (`DirectiveExecutor.stall`), in the same
    /// database and the same transaction as the row change, so a count read
    /// back off them survives a relaunch and can never disagree with what
    /// actually happened. The technique is the house one —
    /// `SalvageRun.stepEntryCount` and `HaulRun.dispatchAttemptCount` both
    /// derive their budgets this way.
    ///
    /// **The episode boundary is the STEP.** Walking back from the newest
    /// entry, the first one naming a step other than the directive's current
    /// one ends the walk: the run was somewhere else, so everything before it
    /// belongs to an earlier visit and buys a fresh budget. Entries naming the
    /// current step are transparent — including `.commandDispatched`, which is
    /// deliberate: a step that re-issues its command and stalls again on the
    /// same step has not progressed, it has looped, and treating the dispatch
    /// as progress would reset the budget on exactly the loop the budget
    /// exists to bound.
    ///
    /// **`.opCompleted` is exempt from the boundary test entirely**, not merely
    /// uncounted — it is the one kind whose `step` cannot be trusted to say
    /// where the run is. `DirectiveExecutor.recordCompletedOps` stamps it with
    /// the step the command was ISSUED from and back-dates `occurredAt` to
    /// `min(max(op.lastConfirmedAt, dispatch.occurredAt), now)`, and
    /// `lastConfirmedAt` advances on any later confirm-read of an
    /// already-terminal op — so an audit entry naming an OLD step can legitimately
    /// sort AFTER the step move that followed it. Letting it end the walk would
    /// discard resolutions genuinely taken on the current step and hand the
    /// directive a fresh budget, which is the unsafe direction (more retries
    /// against a live API). The pass is audit-only by contract — delete it
    /// tomorrow and execution is byte-identical — so it must not be able to
    /// change what the brain does, in either direction.
    ///
    /// **Every `.resolved` entry counts, not just the brain's own retries.**
    /// The alternative is string-matching `summary` ("Retried …"), which is a
    /// display string, and the direction of that error is the dangerous one:
    /// an unrecognised summary reads as "not an attempt" and hands the brain
    /// more retries. Counting all of them is also the behaviour that is
    /// actually right — a resolution of any kind that was followed by no
    /// progress at all is an attempt that did not work, and the brain has no
    /// business piling automated retries on top of an operator who has just
    /// tried the same thing by hand and got nowhere.
    static func retryEpisode(_ directive: Directive, log: [DirectiveLogEntry]) -> RetryEpisode {
        var attempts = 0
        var lastAttemptAt: Date?
        walk: for entry in log.reversed() {
            // `.opCompleted` never ends the walk: its `step` names where the
            // command was issued, and its back-dated `occurredAt` can sort it
            // after the step move that followed. See the doc above.
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

    /// The pure decision for ONE directive. Nil for anything that isn't a
    /// brain-managed stall.
    ///
    /// The switch over `brainDisposition` is exhaustive with no `default:` on
    /// purpose — a disposition added later must force this open rather than
    /// silently inheriting whichever branch happened to be the fallthrough.
    ///
    /// **`.decisionRequest` shares the `.escalate` branch, and that is a
    /// decision, not an omission.** No reason maps to it today (see
    /// `BrainStallDispositionTests`), so the branch is currently unreachable —
    /// which is precisely why it needs to be written to the SAFE answer now,
    /// while nothing depends on it. A decision request is by definition the
    /// human-in-the-loop seam (`brain-executor-seam`): the mission has reached
    /// a point where the CHOICE is the operator's, and a brain that answered it
    /// would be making a policy call it was explicitly denied. Retrying is not
    /// a neutral option there either — it re-runs the step that asked the
    /// question and gets asked it again. So: surface it, touch nothing.
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
                // interval waits rather than retrying, which is the safe
                // direction — the tick after the clock catches up will retry.
                return .waiting(directiveID: directive.id, reason: reason)
            }
            return .retry(
                directiveID: directive.id, reason: reason,
                attempt: episode.attempts + 1, lastAttemptAt: episode.lastAttemptAt
            )
        }
    }

    /// Drive at most one auto-`retry`, and report the first stall left needing
    /// a human (nil if none is).
    ///
    /// **One retry per tick**, the same discipline `plan` applies to launches
    /// and for the same reason: a tick spends one action and re-reads the world
    /// five seconds later against a ledger that now contains it. This is what
    /// keeps the known pile-up bounded — with N free carriers in a
    /// resource-short world the brain can put N Relay Runs into
    /// `.needsAttention` with the same reason (Task 16's review recorded this
    /// as by design: the API vetoes, the brain never pre-judges), and without
    /// the rule a single tick would fire N retries at once. Combined with the
    /// per-directive `retryInterval`, the brain's total stall-driven API rate
    /// is bounded both per-directive and per-tick.
    ///
    /// **The tick's one retry goes to whichever candidate has WAITED LONGEST**
    /// (never-attempted counts as longest), with the directive id as
    /// tie-break. Ordering by id alone starves the tail: with the 5-second tick
    /// and a `retryInterval`-long floor, roughly `retryInterval / tick`
    /// directives can be eligible in rotation, and past that a low-id
    /// directive that has just become eligible again always outranks the
    /// highest-id one — which is then never retried, never spends budget, and
    /// so never reaches `.escalated` either. It would be held silently and
    /// reported to nobody, which is the one outcome this whole layer exists to
    /// prevent. Longest-waiting-first cannot starve anything, and stays fully
    /// deterministic: the same world produces the same choice every tick, which
    /// a stateless brain that re-decides from scratch needs in order for its
    /// own behaviour to be reproducible (the argument `freeCarrier`'s
    /// `min(by:)` records).
    ///
    /// Escalations are reported lowest-id-first instead — they are a report
    /// rather than an action, so fairness doesn't apply, and `BrainDecision
    /// .stall` carries one reason. An operator with three escalated runs is
    /// going to the Directives list anyway, where all three are surfaced;
    /// naming the lowest-id one keeps this reproducible rather than arbitrary.
    private func respondToStalls(_ snapshot: Snapshot) async -> DirectiveAttentionReason? {
        // A `stop()` landing while `report()`'s snapshot read was in flight
        // leaves this tick running against an account whose directive rows are
        // about to be wiped — driving `retry` on one of them is a write with
        // nothing left to write to. See `report()`'s cancellation note.
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
            // auto-retry is a real action taken on the operator's behalf, on a
            // run they may already be looking at, and the reason plus the
            // attempt count are what makes the line answer "why did this clear
            // itself?" without a second lookup. It is bounded by construction —
            // at most `retryBudget` of these per episode — so it can never
            // become a heartbeat.
            logger.notice(
                """
                auto-retry \(attempt.attempt, privacy: .public)/\(Self.retryBudget, privacy: .public) on relay run \
                \(attempt.directiveID, privacy: .public) — \(attempt.reason.rawValue, privacy: .public)
                """
            )
            // `retry` and `cancel` are the brain's ENTIRE operator vocabulary.
            // `skipTarget`, `pause` and `resume` are the operator's,
            // permanently — see this file's header and
            // `BrainStallResponseTests.brainNeverDrivesOperatorOnlyVerbs`.
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

    /// Every device code an in-force directive owns — the set a launch must
    /// not allocate out of.
    ///
    /// The running directive ROWS are the lease ledger (`brain-executor-seam`,
    /// ticket 04); there is no separate lease table and this task deliberately
    /// does not add one. Four rules from that ticket seed the set:
    ///
    ///   1. `deviceCode` — the mission's carrier.
    ///   2. Everything transitively stowed inside it (see the closure below).
    ///   3. `controllerCode` — the AMI the mission is driving.
    ///   4. `fleetTag` — every device wearing it, because a tag is how a Haul
    ///      Run names a working set no column points at. This is why the
    ///      caller must pass an UNFILTERED fleet: a tagged device is usually
    ///      stowed, and `WorldView.read`'s `Device.all` is what makes it
    ///      visible here at all.
    ///
    /// Then a **closure** to a fixpoint over three containment relations. The
    /// seed alone is not "every device an in-force directive owns", which is
    /// what this function claims and what its one consumer needs:
    ///
    ///   - **Stow, downward** (`parent → children`). A relay aboard a carrier,
    ///     a drone aboard a controller aboard a carrier: the whole subtree
    ///     travels with the mission.
    ///   - **Stow, upward** (`child → its hull`). The one review found, and
    ///     the reachable one: directive D owns device X, X is stowed inside
    ///     vessel V, and V is named by no directive. Without this edge V reads
    ///     as free, `freeCarrier` picks it, and the Relay Run flies away with
    ///     another mission's device in the hold. The hull is as reserved as
    ///     its cargo. (Reserving V then re-reserves V's other contents through
    ///     the downward edge, which is correct for the same reason: they all
    ///     go where V goes.)
    ///   - **Adoption** (`controller → adopted drones`), read from BOTH ends
    ///     exactly as `AMIFleet.adoptedDrones(of:in:)` does — the drone's
    ///     `controllerDeviceCode` column AND the controller's
    ///     `controlledDeviceCodes`. The two-ended read is not belt-and-braces:
    ///     `controlled_devices` ships only in the single-device payload and a
    ///     routine fleet sync ERASES it (`controlled-devices-detail-only`), so
    ///     the column is the reliable end and the blob is the bonus. A
    ///     deployed drone adopted by a reserved controller is owned even
    ///     though it is stowed nowhere.
    ///
    /// Every stow read is through the CHILD's own `stowedInDeviceCode` column,
    /// never the parent's `stowed_devices` blob — the blob is not a reliable
    /// inverse (a live vessel's listed one unrelated device while six drones
    /// claimed to be aboard), the same reason `RelayRun.confirmStow` reads the
    /// child end.
    ///
    /// **Deliberately over-reserving rather than under-.** The closure spreads
    /// through a containment component, so one owned drone can reserve a hull
    /// and its other contents. That direction of error costs a tick of
    /// patience; the other direction strands somebody's fleet.
    ///
    /// **Terminates** on any input, including corrupt ones: a code joins the
    /// frontier only on the pass that first inserts it into `reserved`, so a
    /// stow cycle (A aboard B aboard A) closes instead of looping.
    ///
    /// Nothing existing computed this: `DirectiveRow.owningStatuses`
    /// (DirectivesFeature) is a display-side join over `controllerCode` only,
    /// covers neither the carrier, the stow tree, nor the tag, and lives in
    /// a module that depends on this one — so reusing it is impossible in the
    /// only direction that matters, and widening it would leave the display
    /// join answering a question it was not asked. This is the one place the
    /// rules are spelled out.
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

        // `code → everything reserving `code` also reserves`. Built once over
        // the whole fleet rather than once per directive, and walked once from
        // the whole seed set.
        //
        // Every edge TARGET is required to be a device the fleet actually
        // holds. A dangling reference — a hull we have no row for, an adoption
        // list naming a device a sync has not brought in — names nothing this
        // brain could allocate anyway, and admitting it would put phantom
        // codes in a set whose whole meaning is "real devices, spoken for".
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

    /// A carrier this tick may spend: the right type, standing WITH the print
    /// hub, at rest, and owned by nobody.
    ///
    /// Co-location is the composition, not a preference — `RelayRun.acquire`
    /// looks for a print-capable device at the CARRIER's own location because
    /// the printed clone materialises at the printer, so a vessel anywhere
    /// else would stall `unreachableDevice` on its first evaluation. Launching
    /// a run that cannot possibly proceed is worse than idling: it burns the
    /// operator's attention on a stall the brain created.
    ///
    /// `isBusy` is the shared fleet predicate (`Device.isBusy`), not a
    /// bespoke status list: a vessel mid-travel belongs to no directive, so
    /// reservation cannot see it, but it is just as unavailable.
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
    /// when `freeCarrier` comes back nil.
    ///
    /// **One sentence used to cover two operationally opposite worlds**, and
    /// that is the whole reason this function exists. "no free carrier at
    /// AINALRAM-BELT-1" is the truth when a healthy run has the vessel out for
    /// three minutes, and it is equally the truth when a `needsAttention`
    /// mission of a kind the brain may not touch (`brainManagedStall` admits
    /// `relayRun` only) holds it FOREVER. Both rendered as calm idle, which is
    /// exactly the confusion `brain-robustness-bar` clause 6 forbids: idle-calm
    /// has to be distinguishable from a halt. The live fleet is in the second
    /// state right now — one `heaven_vessel` at the print hub, owned by a
    /// stalled `salvageRun` waiting on a relay the brain would have to grow the
    /// mesh to supply — and the brain reports calm forever.
    ///
    /// **A legibility fix and nothing else.** The reservation rule is
    /// untouched, and the brain still does not go near a non-`relayRun`
    /// directive: this only says out loud what the existing rule already
    /// decided. It also stays a graph fact in the file's established voice
    /// (`rationale`, `sourcing`) — who holds what, and in what state — never a
    /// recommendation.
    ///
    /// **No candidate at all keeps the bare sentence.** With nothing of the
    /// carrier type standing at the hub there is no holder to name and no state
    /// to disambiguate; "no free carrier at SOL-3" is then already the whole
    /// fact, and inventing a clause for it would be noise.
    ///
    /// Candidates are named in device-code order, matching `freeCarrier`'s
    /// `min(by:)`, so the sentence a stateless brain produces is the same every
    /// tick. Two are named and the rest counted — the same judgement `list`
    /// makes about served systems, for the same reason.
    static func carrierBlocker(
        at hub: String, devices: [String: Device], reserved: Set<String>, directives: [Directive]
    ) -> String {
        let hulls = devices.values
            .filter { $0.deviceType == carrierDeviceType && $0.location == hub }
            .sorted { $0.deviceCode < $1.deviceCode }
        guard !hulls.isEmpty else { return "no free carrier at \(hub)" }

        // Untagged is reported as its own state, not folded into the per-vessel
        // clauses below: those explain why a vessel the brain MAY fly is
        // unavailable, and "the operator has not opted this fleet in" is a
        // different fact with a different remedy — one the operator can act on
        // immediately, and which would otherwise read as "all busy".
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

    /// What is wrong with ONE candidate carrier. Ownership is tested before
    /// business: a reserved vessel sitting idle at the hub is the case an
    /// operator cannot otherwise explain, where "V1 is travelling" explains
    /// itself.
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
        // Reserved by a directive the fleet no longer explains (its owner names
        // a device we hold no row for). Rare, and still worth saying honestly
        // rather than dressing up.
        return "\(device.deviceCode) is spoken for"
    }

    /// The holder's state, and — when the brain has no power over it — the fact
    /// that waiting will not help.
    ///
    /// `brainManagedStall` is the authority on that second half rather than a
    /// re-typed `kind == .relayRun`: it is the same predicate that decides
    /// whether the stall-response layer will ever look at this row, so the
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

    /// Which in-force directive reserves `code`, by the SAME closure that
    /// reserved it.
    ///
    /// Re-running `reservedDevices` per directive rather than teaching it to
    /// return an owner map: this is the only caller that needs the owner, it
    /// runs only on the already-blocked path, and the alternative would make
    /// every tick's reservation pass carry a provenance dictionary it never
    /// reads. The closure is what makes the answer right — a carrier holding
    /// another run's cargo is reserved by that run through the upward stow
    /// edge, and naming the directive that actually did it is the whole point.
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

    /// Every first hop a Relay Run in force is already flying to.
    ///
    /// A hop in this set is not a candidate. Reserving the CARRIER alone does
    /// not cover it: with two free carriers, every tick between launch and
    /// arrival would print a second relay (370 units, ~800 s) for a system
    /// already being meshed, and the loser's `travel` step would then find the
    /// target meshed on arrival and hand a spare relay back to nobody.
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

    /// The freedom test itself, over ONE device — extracted so the confirm
    /// -fresh gate applies exactly the predicate the ranking applied.
    ///
    /// That identity is the point: a gate that re-tested "free" more loosely
    /// than the selection did would wave through the very carrier the
    /// selection would now reject, and one that tested it more strictly would
    /// defer ticks that had nothing wrong with them. Two copies of a
    /// four-clause predicate is exactly how that drift starts, so there is one.
    static func isFreeCarrier(_ device: Device, at hub: String, reserved: Set<String>) -> Bool {
        device.deviceType == carrierDeviceType
            && device.hasTag(carrierTag)
            && device.location == hub
            && !device.isBusy
            && !reserved.contains(device.deviceCode)
    }

    // MARK: - The rationale

    /// Why this hop, in terms an operator can check against the map.
    ///
    /// A GRAPH FACT, never a scalar — "meshing VEGA — 3,200 units, 1 hop", not
    /// "score 0.82". `Goal.rationale` is read by a human (it is the why-view's
    /// headline and the launch log line), and the whole point of
    /// `GrowRanking`'s field-by-field key is that a choice stays explainable;
    /// collapsing it back into a number here would throw that away.
    ///
    /// The served-systems clause names where the VALUE is when it is not at
    /// the hop itself. Without it a two-hop grow reads as "meshing POLARISUM"
    /// — a hop toward nothing, at a system with no value of its own.
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

    /// How this run's relay is being sourced, as a clause for the launch line.
    ///
    /// Both arms name their cost, because that is the whole difference between
    /// them and the operator's first question either way is "what did that
    /// cost me?" A pure function rather than string-building inline so the
    /// distance is formatted in exactly one place.
    static func sourcing(_ source: ReclaimChoice?) -> String {
        guard let source else { return "printing a fresh relay at the hub (370 units)" }
        return """
            reclaiming \(source.relay.deviceCode) from \(source.relay.system) \
            (\(String(format: "%.1f", source.distanceLY)) ly out, no resources spent)
            """
    }

    /// Names the first two and counts the rest. A hop can serve a large group
    /// (one relay unlocking a whole pocket of the census), and an unbounded
    /// list in a log line and a UI headline helps nobody.
    private static func list(_ names: [String]) -> String {
        guard names.count > 2 else { return names.joined(separator: ", ") }
        return "\(names[0]), \(names[1]) +\(names.count - 2) more"
    }

    // MARK: - The confirm-fresh gate

    /// The gate's two — and only two — answers.
    ///
    /// There is deliberately no third case for "confirm again", "try the next
    /// candidate", or "take a different carrier". The confirm is not a second
    /// selection pass: re-ranking on it would make WHICH system the brain
    /// meshes depend on the timing of a network read, which is precisely the
    /// dependence the gate exists to remove. It either lets the tick's already
    /// -made decision through, or it stops the tick.
    enum Confirmation: Equatable, Sendable {
        /// Proceed to commit, carrying the AUTHORITATIVE row the server just
        /// gave — the commit-time re-check judges that, not the local copy it
        /// may or may not have been reconciled into.
        case proceed(carrier: Device)
        /// Write nothing; report this. The string is the why-view's line, so
        /// it names the carrier and reads as a sentence.
        case deferred(reason: String)
    }

    /// The AUTHORITATIVE half of the gate: what does the server say about this
    /// carrier, right now, immediately before we commit to it?
    ///
    /// **Why a network read at all.** `plan` ranks over a `WorldView` that may
    /// be seconds old, and nothing refreshes an idle vessel's row by itself
    /// (`ami-drones-are-event-silent` is the extreme case, but a resting
    /// heaven vessel is quiet too). Whether the carrier has left the hub or
    /// picked up an errand is the one question the local database structurally
    /// cannot answer, so it is the one this read is spent on.
    ///
    /// **Why it does not also check ownership.** It cannot do so safely: this
    /// is an `async` network read, so anything it learned about the directive
    /// ledger would be stale by the time the insert opened its own
    /// transaction. That half belongs — and now lives — inside the write
    /// transaction itself (`commitBlocker`, applied in `launch`).
    ///
    /// **A failed confirm defers** — fail-closed, the same reasoning the
    /// reserve rail uses. A `.high` refresh is suppressed by neither the TTL
    /// nor the read-budget floor (`PollCoordinator.refresh` applies both to
    /// `.low` only), so nil here means the authoritative read genuinely did not
    /// land, and "we could not confirm" is not "it is fine". It reports its own
    /// distinct reason, because an operator has to be able to tell an API
    /// problem from a carrier that was taken.
    ///
    /// **When it fires, and how often.** Only from the `.grow` arm of
    /// `evaluateOnce` — i.e. only on a tick that has already decided to commit,
    /// which is what keeps a 5-second loop from becoming a `.high` read every
    /// 5 seconds. The ceiling is one `.high` read per tick (12/min, for ONE
    /// device), reached only while there is a launchable candidate AND the
    /// commitment keeps being refused. Sustaining it needs the refusal to
    /// survive into the next tick's snapshot — a failing read does that by
    /// construction, and a negative answer does it whenever the reconciler
    /// declines the fresh row (`confirm-steps-need-fresh-evidence` records a
    /// live same-second drop path). Deliberate either way: the alternative is
    /// remembering the refusal, which is state between ticks (clause 2), and
    /// the same window would otherwise have the brain committing blind.
    private func confirmCarrier(_ carrier: String) async -> Confirmation {
        @Dependency(\.deviceRefresher) var deviceRefresher

        guard let fresh = await deviceRefresher.refresh(carrier, .high) else {
            // `.error`, not `.notice`: an authoritative read that did not land
            // is a fault, and this line is the only place it is visible. It
            // shares the per-tick repeat characteristic of the "world read
            // failed" line above, and for the same reason — the condition is
            // itself the fault, not chatter about a healthy world.
            logger.error("confirm-read of carrier \(carrier, privacy: .public) failed — deferring launch")
            return .deferred(reason: "\(BrainDecision.deferralPrefix)carrier \(carrier) could not be confirmed")
        }
        return .proceed(carrier: fresh)
    }

    /// The LOCAL half of the gate, as a pure function of one consistent set of
    /// rows: is there any reason this commitment must not go ahead? Nil means
    /// commit.
    ///
    /// It re-applies the two predicates the SELECTION applied, against rows
    /// read inside the insert's own transaction:
    ///
    ///   - `isFreeCarrier`, over the reservation closure — the half that closes
    ///     the operator race. A UI launcher (`NewDirectiveFeature`) writes a
    ///     `directives` row on a vessel the operator picked and touches no
    ///     device row at all, so a gate that re-read only the vessel would see
    ///     an idle heaven vessel standing at the hub and commit straight into a
    ///     collision — two directives owning one carrier.
    ///   - `inFlightTargets` — latent today (no UI constructs a `.relayRun`,
    ///     and the brain loop is serial, so nothing else can write one inside
    ///     the window), live the moment a second brain-side launcher lands:
    ///     prune, or the multi-launch pass `plan`'s doc anticipates. The cost
    ///     of missing it is the same 370-unit, ~800 s duplicate print the
    ///     selection-side filter exists to prevent, so it is re-checked here
    ///     rather than left for that task to remember.
    ///   - `inFlightSources` — the same argument again for the RECLAIM half.
    ///     Losing this race is worse than losing the target one: two carriers
    ///     converge on one relay, the second finds it already stowed aboard
    ///     somebody else and stalls (`RelayRun.reclaimDiagnosis` names exactly
    ///     that case), and the mesh has meanwhile lost a node for one grow
    ///     instead of two. A blocked commit DEFERS the whole tick rather than
    ///     falling back to a print, because the tick's decision was made
    ///     outside this transaction and the gate's contract is to let it
    ///     through or stop it — never to substitute a different, resource
    ///     -spending one. The next tick re-sources from scratch, five seconds
    ///     later, at no cost but latency.
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

    /// Create the Relay Run row. The brain's ONE enactment on the grow side.
    ///
    /// Everything downstream is already built: the supervisor spawns an
    /// executor for a `.running` row within a tick, and `RelayRun` takes it
    /// from `acquire` (print at the hub) to `settling` (the target system
    /// reads as meshed). So the fields below are the whole interface between
    /// the brain and the mission, and each is a decision:
    ///
    ///   - `sourceRelayCode` — where the relay comes from, and the one field
    ///     here that is a JUDGEMENT rather than a constant. Nil prints a fresh
    ///     one at the hub (370 units, ~800 s); non-nil sends the carrier to
    ///     reclaim the spare relay it names, for no resources at all. See
    ///     `reclaimSource` for how it is chosen and `RelayRun.acquire` for the
    ///     two branches it selects between.
    ///   - `fleetTag: nil` / `controllerCode: nil` — ownership is the carrier
    ///     and nothing else (ticket 05). The relay is held by transitive stow;
    ///     a committed-devices lease field was proposed and rejected.
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
    /// with: it either sees the racing row or the racing row waits for us. It
    /// costs no extra I/O — the rows are read on the connection already open to
    /// do the insert, and the `.high` device read was paid for before we got
    /// here.
    ///
    /// The residual window is the one nothing local can close: the carrier's
    /// SERVER state, as of a read that has just completed. That is the price of
    /// the world being remote, and it is measured in the milliseconds since the
    /// confirm-read returned rather than in the seconds since the snapshot.
    private func launch(
        goal: Goal, ranked: [GrowCandidate], carrier: Device, hub: String, origin: String,
        source: ReclaimChoice?, database: any DatabaseWriter
    ) async -> BrainDecision {
        // A `stop()` can have landed while the confirm-read above was in
        // flight. Inserting here would write a directive for an account that is
        // logging out, on a carrier the next session may not even own — and the
        // row would be wiped moments later, after the executor had possibly
        // already dispatched off it. See `report()`'s cancellation note.
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
            // The carrier comes home. This was false, on the reasoning that a
            // Relay Run "chains onward rather than coming home" — true only
            // with a fleet big enough that another target is always in reach.
            // With one carrier it meant the run planted a relay and left the
            // vessel parked at the target until a human flew it back, which is
            // where the live fleet spent most of 2026-08-04.
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
            // `.debug`, not `.notice`. A caught race is a real decision and it
            // is reported to the operator through the why-view — but this line
            // can repeat every tick (the negative answer only clears once the
            // next snapshot agrees, which a declined reconcile can delay), and
            // nothing per-tick belongs at `.notice`.
            logger.debug(
                """
                deferred launch on \(carrier.deviceCode, privacy: .public) \
                at \(hub, privacy: .public) — \(blocker, privacy: .public)
                """
            )
            return .idle(reason: blocker)
        }
        // `.notice`, unlike every other line in this file: a launch is rare,
        // irreversible in resource terms (it either ends in a 370-unit print or
        // tears a live relay out of the mesh), and the one brain event an
        // operator reading the log after the fact needs to find. The rationale
        // and the SOURCING both ride along so the line explains itself without
        // a second lookup — and the sourcing clause is a graph fact ("R9 at
        // DEADEND, 7.1 ly from VEGA"), checkable against the map, for the same
        // reason `rationale` is one.
        logger.notice(
            """
            launched relay run \(directive.id, privacy: .public) on \(carrier.deviceCode, privacy: .public) \
            — \(goal.rationale, privacy: .public), \(Self.sourcing(source), privacy: .public)
            """
        )
        return .dispatch(goal, ranked: ranked)
    }
}
