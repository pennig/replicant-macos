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
        if !meshed, Self.relay(aboard: vessel, in: world) == nil {
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
        if Self.stagingIsStale([vessel, controller] + drones, world) {
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
}
