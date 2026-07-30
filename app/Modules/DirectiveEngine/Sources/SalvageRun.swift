//
//  SalvageRun.swift
//  Replicould — DirectiveEngine
//
//  Fly a vessel from salvage system to salvage system, mining each one down and
//  planting FTL relays as it goes so the mesh's frontier expands under its own
//  steam (design spec §5/§7). Continuous by design — there is no finish line —
//  and never coordinates with the Haul Run that drains the piles it leaves
//  behind (§6): the split is uncoupled on purpose.
//
//  **Staging is the player's job**, same contract as `SurveyRun`. The run uses
//  an AMI mining controller that is ALREADY stowed aboard the vessel, mining
//  drones that controller has ALREADY adopted, and FTL relays ALREADY stowed
//  aboard. It never stows and never adopts. Missing any of it is a stall with a
//  reason naming it.
//
//  Pure by contract: no I/O, no clock reads (time comes from `world.now`), no
//  randomness. Every effect is the returned `MissionAction`.
//

import Foundation
import GameModels
import GameServices
import OSLog
import UniverseModels
import Utils

private let logger = Logger(subsystem: "name.pennig.replicould", category: "DirectiveEngine")

public struct SalvageRun: MissionStepMachine {
    public let kind: DirectiveKind = .salvageRun
    public var firstStep: String { Step.preflight }

    public init() {}

    /// This mission's step vocabulary. Plain strings because `Directive.step` is
    /// deliberately untyped — each kind owns its own vocabulary. Only
    /// `preflight` and `travelling` are driven by this task; the remaining
    /// steps are named here so the vocabulary is whole from the start, and any
    /// row that reaches one before its handler ships simply waits (see
    /// `nextAction`'s `default` arm) rather than dispatching blindly.
    public enum Step {
        public static let preflight = "preflight"
        public static let travelling = "travelling"
        public static let emplacing = "emplacing"
        public static let activating = "activating"
        /// Polls for the dispatched `activate` to take, backstopped by
        /// `activationDeadline`. Split from `activating` (which only dispatches)
        /// because a step that dispatches on every re-entry re-stamps its own
        /// `stepStartedAt` (`DirectiveExecutor.apply` does this unconditionally
        /// on every accepted dispatch) — the deadline could never accumulate
        /// from a step that kept resetting its own clock. See `confirmRelay`.
        public static let confirmingRelay = "confirmingRelay"
        public static let configuring = "configuring"
        public static let launching = "launching"
        public static let awaiting = "awaiting"
        public static let verifying = "verifying"
        public static let restocking = "restocking"
    }

    /// The fleet tag a row falls back to when it carries none of its own — a
    /// row written before `fleetTag` existed, or created some other way, still
    /// resolves its fleet.
    public static let defaultFleetTag = "auto:salvage"

    /// The system this run's roam falls back to when a row carries no
    /// `roamCentre` of its own.
    ///
    /// Every salvage row the launcher creates stamps a `roamCentre`, so this
    /// should never actually be exercised — but `.extendQueue` needs SOME
    /// designation to anchor the census read, and a Salvage Run is always
    /// continuous (spec §5), so neither crashing nor quietly finishing the run
    /// is acceptable for a row that is merely missing an optional field.
    /// AINALRAM is where every mined pile is headed anyway (§5 step 8, §8), so
    /// "start looking from home" is a defensible anchor rather than an
    /// arbitrary one.
    public static let baseSystem = "AINALRAM"

    /// How old a row backing a POSITIVE staging finding may be and still be
    /// believed without an authoritative re-read. Same value and reasoning as
    /// `SurveyRun.stagingFreshness` — the doubt applies here unchanged.
    ///
    /// Staging is judged from `stowedInDeviceCode` columns, and mining drones
    /// are AMI-adopted the same way survey drones are — event-silent — so a
    /// drone abandoned in another system keeps claiming it is aboard until
    /// something reads it. The negative-finding guards above only cover "we see
    /// nothing, but have we been allowed to look?"; this is the same doubt
    /// applied to a positive, which is the direction that actually loses a
    /// fleet (six drones, POLARISUM, 2026-07-26). Costs at most one read round
    /// per target.
    public static let stagingFreshness: TimeInterval = 5 * 60

    /// How long to let an `activate` take before surfacing
    /// `relayActivationFailed`. Generous — the relay's own confirm-read is what
    /// flips its status, and that read is subject to the poll budget.
    public static let activationDeadline: TimeInterval = 10 * 60

