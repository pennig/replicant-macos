//
//  HaulRun.swift
//  Replicould — DirectiveEngine
//
//  Keep every `auto:haul`-tagged AMI transport controller pointed at the richest
//  reachable stockpile, so the piles a Salvage Run leaves behind come home
//  (design spec §6). Continuous — there is no finish line — and uncoupled from
//  the Salvage Run entirely.
//
//  **The engine does not haul.** The controller's `ferry` directive issues every
//  `collect_resources` and `deposit_resources` server-side, on its own tick and
//  at no cost to our API budget. This machine only chooses targets: one
//  `set_directive` per pile drained, and one census read a minute.
//
//  **One controller repointed per tick.** `assigning` claims exactly one
//  pending controller (`.assignController`) and hands it to `dispatching` to
//  actually command — never the whole fleet at once. `confirming` then judges
//  ONLY the controller `Directive.controllerCode` names, never the fleet's
//  full plan. A fix landed 2026-07-31 after review found the earlier
//  single-step `assign` let `confirming` re-derive the whole plan: with two
//  tagged controllers and only one ever dispatched, the untouched second
//  controller always read as "pending" and `confirming` could never leave,
//  wedging the run into a false `.commandRejected` stall within
//  `confirmDeadline`. See `Step.dispatching`'s and `Step.confirming`'s doc
//  comments for the two failure modes this shape closes.
//
//  **`confirming` accepts ANY config this run could have issued, not just the
//  most recently dispatched pile** (`hasTakenSomeHaulConfig`) — required so a
//  moving census doesn't false-stall a controller that took the command
//  correctly. That relaxation has a cost: it can no longer tell "settled" from
//  "still running the config from BEFORE this dispatch", so a controller whose
//  new command never actually applies (accepted but not taken — a lost write,
//  or the server's own tick winning a race) reads as instantly settled and
//  gets re-pinned and re-dispatched every cycle, forever, with no deadline and
//  no stall. TWO guards close that, and the first is the one steady state
//  actually needs: `confirming` refuses to read a row OLDER than the dispatch
//  as evidence at all (`controller.updatedAt >= directive.stepStartedAt`),
//  buying one authoritative read instead. Without it the ORDINARY repoint —
//  where the controller is already hauling the previous pile, and its row is
//  minutes old — burned three redundant `set_directive` POSTs and then falsely
//  stalled (2026-07-31 final review). `dispatchAssignment` covers what remains,
//  a command genuinely accepted but never applied, with a log-derived re-entry
//  budget (`dispatchAttemptCount`/`dispatchAttemptLimit`) — the same escape
//  hatch `SalvageRun.stepEntryCount` uses, adapted to a bound spanning three
//  steps instead of one AND scoped to ONE controller, not the whole tagged
//  fleet: an UNSCOPED count trips on the very first pass of any healthy 4+
//  controller fleet, because `assign` pins one controller per evaluation and
//  only leaves the loop once every controller is in force, so a pass
//  repointing N controllers writes N consecutive `dispatching` entries before
//  any out-of-loop step appears between them (caught 2026-07-31). Scoping
//  reads `DirectiveLogEntry.deviceCode`, which `DirectiveExecutor`'s
//  `.assignController` path now stamps with the claimed controller. See
//  `dispatchAttemptCount`'s doc comment.
//
//  Pure by contract: no I/O, no clock reads (time comes from `world.now`), no
//  randomness. Every effect is the returned `MissionAction`.
//

import Foundation
import GameModels
import GameServices
import OSLog
import UniverseModels

private let logger = Logger(subsystem: "name.pennig.replicould", category: "DirectiveEngine")

public struct HaulRun: MissionStepMachine {
    public let kind: DirectiveKind = .haulRun
    public var firstStep: String { Step.preflight }

    public init() {}

