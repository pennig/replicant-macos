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
        /// Polls until the controller reports the config actually in force.
        ///
        /// Split from `assigning` — which only dispatches — because
        /// `set_directive` classifies as `.immediate` and creates NO tracked
        /// `Operation`. A step that dispatched it and named itself as `nextStep`
        /// would find `world.openOperation` structurally nil every time, re-issue
        /// on every 5s tick forever, and re-stamp its own `stepStartedAt` on each
        /// accepted dispatch so no deadline could ever fire. See the
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

    public func nextAction(directive: Directive, world: WorldSnapshot) -> MissionAction {
        switch directive.step {
        case Step.preflight: return preflight(directive, world)
        case Step.surveying: return survey(directive, world)
        case Step.assigning: return assign(directive, world)
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
    static func isInForce(_ assignment: HaulTargetPlanner.Assignment, in world: WorldSnapshot) -> Bool {
        guard let controller = world.device(assignment.controllerCode),
              controller.currentDirective == assignment.directive,
              let config = controller.currentDirectiveConfig
        else { return false }
        return config["collect"]?.stringValue == assignment.location
            && config["deliver"]?.stringValue == deliveryLocation
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

    /// Point ONE controller at its pile, or move on when every controller already
    /// matches. One dispatch per evaluation keeps the one-action-per-tick
    /// contract; N controllers settle over N ticks.
    private func assign(_ directive: Directive, _ world: WorldSnapshot) -> MissionAction {
        let tag = Self.fleetTag(of: directive)
        guard !Self.controllers(in: world, tag: tag).isEmpty else {
            return .stall(.noHaulControllerTagged)
        }
        let assignments = Self.plans(directive, world)
        guard let pending = assignments.first(where: { !Self.isInForce($0, in: world) }) else {
            // Either every controller is correctly pointed, or nothing is
            // reachable at all. Both are the same healthy answer: go and wait.
            // Never `.done` — the Salvage Run keeps making new piles under this
            // one, so an empty frontier is a lull (spec §5).
            return .advanceStep(nextStep: Step.hauling)
        }
        guard world.device(pending.controllerCode) != nil else {
            return .stall(.unreachableDevice)
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

    /// Poll until the dispatched config is in force, then go back for the next
    /// controller. Only ever waits or reads — never dispatches — which is what
    /// lets `confirmDeadline` accumulate honestly.
    private func confirm(_ directive: Directive, _ world: WorldSnapshot) -> MissionAction {
        let assignments = Self.plans(directive, world)
        guard let pending = assignments.first(where: { !Self.isInForce($0, in: world) }) else {
            return .advanceStep(nextStep: Step.assigning)
        }
        if world.now.timeIntervalSince(directive.stepStartedAt) < Self.confirmDeadline {
            return .wait
        }
        // Past the deadline, spend one authoritative read before giving up: the
        // command may well have landed while the local row sat stale. If the
        // re-ask still can't see it, the engine stalls with the carried reason.
        return .refreshDevices(deviceCodes: [pending.controllerCode], thenStall: .commandRejected)
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