    /// The salvage configuration this mission insists on: deplete the named
    /// body, then recall the drones so the vessel can move on. `recall` is
    /// load-bearing — since v2.3.3 the server holds `directive.completed` until
    /// the recall lands, which is what lets `verifying` be one confirming read
    /// rather than a timed wait.
    public static func salvageConfig(body: String) -> [String: JSONValue] {
        ["location": .string(body), "recall": .bool(true)]
    }

    public func nextAction(directive: Directive, world: WorldSnapshot) -> MissionAction {
        guard let vessel = world.device(directive.deviceCode) else {
            return .stall(.unreachableDevice)
        }
        switch directive.step {
        case Step.preflight: return preflight(directive, vessel, world)
        case Step.travelling: return travel(directive, vessel, world)
        case Step.emplacing: return emplace(directive, vessel, world)
        case Step.activating: return activate(vessel, world)
        case Step.confirmingRelay: return confirmRelay(directive, vessel, world)
        case Step.configuring: return configure(directive, vessel, world)
        case Step.launching: return launch(directive, vessel, world)
        case Step.awaiting: return awaitCompletion(directive, world)
        case Step.verifying: return verify(directive, vessel, world)
        case Step.restocking: return restock(directive, vessel, world)
        default:
            // An unrecognised (or not-yet-handled) step must never dispatch. Waiting
            // is inert and recoverable — the user can cancel, or the step ships.
            logger.notice("salvage run \(directive.id, privacy: .public): unknown step \(directive.step, privacy: .public) — waiting")
            return .wait
        }
    }

    // MARK: - Fleet queries

    /// The AMI mining controller stowed aboard this vessel, if any. Forwards to
    /// the shared `AMIFleet` query — see there for the full "why" behind the
    /// stowed-not-co-located and capability-not-type rules.
    public static func controller(aboard vessel: Device, in world: WorldSnapshot) -> Device? {
        AMIFleet.stowed(aboard: vessel, in: world, offering: "gather_salvage")
    }

    /// The controller's adopted mining drones that are also aboard the vessel.
    /// Forwards to `AMIFleet` — see there for why adoption is read from both
    /// ends of the controller/drone link.
    public static func adoptedDrones(
        of controller: Device, aboard vessel: Device, in world: WorldSnapshot
    ) -> [Device] {
        AMIFleet.adoptedDrones(of: controller, aboard: vessel, in: world)
    }

    /// An FTL relay stowed aboard the vessel, if any. Not shared with
    /// `AMIFleet`: a relay isn't adopted by a controller, so this is a plain
    /// stow lookup rather than the two-ended adoption read.
    public static func relay(aboard vessel: Device, in world: WorldSnapshot) -> Device? {
        world.devices.values
            .filter { $0.stowedInDeviceCode == vessel.deviceCode }
            .filter { $0.features.contains("relay") }
            .min { $0.deviceCode < $1.deviceCode }
    }

    /// A relay sitting at the vessel's own location — the one just deployed.
    ///
    /// `deploy` clears the device's `stowedInDeviceCode` the moment it lands,
    /// so `relay(aboard:in:)` stops finding it at exactly the point `activate`
    /// needs to. This is the co-location read that replaces it: resolve the
    /// relay by WHERE IT NOW IS, never by what used to be stowed.
    static func deployedRelay(near vessel: Device, in world: WorldSnapshot) -> Device? {
        guard let location = vessel.location else { return nil }
        return world.devices.values
            .filter { $0.features.contains("relay") && $0.location == location }
            .min { $0.deviceCode < $1.deviceCode }
    }

    /// The Lagrange point to emplace at: the first L4/L5 the system reports,
    /// ordered by designation so the choice is reproducible across
    /// evaluations. Relays require a gravitationally stable point and will not
    /// work anywhere else, so a system with none is not emplaceable.
    ///
    /// Lagrange points hang off each PLANET (`Planet.lagrange: [SpecialSite]`),
    /// not off the system — there is no `StarSystem.lagrangePoints`.
    static func lagrangePoint(in system: StarSystem?) -> String? {
        system?.planets.flatMap(\.lagrange).map(\.designation).sorted().first
    }

    /// Whether any row backing a staging finding is too old to act on. Same
    /// shape as `SurveyRun.stagingIsStale` — one stale row is enough, because
    /// "everything needed is aboard" is a conjunction, so its weakest member
    /// decides how much it is worth.
    static func stagingIsStale(_ devices: [Device], _ world: WorldSnapshot) -> Bool {
        devices.contains { world.now.timeIntervalSince($0.updatedAt) > stagingFreshness }
    }