    /// This mission's step vocabulary. Plain strings because `Directive.step` is
    /// deliberately untyped — each kind owns its own vocabulary.
    public enum Step {
        public static let preflight = "preflight"
        public static let surveying = "surveying"
        public static let assigning = "assigning"
        /// Issues the command `assigning` chose, against the controller it just
        /// pinned (`Directive.controllerCode`, written there via
        /// `.assignController`).
        ///
        /// Split out from `assigning` for one reason: `confirming` must be able
        /// to judge EXACTLY the controller a dispatch was aimed at, never the
        /// whole tagged fleet. Before this step existed, `assigning` dispatched
        /// directly and `confirming` re-derived the FULL plan on every tick,
        /// waiting for every controller in it to be in force. But `assigning`
        /// only ever repoints ONE controller per evaluation ("N controllers
        /// settle over N ticks") — so with two tagged controllers, the second
        /// one (never dispatched) always read as still-pending, and
        /// `confirming` could never leave: it waited out `confirmDeadline` on a
        /// controller nothing had asked to change, then falsely stalled the
        /// whole run with `.commandRejected`. Pinning the ONE controller being
        /// worked, here, is what lets `confirming` ask about it alone.
        ///
        /// Also keeps the same-step-dispatch rule intact on its own: this step
        /// dispatches with `nextStep: .confirming`, never itself — `set_directive`
        /// classifies as `.immediate` and creates NO tracked `Operation`, so a
        /// step naming itself as `nextStep` would find `world.openOperation`
        /// structurally nil every time and re-issue on every 5s tick forever.
        /// See the `same-step-dispatch-needs-tracked-op` note.
        public static let dispatching = "dispatching"
        /// Polls until the pinned controller (`Directive.controllerCode`)
        /// reports, ON A ROW READ AFTER THE DISPATCH, SOME config this run
        /// could have issued — `ferry` or `shuttle`, delivering to
        /// `deliveryLocation` — then hands back to `assigning`, which owns
        /// repointing. A row older than the dispatch buys one authoritative
        /// read rather than being believed; see `confirm`.
        ///
        /// Deliberately does NOT require that config to be the exact pile
        /// `dispatching` most recently sent: the stockpile census has another
        /// writer (`LocationsFeature` refreshes it whenever the operator opens
        /// the Locations catalog) and can move during the up-to-`confirmDeadline`
        /// wait — a new pile appearing, or the dispatched pile draining past a
        /// rival. Judging against a RE-DERIVED plan would then compare the
        /// controller's real, accepted config against a target that no longer
        /// matches it, producing the exact same false `.commandRejected` stall
        /// the multi-controller bug did, but reachable with a single controller.
        ///
        /// Split from `assigning`/`dispatching` — never dispatches, only waits
        /// or reads — because `set_directive` creates no tracked `Operation`,
        /// so any elapsed-interval measurement must live in a step whose
        /// pre-deadline path is exclusively `.wait`: that is the one action
        /// `DirectiveExecutor` does not re-stamp `stepStartedAt` for. See the
        /// `same-step-dispatch-needs-tracked-op` note; this pairing is the fix.
        public static let confirming = "confirming"
        public static let hauling = "hauling"
    }

    /// The fleet tag a row falls back to when it carries none of its own.
    public static let defaultFleetTag = "auto:haul"

    /// Where everything is delivered. Hard-coded to match the Salvage Run's own
    /// base: the autofactories are here, and two runs disagreeing about home
    /// would be a silent, expensive bug.
    public static let deliveryLocation = "AINALRAM-BELT-1"

    /// The capability that makes a device a haul controller. Matched on the
    /// DIRECTIVE it offers rather than `device_type`, exactly as `AMIFleet` does
    /// — a differently-named controller offering `ferry` is still one.
    public static let requiredDirective = HaulTargetPlanner.ferry

    /// How long between census reads. One `GET /v1/locations` per interval is the
    /// run's entire steady-state cost.
    public static let pollInterval: TimeInterval = 60

