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
        let tag = directive.fleetTag ?? Self.defaultFleetTag
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
    /// A system with no Lagrange point at all cannot host a relay. That is a
    /// degraded outcome, not an error: the salvage under a system with no
    /// stable point is still worth taking, the run simply cannot extend the
    /// mesh frontier through it — so this skips straight to mining unmeshed
    /// rather than stalling on a target that will never satisfy the guard.
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
        guard let target = directive.currentTarget,
              let point = Self.lagrangePoint(in: world.system(target))
        else { return .advanceStep(nextStep: Step.configuring) }
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
}