    /// The star system a device is currently in, or nil in transit / stowed.
    static func system(of device: Device) -> String? {
        device.location.map { SiteAssay.system(of: $0) }
    }

    // MARK: - Steps

    private func preflight(_ directive: Directive, _ vessel: Device, _ world: WorldSnapshot) -> MissionAction {
        // A Salvage Run has no finish line (spec §5): an exhausted queue is
        // never `.done`, only ever the cue to plan the next target. Checked
        // BEFORE the staging guards below, so a fresh run with an empty queue
        // extends it rather than stalling over staging it hasn't gotten to yet.
        guard let target = directive.currentTarget else {
            let centre = directive.roamCentre ?? Self.system(of: vessel) ?? Self.baseSystem
            return .extendQueue(centre: centre)
        }
        let tag = Self.fleetTag(directive)
        // Both staging checks are NEGATIVE findings over local rows, exactly
        // like `SurveyRun`'s: silence locally means either nothing is aboard or
        // nobody has been allowed to look lately, and only the first is worth
        // stopping for. `.refreshFleet` demands one authoritative tag read
        // before either counts, and the engine re-asks once against fresh rows.
        guard let controller = Self.controller(aboard: vessel, in: world) else {
            return .refreshFleet(tag: tag, thenStall: .noMiningControllerAboard)
        }
        let drones = Self.adoptedDrones(of: controller, aboard: vessel, in: world)
        guard !drones.isEmpty else {
            return .refreshFleet(tag: tag, thenStall: .noMiningDroneAboard)
        }
        // The relay is an ENABLER, not an optional extra: without one aboard, a
        // vessel reaching an unmeshed target would have to park there for the
        // whole haul to stay commandable, which is exactly what the relay
        // frontier exists to avoid (spec §5 step 8, §7).
        let meshed = SalvageTargetPlanner.meshSystems(in: Array(world.devices.values)).contains(target)
        let relay = Self.relay(aboard: vessel, in: world)
        if !meshed, relay == nil {
            return .advanceStep(nextStep: Step.restocking)
        }
        // The staging answer is positive — but it rests on rows that only a
        // read can correct, and believing a stale one is how six drones were
        // left in POLARISUM (see `SurveyRun.preflight`, the same reasoning
        // unchanged). Deliberately AFTER the restocking check above: a target
        // the vessel isn't actually departing for this tick (it's detouring to
        // base instead) must not pay for a freshness read it doesn't need.
        // `.refreshFleet` rather than `.refreshDevices` — this run resolves its
        // whole fleet by tag (spec §4.2), so a tag read covers vessel,
        // controller, and every drone in the ONE request that can also see
        // stowed devices, rather than naming each row individually.
        //
        // The relay row is folded into this set too (fixed after review): the
        // `emplace` step re-derives `relay(aboard:in:)` on every entry, but that
        // only re-queries these same cached local rows — it forces no live read
        // and so cannot catch a claim that was ALREADY stale before departure.
        // A relay that was stale-positive here is identically stale-positive at
        // the Lagrange point, which would have let `emplace` dispatch `deploy`
        // at a device that was never actually there. This is the one place that
        // can actually correct it, before the vessel commits to the trip.
        var stagingRows = [vessel, controller] + drones
        if let relay { stagingRows.append(relay) }
        if Self.stagingIsStale(stagingRows, world) {
            return .refreshFleet(tag: tag, thenStall: .unreachableDevice)
        }
        return .assignController(deviceCode: controller.deviceCode, nextStep: Step.travelling)
    }

    private func travel(_ directive: Directive, _ vessel: Device, _ world: WorldSnapshot) -> MissionAction {
        guard let target = directive.currentTarget else {
            return .advanceStep(nextStep: Step.preflight)
        }
        if Self.system(of: vessel) == target {
            // Arrived. Skip straight past the emplace step when a relay is
            // already relaying here — there is nothing to plant.
            let meshed = SalvageTargetPlanner.meshSystems(in: Array(world.devices.values)).contains(target)
            return .advanceStep(nextStep: meshed ? Step.configuring : Step.emplacing)
        }
        // An open op means the trip is under way. Expected, not a stall — and
        // the guard that stops a second travel landing on top of the first.
        if world.openOperation(for: vessel.deviceCode) != nil { return .wait }
        return .dispatch(
            kind: .travel, deviceCode: vessel.deviceCode,
            params: CommandParams(destination: target), nextStep: Step.travelling
        )
    }