    /// How stale a fleet row may be and still be believed at preflight. Same
    /// reasoning as `SurveyRun.stagingFreshness`: a positive finding read off a
    /// row nothing has touched in an hour is not evidence.
    public static let stagingFreshness: TimeInterval = 5 * 60

    /// How long to let a controller take the dispatched config before treating
    /// silence as a rejection.
    public static let confirmDeadline: TimeInterval = 5 * 60

    /// How stale the pinned controller's row must be before `confirming` will
    /// spend an authoritative read on it.
    ///
    /// Only reached when the row PREDATES the dispatch — see `confirm` — so in
    /// the healthy case this throttle costs one read per repoint. Its real job
    /// is the degenerate one: a row read moments before the command went out is
    /// stale-as-evidence but freshly-read as a request, and re-reading it on
    /// the very next 5s tick would buy nothing but rate limit.
    public static let confirmReadInterval: TimeInterval = 30

    /// How many `dispatching → confirming → assigning` cycles the SAME pinned
    /// controller may spend without ever satisfying `isInForce`, before
    /// `dispatchAssignment` stalls instead of dispatching again. See
    /// `dispatchAttemptCount`'s doc comment for why this exists.
    public static let dispatchAttemptLimit = 3

    public func nextAction(directive: Directive, world: WorldSnapshot) -> MissionAction {
        switch directive.step {
        case Step.preflight: return preflight(directive, world)
        case Step.surveying: return survey(directive, world)
        case Step.assigning: return assign(directive, world)
        case Step.dispatching: return dispatchAssignment(directive, world)
        case Step.confirming: return confirm(directive, world)
        case Step.hauling: return haul(directive, world)
        default:
            // An unrecognised step must never dispatch. Waiting is inert and
            // recoverable — the user can cancel.
            logger.notice("haul run \(directive.id, privacy: .public): unknown step \(directive.step, privacy: .public) — waiting")
            return .wait
        }
    }

    /// A Haul Run never emits `.extendQueue`: its targets are locations ranked
    /// from the footprint census, not systems drawn from `RoamContext` (which
    /// carries no footprints at all). Answering `.idle` rather than `.exhausted`
    /// keeps a stray call from finishing a run that has no finish line.
    public func plan(_ context: RoamContext) -> RoamPlan { .idle }

    // MARK: - Fleet

    /// Every tagged controller offering `ferry`, in a stable order.
    ///
    /// Resolved by TAG, never by location: the tag is the operator's opt-in, and
    /// untagging a controller is how they take it back. Sorted by device code so
    /// the same controller keeps the same rank across evaluations.
    public static func controllers(in world: WorldSnapshot, tag: String) -> [Device] {
        world.devices.values
            .filter { $0.tags.contains(tag) }
            .filter { $0.availableDirectives.contains(requiredDirective) }
            .sorted { $0.deviceCode < $1.deviceCode }
    }

    private static func fleetTag(of directive: Directive) -> String {
        directive.fleetTag ?? defaultFleetTag
    }

    /// The stockpile the tagged fleet is actually draining right now, or nil
    /// when no tagged controller holds a haul config — the "Nothing reachable"
    /// state.
    ///
    /// **The row subtitle's only possible source** (design spec §9: "the row
    /// subtitle names the work in flight rather than a count… read from the
    /// controllers' own in-force config"). A Haul Run stores no assignment
    /// state — not a queue, not a `roamCentre`, not a drained-pile count — so
    /// there is nothing on the `Directive` to render; what it is working exists
    /// only on the controllers themselves. Lives here rather than in the
    /// feature so "is this a config we could have issued" has exactly one
    /// definition (`hasTakenSomeHaulConfig`), shared with `confirming`.
    ///
    /// Names the LOWEST-CODED controller's pile when several are hauling
    /// different ones: the same total order `controllers(in:tag:)` and the
    /// planner rank by, so the answer is stable across evaluations rather than
    /// flickering with dictionary order. §9 asks for one designation, and
    /// summarising N of them would be inventing UI the spec declines to offer.
    public static func currentHaulTarget(devices: [Device], tag: String) -> String? {
        devices
            .filter { $0.tags.contains(tag) }
            .sorted { $0.deviceCode < $1.deviceCode }
            .lazy
            .compactMap { device -> String? in
                guard hasTakenSomeHaulConfig(device) else { return nil }
                return device.currentDirectiveConfig?["collect"]?.stringValue
            }
            .first
    }

