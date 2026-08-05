//
//  HaulRun.swift
//  Replicould — DirectiveEngine
//
//  Keep every `auto:haul`-tagged AMI transport controller pointed at the richest
//  reachable stockpile, so the piles a Salvage Run leaves behind come home.
//  Continuous — there is no finish line — and uncoupled from the Salvage Run.
//
//  **The engine does not haul.** The controller's `ferry` directive issues every
//  `collect_resources` and `deposit_resources` server-side, on its own tick and
//  at no cost to our API budget. This machine only chooses targets: one
//  `set_directive` per pile drained, and one census read a minute.
//
//  **One controller repointed per tick.** `assigning` claims exactly one pending
//  controller and hands it to `dispatching`; `confirming` then judges ONLY the
//  controller `Directive.controllerCode` names, never the fleet's full plan —
//  re-deriving the whole plan waits out `confirmDeadline` on controllers nothing
//  asked to change and then stalls the run `.commandRejected`. See
//  `Step.dispatching` and `Step.confirming`.
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

    /// This mission's step vocabulary, as the bare strings `Directive.step` holds.
    public enum Step {
        /// Prove the tagged fleet exists before anything is commanded.
        public static let preflight = "preflight"
        /// Refresh the stockpile census the target ranking is read from.
        public static let surveying = "surveying"
        /// Pin the one controller this evaluation wants to repoint.
        public static let assigning = "assigning"
        /// Issues the command `assigning` chose, against the controller it just
        /// pinned (`Directive.controllerCode`, written there by
        /// `.assignController`).
        ///
        /// Separate from `assigning` so `confirming` can judge EXACTLY the
        /// controller a dispatch was aimed at: `assigning` repoints only ONE
        /// controller per evaluation, so a `confirming` that re-derives the full
        /// fleet plan waits on controllers nothing has asked to change and
        /// stalls the run once `confirmDeadline` passes.
        ///
        /// Dispatches with `nextStep: .confirming`, never itself: `set_directive`
        /// classifies as `.immediate` and creates NO tracked `Operation`, so a
        /// step naming itself would find `world.openOperation` structurally nil
        /// and re-issue on every 5s tick forever. See the
        /// `same-step-dispatch-needs-tracked-op` note.
        public static let dispatching = "dispatching"
        /// Polls until the pinned controller (`Directive.controllerCode`)
        /// reports, ON A ROW READ AFTER THE DISPATCH, SOME config this run
        /// could have issued — `ferry` or `shuttle`, delivering to
        /// `deliveryLocation` — then hands back to `assigning`, which owns
        /// repointing. A row older than the dispatch buys one authoritative
        /// read rather than being believed; see `confirm`.
        ///
        /// Deliberately does NOT require that config to name the exact pile
        /// `dispatching` most recently sent: the stockpile census has another
        /// writer (`LocationsFeature` refreshes it whenever the operator opens
        /// the Locations catalog) and can move during the wait, so judging
        /// against a RE-DERIVED plan compares the controller's real, accepted
        /// config against a target the census has since moved past, and
        /// false-stalls `.commandRejected` on a single controller.
        ///
        /// Never dispatches, only waits or reads: `set_directive` creates no
        /// tracked `Operation`, so an elapsed-interval measurement holds only in
        /// a step whose pre-deadline path is exclusively `.wait` — the one
        /// action `DirectiveExecutor` does not re-stamp `stepStartedAt` for.
        public static let confirming = "confirming"
        /// The quiet step between census reads.
        public static let hauling = "hauling"
    }

    /// The fleet tag a row falls back to when it carries none of its own.
    public static let defaultFleetTag = "auto:haul"

    /// Where everything is delivered. Must match the Salvage Run's own base —
    /// two runs disagreeing about home split the fleet's deliveries silently.
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
    /// Only reached when the row PREDATES the dispatch (see `confirm`), so in
    /// the healthy case it costs one read per repoint; without the throttle a
    /// row read moments before the command went out — stale as evidence but
    /// freshly read as a request — is re-read on the very next 5s tick, buying
    /// nothing but rate limit.
    public static let confirmReadInterval: TimeInterval = 30

    /// How many `dispatching → confirming → assigning` cycles the SAME pinned
    /// controller may spend without ever satisfying `isInForce`, before
    /// `dispatchAssignment` stalls instead of dispatching again. See
    /// `dispatchAttemptCount`'s doc comment for why this exists.
    public static let dispatchAttemptLimit = 3

    /// Route `directive`'s current step against `world`.
    ///
    /// An unrecognised step waits rather than dispatching: waiting is inert and
    /// the operator can cancel, where guessing would command the fleet.
    public func nextAction(directive: Directive, world: WorldSnapshot) -> MissionAction {
        switch directive.step {
        case Step.preflight: return preflight(directive, world)
        case Step.surveying: return survey(directive, world)
        case Step.assigning: return assign(directive, world)
        case Step.dispatching: return dispatchAssignment(directive, world)
        case Step.confirming: return confirm(directive, world)
        case Step.hauling: return haul(directive, world)
        default:
            logger.notice("haul run \(directive.id, privacy: .public): unknown step \(directive.step, privacy: .public) — waiting")
            return .wait
        }
    }

    /// A Haul Run never roams: its targets are locations ranked from the
    /// footprint census, and `context` carries no footprints at all. Answers
    /// `.idle`, never `.exhausted` — the latter would let a stray call finish a
    /// run that has no finish line.
    public func plan(_ context: RoamContext) -> RoamPlan { .idle }

    // MARK: - Fleet

    /// Every device in `world` carrying `tag` and offering `ferry`, sorted by
    /// device code so a controller keeps its rank across evaluations.
    ///
    /// Resolved by TAG, never by location: the tag is the operator's opt-in, and
    /// untagging a controller is how they take it back.
    public static func controllers(in world: WorldSnapshot, tag: String) -> [Device] {
        world.devices.values
            .filter { $0.hasTag(tag) }
            .filter { $0.availableDirectives.contains(requiredDirective) }
            .sorted { $0.deviceCode < $1.deviceCode }
    }

    /// `directive`'s own fleet tag, or `defaultFleetTag` when it carries none.
    private static func fleetTag(of directive: Directive) -> String {
        directive.fleetTag ?? defaultFleetTag
    }

    /// The stockpile the `tag`ged controllers among `devices` are draining right
    /// now, or nil when none holds a haul config — the "Nothing reachable" state.
    ///
    /// **The row subtitle's only possible source.** A Haul Run stores no
    /// assignment state, so what it is working exists only on the controllers
    /// themselves; defining it here rather than in the feature keeps "is this a
    /// config we could have issued" to one implementation
    /// (`hasTakenSomeHaulConfig`), shared with `confirming`.
    ///
    /// Names the LOWEST-CODED controller's pile when several are hauling
    /// different ones — the same total order `controllers(in:tag:)` and the
    /// planner rank by, so the answer cannot flicker with dictionary order.
    public static func currentHaulTarget(devices: [Device], tag: String) -> String? {
        devices
            .filter { $0.hasTag(tag) }
            .sorted { $0.deviceCode < $1.deviceCode }
            .lazy
            .compactMap { device -> String? in
                guard hasTakenSomeHaulConfig(device) else { return nil }
                return device.currentDirectiveConfig?["collect"]?.stringValue
            }
            .first
    }

    /// The assignments this evaluation would like `directive`'s tagged
    /// controllers to be running, ranked from `world`'s census.
    private static func plans(_ directive: Directive, _ world: WorldSnapshot) -> [HaulTargetPlanner.Assignment] {
        HaulTargetPlanner.assignments(
            controllers: controllers(in: world, tag: fleetTag(of: directive)),
            footprints: world.footprints.mapValues(\.resources),
            meshSystems: SalvageTargetPlanner.meshSystems(in: Array(world.devices.values)),
            delivery: deliveryLocation
        )
    }

    /// Whether `world` already reports `assignment` in force on its controller —
    /// what `assign` decides (re)pointing from.
    ///
    /// Read off the controller's OWN `ami_directive` block, the server's record
    /// of what it is working, so the run needs no column of its own to remember
    /// assignments and cannot drift from reality after a relaunch.
    ///
    /// `_eval_state` is deliberately NOT consulted: a controller can report
    /// `blocked:[('no_taxi_plate', 1)]` while its surge-capable freighter hauls
    /// perfectly well, so treating `blocked:` as a fault halts a healthy run.
    ///
    /// `confirm` must NOT use this — see `hasTakenSomeHaulConfig` and
    /// `Step.confirming` for why a looser check is required there.
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
    /// **Only meaningful on a row read AFTER the dispatch.** Being blind to
    /// which pile is named makes it equally blind to the controller's
    /// PRE-dispatch config, which in steady state satisfies it exactly, so
    /// against an arbitrary row it answers "is this controller hauling for us",
    /// not "did it take the command"; `confirm` is what enforces that ordering.
    ///
    /// `confirm` uses this rather than `isInForce` against a re-derived plan
    /// because the census can move during the confirm window, and a plan-based
    /// comparison would then judge a real, accepted config against a target that
    /// has since changed and never match. `_eval_state` stays unread here too,
    /// for the reason `isInForce` gives.
    static func hasTakenSomeHaulConfig(_ controller: Device) -> Bool {
        guard let currentDirective = controller.currentDirective,
              [HaulTargetPlanner.ferry, HaulTargetPlanner.shuttle].contains(currentDirective),
              let config = controller.currentDirectiveConfig
        else { return false }
        return config["deliver"]?.stringValue == deliveryLocation
    }

    // MARK: - Re-entry budget

    /// How many times, contiguously, `controllerCode` has been PINNED for
    /// dispatch — `.stepStarted(dispatching)` entries in `world.log` naming it —
    /// since `directive` last left the loop or an operator resolved a stall.
    ///
    /// **Counts entries into `dispatching`, not completed `set_directive`
    /// POSTs.** Several of `dispatchAssignment`'s exits dispatch nothing, but
    /// each still follows the entry `assign`'s `.assignController` wrote before
    /// it ran, and each hands back to `assigning`, which re-pins this controller
    /// only while it is STILL not `isInForce` — so a controller re-entering
    /// `dispatching` is exactly one `assign` keeps choosing to repoint.
    ///
    /// **Why it exists.** `confirm`'s check is loose enough to match the
    /// PRE-dispatch config, so a command accepted but never applied reads as
    /// instantly settled: `confirm` never waits, `confirmDeadline` never
    /// accumulates, and `assign`'s strict `isInForce` re-pins and re-dispatches
    /// the same controller with no deadline anywhere in the cycle. This budget is
    /// the terminator that relaxation removed.
    ///
    /// **Must stay scoped to ONE controller.** `assign` pins one controller per
    /// evaluation and leaves the loop only once EVERY controller is in force, so
    /// an unscoped count reaches N on the first healthy pass of an N-controller
    /// fleet and false-stalls it. The scope is `DirectiveLogEntry.deviceCode`,
    /// which `DirectiveExecutor`'s `.assignController` path stamps with the
    /// claimed controller; an entry naming a DIFFERENT controller neither counts
    /// nor resets, since `assign` may interleave pins within one pass.
    ///
    /// **Read from the timeline, not a column** — `SalvageRun.stepEntryCount`'s
    /// technique, over a bound spanning three steps: `assigning` and `confirming`
    /// entries are transparent, `dispatching` entries are counted. The walk stops
    /// without counting at any `.stepStarted` naming a step OUTSIDE the loop
    /// (`preflight`/`surveying`/`hauling`), and stops counting at a `.resolved`
    /// entry, so an operator's Retry buys a fresh budget rather than replaying an
    /// exhausted one.
    ///
    /// **Never floors to 1** the way `stepEntryCount` does: `dispatching` is
    /// never a `firstStep`, so any real evaluation already has a matching entry,
    /// and 0 means a log that was never populated — a bare fixture, where a floor
    /// would assert a bound production cannot violate.
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

    /// Confirm `directive`'s tagged fleet exists in `world`, buying an
    /// authoritative tag read when the local rows are empty or stale. The tag
    /// scope is the only one that sees every member regardless of state.
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

    /// Refresh the stockpile census for `directive` — one request serving both
    /// discovery and drain detection — gated on `world`'s freshest read so the
    /// engine's 5s tick cannot multiply into requests.
    ///
    /// `thenStall: nil` never escalates: a stale census is a lull, `assigning`
    /// still has whatever pile data it last saw, and the `nil`-fallback contract
    /// (`MissionAction.refreshFootprint`) makes a transient failure cost this one
    /// cycle rather than stranding a continuous run.
    private func survey(_ directive: Directive, _ world: WorldSnapshot) -> MissionAction {
        let newest = world.footprints.values.map(\.fetchedAt).max()
        if let newest, world.now.timeIntervalSince(newest) < Self.pollInterval {
            return .advanceStep(nextStep: Step.assigning)
        }
        return .refreshFootprint(nextStep: Step.assigning, thenStall: nil)
    }

    /// Pin ONE pending controller from `directive`'s fleet for `dispatching` to
    /// command, or move on when every controller in `world` already matches. One
    /// pin per evaluation keeps the one-action-per-tick contract; N controllers
    /// settle over N ticks.
    ///
    /// Does not check the pinned controller's existence: `pending` comes from
    /// `Self.plans`, which only names controllers found IN `world.devices`. The
    /// equivalent LIVE guard is in `dispatchAssignment`, which reads
    /// `Directive.controllerCode` back off the persisted row — where it CAN name
    /// a device that has vanished since.
    private func assign(_ directive: Directive, _ world: WorldSnapshot) -> MissionAction {
        let tag = Self.fleetTag(of: directive)
        guard !Self.controllers(in: world, tag: tag).isEmpty else {
            // `noHaulControllerTagged` belongs to a fresh TAG READ finding
            // nothing, never to local silence: `world.devices` is local SQLite,
            // and a transient gap there stalls a healthy fleet and demands a
            // human for what one request settles. `reAsk` bounds the read — if
            // the fresh rows still show no controller, the carried reason
            // surfaces on this same tick.
            return .refreshFleet(tag: tag, thenStall: .noHaulControllerTagged)
        }
        let assignments = Self.plans(directive, world)
        guard let pending = assignments.first(where: { !Self.isInForce($0, in: world) }) else {
            // Every controller correctly pointed, or nothing reachable at all —
            // the same healthy answer either way. Never `.done`: the Salvage Run
            // keeps making new piles under this one, so an empty frontier is a
            // lull.
            return .advanceStep(nextStep: Step.hauling)
        }
        logger.debug("haul run \(directive.id, privacy: .public): pinning \(pending.controllerCode, privacy: .public)")
        return .assignController(deviceCode: pending.controllerCode, nextStep: Step.dispatching)
    }

    /// Issue the command `assigning` chose, against the controller `directive`
    /// pinned. Re-derives the target from `world` rather than trusting anything
    /// carried on the row — the run stores no assignment state of its own beyond
    /// `controllerCode`.
    private func dispatchAssignment(_ directive: Directive, _ world: WorldSnapshot) -> MissionAction {
        guard let controllerCode = directive.controllerCode else {
            // `assign` always pins one before advancing here; with nothing to
            // dispatch to, re-plan.
            return .advanceStep(nextStep: Step.assigning)
        }
        guard world.device(controllerCode) != nil else {
            // Genuinely gone from the account, not merely untagged:
            // `world.device(_:)` is a raw lookup across ALL devices, independent
            // of the tag filter `Self.controllers` applies. A configuration
            // problem, not a lull.
            return .stall(.unreachableDevice)
        }
        guard let pending = Self.plans(directive, world).first(where: { $0.controllerCode == controllerCode }) else {
            // The census moved since `assign` ran and this controller has
            // nothing pending. Let `assign` re-plan.
            return .advanceStep(nextStep: Step.assigning)
        }
        if Self.isInForce(pending, in: world) {
            // Became correctly pointed between the two ticks. Nothing to send,
            // and nothing to confirm either.
            return .advanceStep(nextStep: Step.assigning)
        }
        guard Self.dispatchAttemptCount(directive, world, controllerCode: controllerCode) <= Self.dispatchAttemptLimit else {
            // Budget spent without ever satisfying `isInForce` — surface it
            // rather than spending another POST on a command that has already
            // failed to apply `dispatchAttemptLimit` times running.
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

    /// Poll until the controller `directive` pinned reports, in `world`, a config
    /// this run could have issued, then go back to `assigning`. Never re-derives
    /// the whole fleet's plan and never dispatches — see `Step.confirming` for
    /// why both matter.
    ///
    /// Every path that STAYS in this step returns `.wait`, including the
    /// pre-deadline `.refreshDevices` below (`reAsk` collapses a repeat request
    /// into `.wait`), because `.wait` is the one action `DirectiveExecutor` does
    /// not re-stamp `stepStartedAt` for — anything else makes the deadline this
    /// step measures unreachable.
    private func confirm(_ directive: Directive, _ world: WorldSnapshot) -> MissionAction {
        guard let controllerCode = directive.controllerCode else {
            // `dispatchAssignment` always pins one before advancing here.
            // Defensive only: let `assign` re-derive it.
            return .advanceStep(nextStep: Step.assigning)
        }
        guard let controller = world.device(controllerCode) else {
            // Genuinely gone, not merely untagged — the distinction
            // `dispatchAssignment`'s matching guard documents. Waiting out the
            // deadline on a device that can never report back only delays the
            // same conclusion.
            return .stall(.unreachableDevice)
        }
        guard controller.updatedAt >= directive.stepStartedAt else {
            // The row was READ BEFORE the command went out, so it cannot say
            // whether the controller took it — and `hasTakenSomeHaulConfig`
            // accepts ANY ferry/shuttle delivering home, so the PRE-dispatch
            // config is exactly what it would mistake for evidence. Steady
            // state, not an edge case: a repoint commands a controller that is
            // already hauling, and device rows refresh about five minutes apart
            // while this loop runs every 5s.
            //
            // The deadline check comes FIRST, ahead of the throttled read: a row
            // that can never be refreshed (offline, rate limited, a controller
            // the server 404s) never satisfies this guard, and a failed read
            // never advances `controller.updatedAt`, so a staleness-first
            // ordering polls `.high` reads forever instead of ever stalling.
            if world.now.timeIntervalSince(directive.stepStartedAt) >= Self.confirmDeadline {
                return .refreshDevices(deviceCodes: [controllerCode], thenStall: .commandRejected)
            }
            // Buy one authoritative read instead, throttled by
            // `confirmReadInterval` so this costs a read per repoint rather than
            // one per tick. `thenStall: nil` keeps it bounded: `reAsk` collapses
            // a repeat request into `.wait`, so a read that fails or brings back
            // nothing new is not fatal.
            if world.now.timeIntervalSince(controller.updatedAt) > Self.confirmReadInterval {
                return .refreshDevices(deviceCodes: [controllerCode], thenStall: nil)
            }
            return .wait
        }
        if Self.hasTakenSomeHaulConfig(controller) {
            // Settled on SOME config this run could have issued — not
            // necessarily the pile most recently dispatched, since the census
            // can move during the wait. `assigning` owns repointing.
            return .advanceStep(nextStep: Step.assigning)
        }
        if world.now.timeIntervalSince(directive.stepStartedAt) < Self.confirmDeadline {
            return .wait
        }
        // Past the deadline, spend one authoritative read before giving up: the
        // command may have landed while the local row sat stale. If the re-ask
        // still cannot see it, the engine stalls with the carried reason.
        return .refreshDevices(deviceCodes: [controllerCode], thenStall: .commandRejected)
    }

    /// Hold `directive` for `pollInterval` against `world`'s clock, then survey
    /// again. `.wait` is the only action that writes nothing, so this is the one
    /// place an interval can be measured without the step resetting the clock it
    /// is reading.
    private func haul(_ directive: Directive, _ world: WorldSnapshot) -> MissionAction {
        if world.now.timeIntervalSince(directive.stepStartedAt) < Self.pollInterval {
            return .wait
        }
        return .advanceStep(nextStep: Step.surveying)
    }
}