    /// Fly to the target's Lagrange point, then deploy the stowed relay once
    /// there. `deploy` does not activate the relay — that is `activate`'s job,
    /// a separate command verified against the live API — so this step's
    /// terminal action always hands off to `Step.activating` rather than
    /// declaring the mesh work done.
    ///
    /// Two DIFFERENT causes can leave `Self.lagrangePoint(in:)` unable to name
    /// a point, and conflating them was an Important bug caught in review: the
    /// target's `SystemDetail` blob simply not being cached YET (the row
    /// hasn't landed, or failed to decode) is NOT evidence the system
    /// genuinely lacks a Lagrange point. `world.system(target)` being nil
    /// nil-chained straight through `lagrangePoint(in:)` into the same
    /// "no point" branch as a cached system that really has none — and
    /// because nothing routes `configuring` back to `emplacing`, that silently
    /// and permanently forfeited relay emplacement for the target, with no log
    /// entry and no operator visibility. `travel()` routes arrival here
    /// regardless of whether the blob is cached, so the race lands right after
    /// arrival, before the passive rescan.
    ///
    /// So the two causes are split below: an uncached blob is a bounded
    /// `.wait` — the same `systemResolutionDeadline` backstop `configure` uses
    /// for its own `.unresolved` case, surfacing `.salvageSystemUnresolved` if
    /// the passive rescan never lands. A CACHED system that genuinely has no
    /// L4/L5 anywhere is the degraded-but-fine outcome: the salvage under a
    /// system with no stable point is still worth taking, the run simply
    /// cannot extend the mesh frontier through it — so this skips straight to
    /// mining unmeshed rather than stalling on a target that will never
    /// satisfy the guard.
    ///
    /// The relay-aboard check is re-run on every entry to this step rather than
    /// trusted from whatever got the vessel here. This is a backstop for the
    /// relay being genuinely absent (never staged, released, decommissioned) —
    /// NOT a substitute for staleness protection: `relay(aboard:in:)` only
    /// re-queries the same cached local rows `preflight` already read, so it
    /// forces no live read and cannot correct a claim that was already stale
    /// before departure. That protection lives in `preflight`, which folds the
    /// relay device into its staging-freshness recheck (fixed after review) —
    /// a departure only reaches here once that read has already vetted the
    /// relay as fresh. When THIS guard fires (the never-was-aboard case), it
    /// reroutes to `Step.restocking` rather than dispatching `deploy` at a
    /// device that was never actually there.
    private func emplace(_ directive: Directive, _ vessel: Device, _ world: WorldSnapshot) -> MissionAction {
        guard let target = directive.currentTarget else {
            return .advanceStep(nextStep: Step.configuring)
        }
        guard let system = world.system(target) else {
            // Blob not cached yet. `.wait` is the only `MissionAction` that
            // never re-stamps `stepStartedAt` (see the same-step-dispatch
            // memory note), so it's the only way this bound can genuinely
            // accumulate — same shape as `configure`'s `.unresolved` handling.
            if world.now.timeIntervalSince(directive.stepStartedAt) > Self.systemResolutionDeadline {
                return .stall(.salvageSystemUnresolved)
            }
            return .wait
        }
        guard let point = Self.lagrangePoint(in: system) else {
            return .advanceStep(nextStep: Step.configuring)
        }
        guard let relay = Self.relay(aboard: vessel, in: world) else {
            return .advanceStep(nextStep: Step.restocking)
        }
        if vessel.location != point {
            if world.openOperation(for: vessel.deviceCode) != nil { return .wait }
            return .dispatch(
                kind: .travel, deviceCode: vessel.deviceCode,
                params: CommandParams(destination: point), nextStep: Step.emplacing
            )
        }
        // No `openOperation` guard here: `deploy` is `OperationKind.simple`,
        // which the command layer classifies `.immediate` and tracks with NO
        // `Operation` row at all (`CommandClient`'s completion classification;
        // `deadlineCommands` doesn't list `deploy`), so the lookup would always
        // be nil — a guard that can never fire is not a guard, it's noise.
        return .dispatch(
            kind: OperationKind.simple("deploy"), deviceCode: relay.deviceCode,
            params: CommandParams(), nextStep: Step.activating
        )
    }