    /// The assignment this evaluation would like every controller to be running.
    private static func plans(_ directive: Directive, _ world: WorldSnapshot) -> [HaulTargetPlanner.Assignment] {
        HaulTargetPlanner.assignments(
            controllers: controllers(in: world, tag: fleetTag(of: directive)),
            footprints: world.footprints.mapValues(\.resources),
            meshSystems: SalvageTargetPlanner.meshSystems(in: Array(world.devices.values)),
            delivery: deliveryLocation
        )
    }

    /// Whether the server already reports this exact assignment in force.
    ///
    /// Read off the controller's OWN `ami_directive` block — the server's record
    /// of what it is working — so the run needs no column of its own to remember
    /// assignments, and cannot drift from reality after a relaunch.
    ///
    /// `_eval_state` is deliberately NOT consulted: a controller reads
    /// `blocked:[('no_taxi_plate', 1)]` while its surge-capable freighter hauls
    /// perfectly well (observed live 2026-07-31), so treating `blocked:` as a
    /// fault would halt a healthy run.
    ///
    /// Used by `assign` to decide whether a controller needs (re)pointing at
    /// all. `confirm` deliberately does NOT use this — see `hasTakenSomeHaulConfig`
    /// and `Step.confirming`'s doc comment for why a looser check is required
    /// there.
    static func isInForce(_ assignment: HaulTargetPlanner.Assignment, in world: WorldSnapshot) -> Bool {
        guard let controller = world.device(assignment.controllerCode),
              controller.currentDirective == assignment.directive,
              let config = controller.currentDirectiveConfig
        else { return false }
        return config["collect"]?.stringValue == assignment.location
            && config["deliver"]?.stringValue == deliveryLocation
    }

    /// Whether `controller` currently runs ANY config this run could have
    /// issued — `ferry` or `shuttle`, delivering to `deliveryLocation` —
    /// regardless of which pile it names.
    ///
    /// `confirm` uses this instead of `isInForce` against a re-derived plan,
    /// because the stockpile census can move during the confirm window (see
    /// `Step.confirming`'s doc comment): a plan-based comparison would then
    /// judge the controller's real, accepted config against a target that has
    /// since changed, and never match. `_eval_state` stays unread here too,
    /// for the same reason `isInForce` ignores it.
    ///
    /// **Only meaningful on a row read AFTER the dispatch.** Being deliberately
    /// blind to which pile is named makes it equally blind to the controller's
    /// PRE-dispatch config, which in steady state satisfies it exactly. `confirm`
    /// is what enforces that ordering (`updatedAt >= stepStartedAt`); calling
    /// this against an arbitrary row answers "is this controller hauling for
    /// us", not "did it take the command".
    static func hasTakenSomeHaulConfig(_ controller: Device) -> Bool {
        guard let currentDirective = controller.currentDirective,
              [HaulTargetPlanner.ferry, HaulTargetPlanner.shuttle].contains(currentDirective),
              let config = controller.currentDirectiveConfig
        else { return false }
        return config["deliver"]?.stringValue == deliveryLocation
    }

    // MARK: - Re-entry budget

