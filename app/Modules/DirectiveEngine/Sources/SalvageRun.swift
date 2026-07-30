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

    /// The salvage bodies of `system`, richest-first, ready for the (not yet
    /// implemented) `mine` step to work down one at a time.
    ///
    /// Ranked by summed `remainingPct` rather than absolute assayed units:
    /// `WorldSnapshot` caches decoded `StarSystem` blobs, not the `SiteAssay`
    /// unit totals `SalvageTargetPlanner` ranks systems by (that table isn't
    /// threaded through this snapshot). Percentage-remaining is the ordering
    /// this data can actually support; a future task should switch to exact
    /// unit totals if `mine` needs them precisely rather than approximately.
    /// A depleted site is excluded outright — there is nothing left to work.
    public static func salvageBodies(in system: String, world: WorldSnapshot) -> [String] {
        guard let star = world.system(system) else { return [] }
        let sites = star.planets.flatMap { planet in
            planet.salvage + planet.moons.flatMap(\.salvage)
        }
        return sites
            .filter { !$0.depleted }
            .sorted { lhs, rhs in
                let lhsRemaining = lhs.remainingPct.values.reduce(0, +)
                let rhsRemaining = rhs.remainingPct.values.reduce(0, +)
                if lhsRemaining != rhsRemaining { return lhsRemaining > rhsRemaining }
                return lhs.designation < rhs.designation
            }
            .map(\.designation)
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