    /// Issue `activate` once. Dispatch-only, deliberately — mirrors
    /// `SurveyRun.launch`, which likewise fires its command unconditionally
    /// and leaves all polling to the next step. See `confirmRelay` for why
    /// this step must never dispatch a second time on re-entry.
    private func activate(_ vessel: Device, _ world: WorldSnapshot) -> MissionAction {
        // Resolve the relay by where it now IS, not by what is stowed: `deploy`
        // cleared its `stowedInDeviceCode`, so the aboard-query no longer finds
        // it. This is the easy bug here.
        guard let relay = Self.deployedRelay(near: vessel, in: world) else {
            return .stall(.relayActivationFailed)
        }
        return .dispatch(
            kind: OperationKind.simple("activate"), deviceCode: relay.deviceCode,
            params: CommandParams(), nextStep: Step.confirmingRelay
        )
    }

    /// Poll for the dispatched `activate` to take, then hand off to mining once
    /// the relay reports `relaying`. Backstopped by `activationDeadline`: a
    /// relay that deployed but never came up is a dead run, since the whole
    /// point of the trip was the mesh membership `relaying` alone confers.
    ///
    /// Deliberately never dispatches — this is the fix for a real bug caught in
    /// review. `activate` is `OperationKind.simple`, tracked with NO `Operation`
    /// row (same reasoning as `emplace`'s dropped guard above), so an
    /// `openOperation` check here could never be non-nil and could not have
    /// stopped a same-step redispatch. Worse: `DirectiveExecutor.apply`'s
    /// `.dispatch` case unconditionally re-stamps `stepStartedAt` to `date.now`
    /// on every accepted dispatch, with no same-step exception — so the
    /// original single-step design (`activate` dispatching back into itself on
    /// every tick the relay wasn't yet `relaying`) reset the very clock
    /// `activationDeadline` measures from on every evaluation, and the backstop
    /// could never fire: a relay that never came up would have had `activate`
    /// issued at the live API forever. Splitting the dispatch (`activate`,
    /// above) from this poll — mirroring `SurveyRun.launching`/`.awaiting` — is
    /// the fix: `stepStartedAt` is stamped exactly once, on entry to THIS step,
    /// and accumulates honestly from there.
    private func confirmRelay(_ directive: Directive, _ vessel: Device, _ world: WorldSnapshot) -> MissionAction {
        guard let relay = Self.deployedRelay(near: vessel, in: world) else {
            return .stall(.relayActivationFailed)
        }
        if relay.status == "relaying" { return .advanceStep(nextStep: Step.configuring) }
        if world.now.timeIntervalSince(directive.stepStartedAt) > Self.activationDeadline {
            return .stall(.relayActivationFailed)
        }
        return .wait
    }

    // MARK: - Mining loop

    /// The controller this run claimed, re-resolved from the fleet on every
    /// evaluation — the row is the checkpoint, and a controller since released
    /// or decommissioned must surface rather than be dispatched at. Mirrors
    /// `SurveyRun.claimedController`.
    private func claimedController(_ directive: Directive, _ vessel: Device, _ world: WorldSnapshot) -> Device? {
        guard let code = directive.controllerCode else {
            return Self.controller(aboard: vessel, in: world)
        }
        return world.device(code)
    }

    /// What resolving the next salvage body found. Distinguishes "nothing left
    /// to mine" from "don't know yet" — the two collapse to the same `nil` if
    /// left unstructured, and `configure` must never treat the second as the
    /// first. `WorldSnapshot.read` already documents this exact convention for
    /// a `StarSystem` blob that fails to decode ("treated as absent... which
    /// is the safe direction to be wrong in") — this is that same rule applied
    /// to the caller that acts on the blob.
    enum NextBodyResolution: Equatable {
        /// A live body to configure toward.
        case body(String)
        /// The target system is cached and holds no live salvage body —
        /// genuinely finished, whether drained or never worth mining to begin
        /// with. Also the outcome when the queue itself is exhausted (no
        /// `currentTarget`): `.advanceTarget` handles that safely too, since it
        /// resets to `firstStep` (`preflight`), whose own queue-exhausted check
        /// runs on the very next evaluation.
        case finished
        /// The target system's catalogue blob (`SystemDetail`) isn't cached
        /// yet — the row hasn't landed, or failed to decode. NOT evidence the
        /// system is done; the caller must wait for it rather than advance.
        case unresolved
    }