    /// How many times, contiguously, `controllerCode` has been PINNED for
    /// dispatch — i.e. how many times `dispatching` has been entered naming
    /// this specific controller — without the loop leaving for `assigning`'s
    /// SETTLED exit (`Step.hauling`) or an operator resolution.
    ///
    /// **This counts entries into `dispatching`, not completed `set_directive`
    /// POSTs.** Several of `dispatchAssignment`'s own exits (`controllerCode`
    /// nil, the pinned device vanished, nothing pending for it, or it is
    /// already `isInForce`) leave without dispatching anything at all — yet
    /// each still followed a `.stepStarted(dispatching)` entry written by
    /// `assign`'s `.assignController`, BEFORE `dispatchAssignment` ever ran to
    /// decide whether to actually dispatch. That is still the right quantity
    /// to bound: every one of those exits either ends the run or hands back to
    /// `assigning`, which will only re-pin THIS controller if it is STILL not
    /// `isInForce` — so a controller repeatedly re-ENTERING `dispatching` is
    /// exactly a controller `assign` keeps choosing to (re)point, dispatch
    /// count or not.
    ///
    /// **Why this exists.** `hasTakenSomeHaulConfig` (used by `confirm`) is
    /// deliberately looser than `isInForce` (used by `assign`) so a moving
    /// census doesn't false-stall a controller that took the dispatched
    /// command correctly. The cost: `confirm` can no longer distinguish "took
    /// the NEW config" from "still running the OLD one" — a command that is
    /// accepted but never actually applied (a lost write, or the controller's
    /// own tick winning a race) reads as instantly settled, so `confirm`
    /// advances to `assigning` immediately, `assign`'s STRICT `isInForce`
    /// check still sees the wrong pile and re-pins the same controller, and
    /// the cycle repeats with no deadline anywhere in it — the loosened check
    /// never waits, so `confirmDeadline` cannot accumulate. This budget is the
    /// terminator that relaxation removed.
    ///
    /// **Read from the timeline, not a column** — the same technique
    /// `SalvageRun.stepEntryCount` uses (see the
    /// `same-step-dispatch-needs-tracked-op` memory note's "escape hatch"
    /// section), adapted twice over for this shape: the bound spans THREE
    /// steps instead of one — `assigning` (pin) and `confirming` (poll)
    /// entries are transparent, linking one dispatch to the next without
    /// themselves costing a command, while `dispatching` entries are counted,
    /// because that is where the actual `set_directive` POST happens (or
    /// would have) and is exactly the budget the file header's "one
    /// `set_directive` per pile drained" promises — AND the count is scoped to
    /// ONE controller (`controllerCode`) rather than the whole pass: `assign`
    /// pins one controller per evaluation and only leaves the loop once EVERY
    /// controller in the fleet is in force, so an unscoped count over N
    /// healthy, never-retried controllers reaches N on the very first pass —
    /// a real incident on a 4-controller fleet, caught 2026-07-31. Scoping is
    /// what `DirectiveLogEntry.deviceCode` is for: `DirectiveExecutor`'s
    /// `.assignController` path stamps the claimed controller onto the
    /// `.stepStarted(dispatching)` entry it writes (previously always nil),
    /// so a `dispatching` entry naming a DIFFERENT controller is simply
    /// irrelevant here rather than counted or treated as a loop boundary —
    /// it neither adds to this controller's count nor resets it, since
    /// `assign` can legitimately interleave several controllers' pins within
    /// one pass. The walk stops (without counting) at any `.stepStarted`
    /// naming a step OUTSIDE the loop (`preflight`/`surveying`/`hauling`) —
    /// evidence the run genuinely left it — and stops (counting) at a
    /// `.resolved` entry, so an operator's Retry buys a fresh budget rather
    /// than replaying an exhausted one, exactly like `stepEntryCount`.
    ///
    /// **Deliberately does NOT floor to 1** the way `stepEntryCount` does.
    /// `stepEntryCount` floors because being IN a step at all guarantees at
    /// least one entry into it, including the degenerate case of a step
    /// that's also a mission's `firstStep` — evaluated before anything has
    /// ever been logged for that directive. `dispatching` is never a
    /// `firstStep`: the ONLY way into it is `assign`'s `.assignController`,
    /// which unconditionally logs an entry first, so a real, on-disk
    /// evaluation of this step always has at least one matching entry already
    /// in `world.log` by the time this runs. A result of 0 therefore reflects
    /// a log that was never populated at all — a bare test fixture, not
    /// reachable production state — and returning 0 rather than flooring to 1
    /// keeps the guard permissive in exactly that untested-fixture case
    /// rather than asserting a floor production can't actually violate.
    static func dispatchAttemptCount(
        _ directive: Directive, _ world: WorldSnapshot, controllerCode: String
    ) -> Int {
        var count = 0
        for entry in world.log.reversed() {
            if entry.kind == .resolved {
                count += 1
                break
            }
            guard entry.kind == .stepStarted else { continue }
            switch entry.step {
            case Step.dispatching:
                if entry.deviceCode == controllerCode { count += 1 }
            case Step.assigning, Step.confirming:
                continue
            default:
                return count
            }
        }
        return count
    }