    /// The next salvage body to work in the current target system: the richest
    /// one still holding salvage, by assayed units then designation.
    ///
    /// Re-derived from the catalogue on every evaluation rather than stored as a
    /// cursor. A cursor would drift the moment anything else depleted a site,
    /// and a depleted body simply stops being offered.
    static func nextBody(in directive: Directive, world: WorldSnapshot) -> NextBodyResolution {
        guard let target = directive.currentTarget else { return .finished }
        guard let system = world.system(target) else { return .unresolved }
        // `salvageBodies(totals:)` ALREADY excludes depleted sites
        // (`where !site.depleted`), so no extra filter is needed — a drained body
        // simply stops appearing, which is what makes an empty result mean
        // "system finished" (now that "system absent" is its own case above).
        // Pass the assay totals: without them `unitsRemaining` and
        // `discoveredTotal` are both nil for every body and the ranking below
        // collapses to the designation tiebreak.
        guard let body = system.salvageBodies(totals: world.siteAssays)
            .max(by: { lhs, rhs in
                // `unitsRemaining` is nil until the body's live percentages have
                // been fetched; `discoveredTotal` carries the historical figure
                // for exactly that case, and is the COMMON one. Falling back to 0
                // instead would rank every unhydrated body last and send the run
                // to the least valuable target it knows about.
                let l = lhs.unitsRemaining ?? lhs.discoveredTotal ?? 0
                let r = rhs.unitsRemaining ?? rhs.discoveredTotal ?? 0
                // `max(by:)` wants "lhs strictly precedes rhs"; ties break on
                // designation so the pick is reproducible across evaluations.
                return l == r ? lhs.designation > rhs.designation : l < r
            })?.designation
        else { return .finished }
        return .body(body)
    }

    /// Whether an in-force config already equals `salvageConfig(body:)` on the
    /// two fields that matter. Compared field by field rather than
    /// whole-object, same reasoning as `SurveyRun.configMatches` — the server
    /// may echo extra keys, and an inequality there is not a reason to
    /// re-issue. A leftover `location` from manual use would otherwise
    /// silently work the wrong body, so re-issuing is the default and only an
    /// exact match on both fields skips it.
    static func configMatches(_ config: JSONValue?, body: String) -> Bool {
        guard let config else { return false }
        return config["location"]?.stringValue == body && config["recall"]?.boolValue == true
    }

    /// How long `configuring` may wait on the target system's catalogue blob
    /// before surfacing `salvageSystemUnresolved`. The vessel has already
    /// arrived by the time this step runs, so the arrival itself already
    /// triggers `LocationsIngestion`'s passive rescan independent of this
    /// mission — this is a backstop against that never landing (a dropped
    /// event, a persistent decode failure), not the expected path. Same scale
    /// as `activationDeadline` / `backstopInterval`.
    public static let systemResolutionDeadline: TimeInterval = 10 * 60

    private func configure(_ directive: Directive, _ vessel: Device, _ world: WorldSnapshot) -> MissionAction {
        switch Self.nextBody(in: directive, world: world) {
        case .finished:
            // Nothing live left in this system — drained, or never held
            // anything worth mining, or the queue itself is exhausted.
            // Checked FIRST, mirroring `preflight`'s queue-before-staging
            // order: a target with nothing left must advance regardless of
            // whether the fleet happens to still be staged for a step it will
            // never take.
            //
            // This is also the seam Task 8's `verifying` step will hand back
            // into: once it exists, a body that just finished routes back to
            // `configuring`, and this same check is what recognises "nothing
            // left" on that return trip — no separate finished-system check
            // needs to live in `verifying` itself.
            return .advanceTarget

        case .unresolved:
            // The catalogue blob hasn't landed. This must NEVER read as
            // "finished" — see `NextBodyResolution`'s doc and
            // `WorldSnapshot.read`'s matching convention for a blob that
            // fails to decode. A `.refreshSystem` request is deliberately NOT
            // issued here: `DirectiveExecutor.apply`'s `.refreshSystem` case
            // always calls `move()`, which re-stamps `stepStartedAt`
            // unconditionally on every pass — so re-requesting it on every
            // re-entry to this same step would reset the very clock the
            // backstop below needs to measure from, the same class of bug as
            // a same-step `.dispatch` (see the
            // same-step-dispatch-needs-tracked-op memory note; `.refreshSystem`
            // is not a `.dispatch`, but it shares the "any transition re-stamps
            // the clock" hazard). `.wait` is the one action
            // `DirectiveExecutor.apply` leaves entirely inert — no commit, no
            // state change — so it is the only way this bound can genuinely
            // accumulate. Nothing is lost by not actively requesting a
            // refresh: the vessel's arrival already triggers the passive
            // rescan on its own.
            if world.now.timeIntervalSince(directive.stepStartedAt) > Self.systemResolutionDeadline {
                return .stall(.salvageSystemUnresolved)
            }
            return .wait

        case let .body(body):
            guard let controller = claimedController(directive, vessel, world) else {
                return .stall(.noMiningControllerAboard)
            }
            if controller.currentDirective == "gather_salvage",
               Self.configMatches(controller.currentDirectiveConfig, body: body) {
                return .advanceStep(nextStep: Step.launching)
            }
            return .dispatch(
                kind: .setDirective, deviceCode: controller.deviceCode,
                params: CommandParams(directive: "gather_salvage", configuration: Self.salvageConfig(body: body)),
                nextStep: Step.launching
            )
        }
    }