    // MARK: - Steps

    /// Confirm there is a fleet at all, re-reading it authoritatively when the
    /// local rows are empty or stale. The tag scope is the only one that sees
    /// every member regardless of state.
    private func preflight(_ directive: Directive, _ world: WorldSnapshot) -> MissionAction {
        let tag = Self.fleetTag(of: directive)
        let found = Self.controllers(in: world, tag: tag)
        let stale = found.isEmpty || found.contains {
            world.now.timeIntervalSince($0.updatedAt) > Self.stagingFreshness
        }
        if stale {
            return .refreshFleet(tag: tag, thenStall: .noHaulControllerTagged)
        }
        return .advanceStep(nextStep: Step.surveying)
    }

    /// Refresh the stockpile census — one request that serves both discovery and
    /// drain detection. Gated on freshness so the engine's 5s tick cannot
    /// multiply into requests.
    private func survey(_ directive: Directive, _ world: WorldSnapshot) -> MissionAction {
        let newest = world.footprints.values.map(\.fetchedAt).max()
        if let newest, world.now.timeIntervalSince(newest) < Self.pollInterval {
            return .advanceStep(nextStep: Step.assigning)
        }
        return .refreshFootprint(nextStep: Step.assigning)
    }

    /// Pin ONE pending controller for `dispatching` to command, or move on when
    /// every controller already matches. One pin per evaluation keeps the
    /// one-action-per-tick contract; N controllers settle over N ticks.
    ///
    /// Does not itself check `world.device(pending.controllerCode)` for
    /// existence — `pending` always comes from `Self.plans`, which only ever
    /// names controllers `Self.controllers` found IN `world.devices`, so that
    /// guard could never fire here. The equivalent, LIVE guard is in
    /// `dispatchAssignment`, which reads `Directive.controllerCode` back off
    /// the persisted row — and a row's controller CAN have vanished by the
    /// time that next tick runs.
    private func assign(_ directive: Directive, _ world: WorldSnapshot) -> MissionAction {
        let tag = Self.fleetTag(of: directive)
        guard !Self.controllers(in: world, tag: tag).isEmpty else {
            // Spec §7 raises `noHaulControllerTagged` on "a fresh TAG READ finds
            // no `auto:haul` controller", never on local silence — so mirror
            // `preflight` and buy the read first. `world.devices` is local
            // SQLite, and a transient gap there (a sync that has not landed, a
            // row nothing has touched) would otherwise stall a healthy fleet
            // and demand a human for something a single request settles. The
            // engine's `reAsk` bounds it: if the fresh rows still show no
            // controller, the carried reason surfaces on this same tick.
            return .refreshFleet(tag: tag, thenStall: .noHaulControllerTagged)
        }
        let assignments = Self.plans(directive, world)
        guard let pending = assignments.first(where: { !Self.isInForce($0, in: world) }) else {
            // Either every controller is correctly pointed, or nothing is
            // reachable at all. Both are the same healthy answer: go and wait.
            // Never `.done` — the Salvage Run keeps making new piles under this
            // one, so an empty frontier is a lull (spec §5).
            return .advanceStep(nextStep: Step.hauling)
        }
        logger.debug("haul run \(directive.id, privacy: .public): pinning \(pending.controllerCode, privacy: .public)")
        return .assignController(deviceCode: pending.controllerCode, nextStep: Step.dispatching)
    }

    /// Issue the command `assigning` chose, against the controller it just
    /// pinned. Re-derives the target from the CURRENT world rather than
    /// trusting anything carried on the directive — nothing is; the run stores
    /// no assignment state of its own beyond `controllerCode` (file header).
    private func dispatchAssignment(_ directive: Directive, _ world: WorldSnapshot) -> MissionAction {
        guard let controllerCode = directive.controllerCode else {
            // `assign` always pins one before advancing here. If it's somehow
            // missing, there is nothing to dispatch to — go back and re-plan.
            return .advanceStep(nextStep: Step.assigning)
        }
        guard world.device(controllerCode) != nil else {
            // `world.device(_:)` is a raw lookup by code across ALL devices,
            // independent of tags — untagging a controller removes it from
            // `Self.controllers(...)`'s FILTERED fleet, never from
            // `world.devices` itself. So this can only fail when the device is
            // genuinely gone from the account (released, scrapped, or never
            // synced), not merely untagged. THIS is the live version of the
            // unreachable-device guard: unlike in `assign`, `controllerCode`
            // here is read back off the persisted row, so it CAN legitimately
            // name a device that has since vanished outright. A configuration
            // problem, not a lull.
            return .stall(.unreachableDevice)
        }
        guard let pending = Self.plans(directive, world).first(where: { $0.controllerCode == controllerCode }) else {
            // The census moved since `assign` ran and this controller no
            // longer has anything pending. Nothing to dispatch — let `assign`
            // re-plan.
            return .advanceStep(nextStep: Step.assigning)
        }
        if Self.isInForce(pending, in: world) {
            // Became correctly pointed between the `assigning` and
            // `dispatching` ticks (another controller's dispatch nudged the
            // ranking, say). Nothing to send — nothing to confirm either.
            return .advanceStep(nextStep: Step.assigning)
        }
        guard Self.dispatchAttemptCount(directive, world, controllerCode: controllerCode) <= Self.dispatchAttemptLimit else {
            // This controller has already spent its repeat-dispatch budget
            // without ever satisfying `isInForce` — see
            // `dispatchAttemptCount`'s doc comment. Surface it rather than
            // spending another POST on a command that has already failed to
            // apply `dispatchAttemptLimit` times running.
            logger.notice("haul run \(directive.id, privacy: .public): \(controllerCode, privacy: .public) exhausted its dispatch-attempt budget — stalling")
            return .stall(.commandRejected)
        }
        logger.info("haul run \(directive.id, privacy: .public): pointing \(pending.controllerCode, privacy: .public) at \(pending.location, privacy: .public)")
        return .dispatch(
            kind: .setDirective,
            deviceCode: pending.controllerCode,
            params: CommandParams(directive: pending.directive, configuration: [
                "collect": .string(pending.location),
                "deliver": .string(Self.deliveryLocation),
            ]),
            nextStep: Step.confirming
        )
    }