    /// Issue `launch` once. Dispatch-only, deliberately — mirrors
    /// `SurveyRun.launch` and this run's own `activate`: `launch` is
    /// `OperationKind.simple`, tracked with NO `Operation` row, so a same-step
    /// redispatch guard here could never fire and would reset
    /// `stepStartedAt` on every tick (see the same-step-dispatch memory note).
    /// All polling lives in `awaitCompletion`, entered fresh via `nextStep`.
    private func launch(_ directive: Directive, _ vessel: Device, _ world: WorldSnapshot) -> MissionAction {
        guard let controller = claimedController(directive, vessel, world) else {
            return .stall(.noMiningControllerAboard)
        }
        return .dispatch(
            kind: OperationKind.simple("launch"), deviceCode: controller.deviceCode,
            params: CommandParams(), nextStep: Step.awaiting
        )
    }

    /// How long to wait on the `directive.completed` fast path before moving on
    /// to verify anyway. Same value and reasoning as `SurveyRun.backstopInterval`
    /// — a dropped SSE frame must not strand a run forever.
    public static let backstopInterval: TimeInterval = 10 * 60

    /// Tolerance when comparing a completion's time against the step's start.
    /// Same value and reasoning as `SurveyRun.eventTimeSkewTolerance`.
    static let eventTimeSkewTolerance: TimeInterval = 5

    /// Whether a completion for THIS step has landed in the timeline.
    /// Issue-time relative, not wall-clock — same shape as
    /// `SurveyRun.completionSeen`, so a completion delivered by catch-up after
    /// the app was closed still counts while a replay does not.
    public static func completionSeen(_ directive: Directive, _ world: WorldSnapshot) -> Bool {
        saw(.directiveCompleted, directive, world)
    }

    /// Whether a launch reporting zero deployed devices landed in THIS step. A
    /// launch that deployed nothing cannot produce the completion `awaiting` is
    /// waiting for, so this turns a permanent wait into a named stall. Same
    /// shape as `SurveyRun.emptyLaunchSeen`.
    public static func emptyLaunchSeen(_ directive: Directive, _ world: WorldSnapshot) -> Bool {
        saw(.launchDeployedNothing, directive, world)
    }

    /// Whether an entry of `kind` belongs to the directive's current step.
    private static func saw(
        _ kind: DirectiveLogKind, _ directive: Directive, _ world: WorldSnapshot
    ) -> Bool {
        world.log.contains { entry in
            entry.kind == kind
                && entry.occurredAt >= directive.stepStartedAt
                    .addingTimeInterval(-eventTimeSkewTolerance)
        }
    }

    /// The riskiest wait in the design, same as `SurveyRun.awaitCompletion` —
    /// the controller drives its drones server-side, so there is no operation
    /// the app created to key off. Unlike the survey (which needs a system
    /// re-read to confirm scan counts before trusting completion), a body's
    /// depletion is confirmed by Task 8's `verifying` step, so a completion
    /// here hands off directly rather than issuing its own refresh.
    private func awaitCompletion(_ directive: Directive, _ world: WorldSnapshot) -> MissionAction {
        if Self.completionSeen(directive, world) {
            return .advanceStep(nextStep: Step.verifying)
        }
        // The controller told us this launch deployed nothing. No drones are
        // out, so no completion is coming and the backstop would poll forever
        // until someone noticed. Surface it now.
        if Self.emptyLaunchSeen(directive, world) { return .stall(.launchDeployedNothing) }
        if world.now.timeIntervalSince(directive.stepStartedAt) > Self.backstopInterval {
            return .advanceStep(nextStep: Step.verifying)
        }
        return .wait
    }

    // MARK: - Verify & restock

    /// The fleet tag a directive resolves against, falling back to
    /// `defaultFleetTag` for a row that carries none of its own. Shared by
    /// every step that needs to name the tag for a `.refreshFleet` — kept in
    /// one place rather than each step repeating `directive.fleetTag ??
    /// Self.defaultFleetTag`.
    static func fleetTag(_ directive: Directive) -> String {
        directive.fleetTag ?? Self.defaultFleetTag
    }