    /// Poll until the PINNED controller (`Directive.controllerCode`) reports a
    /// config this run could have issued, then go back to `assigning` — never
    /// re-derives the whole fleet's plan, and never dispatches, which is what
    /// lets `confirmDeadline` accumulate honestly. See `Step.confirming`'s doc
    /// comment for why both of those matter.
    ///
    /// Every path that STAYS in this step returns `.wait`, including the
    /// pre-deadline `.refreshDevices` below — `reAsk` collapses a repeat
    /// request into `.wait`, and `.wait` is the one action `DirectiveExecutor`
    /// does not re-stamp `stepStartedAt` for. That is what keeps the deadline
    /// this step measures real.
    private func confirm(_ directive: Directive, _ world: WorldSnapshot) -> MissionAction {
        guard let controllerCode = directive.controllerCode else {
            // `dispatchAssignment` always pins one before advancing here.
            // Defensive only: go back and let `assign` re-derive it.
            return .advanceStep(nextStep: Step.assigning)
        }
        guard let controller = world.device(controllerCode) else {
            // Absent from `world.devices` outright — same "genuinely gone,
            // not merely untagged" distinction `dispatchAssignment`'s matching
            // guard documents. Waiting out the deadline on a device that can
            // never report back would just delay reaching the same
            // conclusion.
            return .stall(.unreachableDevice)
        }
        guard controller.updatedAt >= directive.stepStartedAt else {
            // The local row was READ BEFORE the command went out, so it cannot
            // say whether the controller took it — and because
            // `hasTakenSomeHaulConfig` accepts ANY ferry/shuttle delivering
            // home, the controller's PRE-dispatch config is exactly the thing
            // it would mistake for evidence. In steady state that is the
            // normal case, not an edge one: a repoint dispatches to a
            // controller that is already hauling something, and device rows
            // refresh about five minutes apart while this loop runs every 5s.
            // Believing the stale row reported "settled" on the very next
            // tick, so `confirming` never waited, `confirmDeadline` never
            // accumulated, the post-deadline read below was unreachable, and
            // `assigning`'s strict `isInForce` re-pinned the same controller
            // for another POST until `dispatchAttemptCount` stalled the run —
            // three redundant `set_directive`s and a false `.commandRejected`
            // on a command that had landed (2026-07-31 final review).
            //
            // The deadline check has to come FIRST, ahead of the throttled
            // read below: a row that can never be refreshed — offline, rate
            // limited, a controller the server 404s — never satisfies this
            // guard, so the throttled-read branch is the only thing that would
            // ever run for it. That branch alone can't stall the run, because
            // a failed or empty read never advances `controller.updatedAt`,
            // so the next evaluation re-enters this same guard and asks
            // again — an unrefreshable row would poll `.high` reads forever
            // rather than ever reaching `confirmDeadline`.
            if world.now.timeIntervalSince(directive.stepStartedAt) >= Self.confirmDeadline {
                return .refreshDevices(deviceCodes: [controllerCode], thenStall: .commandRejected)
            }
            // Buy one authoritative read instead, throttled by
            // `confirmReadInterval` so this costs a read per repoint rather
            // than one per tick. `thenStall: nil` matters: the engine's `reAsk`
            // collapses a repeat request into `.wait`, so a read that fails or
            // brings back nothing new is bounded rather than fatal.
            if world.now.timeIntervalSince(controller.updatedAt) > Self.confirmReadInterval {
                return .refreshDevices(deviceCodes: [controllerCode], thenStall: nil)
            }
            return .wait
        }
        if Self.hasTakenSomeHaulConfig(controller) {
            // Settled on SOME config this run could have issued — not
            // necessarily the exact pile most recently dispatched, since the
            // census can move during the wait. `assigning` owns repointing;
            // hand back to it.
            return .advanceStep(nextStep: Step.assigning)
        }
        if world.now.timeIntervalSince(directive.stepStartedAt) < Self.confirmDeadline {
            return .wait
        }
        // Past the deadline, spend one authoritative read before giving up: the
        // command may well have landed while the local row sat stale. If the
        // re-ask still can't see it, the engine stalls with the carried reason.
        return .refreshDevices(deviceCodes: [controllerCode], thenStall: .commandRejected)
    }

    /// The quiet step. `.wait` is the only action that writes nothing, so this is
    /// the one place an interval can be measured without the step resetting the
    /// clock it is reading.
    private func haul(_ directive: Directive, _ world: WorldSnapshot) -> MissionAction {
        if world.now.timeIntervalSince(directive.stepStartedAt) < Self.pollInterval {
            return .wait
        }
        return .advanceStep(nextStep: Step.surveying)
    }
}