    /// Confirm the recall actually landed before doing anything else.
    ///
    /// This step exists because a Survey Run once lost its entire drone
    /// complement: `directive.completed` meant the survey had finished, not
    /// the recall, and the run read completion as clearance to depart,
    /// stranding drones in the system it just left.
    ///
    /// But the server changed. Since v2.3.3, a directive configured with
    /// `recall` (see `salvageConfig(body:)`) holds `directive.completed` until
    /// the drones have finished travelling — so by the time this step runs
    /// they SHOULD already be aboard, and a stranded-looking drone is far more
    /// likely a stale local row than a real loss. That is why this is ONE
    /// confirming read rather than `SurveyRun.recover`'s elaborate ETA-driven
    /// polling: that machinery answers a doubt this run's completion
    /// semantics have already resolved. If the FRESH rows still say a drone is
    /// out, then it is a real loss and the run stalls rather than departing
    /// without it.
    ///
    /// Once recovery is confirmed, `nextBody` decides where to go next — and
    /// its `.unresolved` case must be handled exactly as `configure` and
    /// `emplace` handle it (a bounded wait, never silently read as
    /// `.finished`): the same Critical class of bug fixed one step over.
    private func verify(_ directive: Directive, _ vessel: Device, _ world: WorldSnapshot) -> MissionAction {
        guard let controller = claimedController(directive, vessel, world) else {
            // Nothing to verify against, and a vanished controller is
            // preflight's diagnosis to make — holding the run here would
            // stall on a reason that doesn't name the real problem. Mirrors
            // `SurveyRun.recover`'s identical handling.
            return .advanceTarget
        }
        // The WIDE `AMIFleet` query, not the aboard-vessel one: recovery is
        // judged over every drone this controller has ever adopted, wherever
        // it currently is — "some drones are home" is precisely the state
        // that loses the others (see `AMIFleet.adoptedDrones(of:in:)`'s own
        // doc).
        let stranded = AMIFleet.adoptedDrones(of: controller, in: world)
            .filter { $0.stowedInDeviceCode != vessel.deviceCode }
        if !stranded.isEmpty {
            return .refreshFleet(tag: Self.fleetTag(directive), thenStall: .dronesNotRecovered)
        }
        switch Self.nextBody(in: directive, world: world) {
        case .finished:
            // Recovered, and nothing live left in this system: this target is
            // done.
            return .advanceTarget
        case .body:
            // Recovered, and more bodies here — work the next one.
            return .advanceStep(nextStep: Step.configuring)
        case .unresolved:
            // The catalogue blob went missing again between `configure` and
            // here (dropped event, decode failure) — must NEVER read as
            // `.finished`. See `emplace`'s matching fix and doc for the full
            // reasoning; same backstop, same deadline.
            if world.now.timeIntervalSince(directive.stepStartedAt) > Self.systemResolutionDeadline {
                return .stall(.salvageSystemUnresolved)
            }
            return .wait
        }
    }

    /// The base a run restocks at. A constant for now — the delivery location
    /// is spec §1's fixed destination, and making it configurable before
    /// there is a second base would be a setting with one possible value.
    public static let baseDesignation = "AINALRAM-BELT-1"

    /// Fly the vessel home once it is out of relays, then stall for the
    /// operator once it arrives. The engine never stows and never adopts —
    /// staging is the player's job, the same contract as every other step in
    /// this run — so this parks and asks rather than loading relays itself.
    /// A relay found aboard short-circuits the detour immediately, whether
    /// the vessel has reached base yet or not, so a player who stages one
    /// mid-flight doesn't have to wait for the arrival that would otherwise
    /// be pointless.
    private func restock(_ directive: Directive, _ vessel: Device, _ world: WorldSnapshot) -> MissionAction {
        if Self.relay(aboard: vessel, in: world) != nil {
            return .advanceStep(nextStep: Step.preflight)
        }
        if vessel.location == Self.baseDesignation {
            return .stall(.awaitingRelayRestock)
        }
        // `.travel` is a TRACKED op kind (creates an `Operation` row), so this
        // guard actually fires — unlike the `.simple` verbs elsewhere in this
        // file — and this same-step dispatch is the safe shape the
        // same-step-dispatch-needs-tracked-op memory note describes.
        if world.openOperation(for: vessel.deviceCode) != nil { return .wait }
        return .dispatch(
            kind: .travel, deviceCode: vessel.deviceCode,
            params: CommandParams(destination: Self.baseDesignation), nextStep: Step.restocking
        )
    }
}
