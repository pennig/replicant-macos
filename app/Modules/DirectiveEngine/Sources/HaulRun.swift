//
//  HaulRun.swift
//  Replicould — DirectiveEngine
//
//  Keeps every `auto:haul`-tagged AMI transport controller pointed at the richest
//  reachable stockpile. Continuous — no finish line. The engine never hauls: the
//  controller's `ferry` directive moves resources server-side, so this only picks
//  targets. Repoints ONE controller per tick. Pure — every effect is the returned
//  `MissionAction`, and time comes from `world.now`.
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
        /// Issue the command `assigning` chose, against the controller it pinned.
        /// Must dispatch with `nextStep: .confirming`, never itself — `set_directive`
        /// creates no tracked `Operation`, so a self-naming step re-issues forever.
        public static let dispatching = "dispatching"
        /// Poll until the pinned controller reports, on a row read AFTER the
        /// dispatch, some config this run could have issued, then hand back to
        /// `assigning`. Waits or reads, never dispatches.
        public static let confirming = "confirming"
        /// The quiet step between census reads.
        public static let hauling = "hauling"
    }

    /// The fleet tag a row falls back to when it carries none of its own.
    public static let defaultFleetTag = "auto:haul"

    /// The sink used when no hub is recognised. A fallback, not the answer:
    /// `deliverySink(in:)` is what a run with a world in hand must ask.
    public static let deliveryLocation = "AINALRAM-BELT-1"

    /// Matched on the DIRECTIVE a device offers, not `device_type` — a
    /// differently-named controller offering `ferry` is still a haul controller.
    public static let requiredDirective = HaulTargetPlanner.ferry

    /// Between census reads. One `GET /v1/locations` per interval is the run's
    /// entire steady-state cost.
    public static let pollInterval: TimeInterval = 60

    /// How stale a fleet row may be and still be believed at preflight.
    public static let stagingFreshness: TimeInterval = 5 * 60

    /// How long to let a controller take the dispatched config before treating
    /// silence as a rejection.
    public static let confirmDeadline: TimeInterval = 5 * 60

    /// Throttles `confirming`'s authoritative read, which is only reached on a row
    /// predating the dispatch — without it, a row read moments before the command
    /// went out is re-read on the next 5s tick.
    public static let confirmReadInterval: TimeInterval = 30

    /// How many `dispatching → confirming → assigning` cycles the SAME pinned
    /// controller may spend without satisfying `isInForce` before stalling.
    public static let dispatchAttemptLimit = 3

    /// Route `directive`'s current step against `world`. An unrecognised step
    /// waits rather than dispatching — waiting is inert, guessing commands the fleet.
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

    /// Never `.exhausted` — that would finish a run which has no finish line.
    public func plan(_ context: RoamContext) -> RoamPlan { .idle }

    // MARK: - Fleet

    /// Every device in `devices` carrying `tag` and offering `ferry`, sorted by
    /// code so a controller keeps its rank across evaluations. Resolved by TAG,
    /// never location — untagging is how the operator takes a controller back.
    public static func controllers(in devices: some Sequence<Device>, tag: String) -> [Device] {
        devices
            .filter { $0.hasTag(tag) }
            .filter { $0.availableDirectives.contains(requiredDirective) }
            .sorted { $0.deviceCode < $1.deviceCode }
    }

    public static func controllers(in world: WorldSnapshot, tag: String) -> [Device] {
        controllers(in: world.devices.values, tag: tag)
    }

    private static func fleetTag(of directive: Directive) -> String {
        directive.fleetTag ?? defaultFleetTag
    }

    /// Where this run delivers: the recognised hub, or `deliveryLocation` when
    /// no hub is on the mesh. One recognition rule, shared with `RelayRun`.
    public static func deliverySink(in world: WorldSnapshot) -> String {
        RelayRun.hubLocation(in: world) ?? deliveryLocation
    }

    /// The stockpile `controller` is draining, or nil when it runs no config
    /// this run could have issued. `delivery` is the sink to recognise it by.
    public static func drainedPile(of controller: Device, delivery: String) -> String? {
        guard hasTakenSomeHaulConfig(controller, delivery: delivery) else { return nil }
        return controller.currentDirectiveConfig?["collect"]?.stringValue
    }

    /// The stockpile `tag`ged controllers are draining, or nil for the "Nothing
    /// reachable" state. Names the LOWEST-CODED controller's pile when several
    /// differ, so the answer cannot flicker with dictionary order.
    public static func currentHaulTarget(devices: [Device], tag: String, delivery: String) -> String? {
        devices
            .filter { $0.hasTag(tag) }
            .sorted { $0.deviceCode < $1.deviceCode }
            .lazy
            .compactMap { drainedPile(of: $0, delivery: delivery) }
            .first
    }

    private static func plans(_ directive: Directive, _ world: WorldSnapshot) -> [HaulTargetPlanner.Assignment] {
        HaulTargetPlanner.assignments(
            controllers: controllers(in: world, tag: fleetTag(of: directive)),
            footprints: world.footprints.mapValues(\.resources),
            meshSystems: SalvageTargetPlanner.meshSystems(in: Array(world.devices.values)),
            delivery: deliverySink(in: world)
        )
    }

    /// The one collect location a per-mine row is pinned to, or nil for the
    /// general drainer. A pinned row drives only its own `deviceCode`.
    public static func pinnedSource(of directive: Directive) -> String? {
        directive.targets.first
    }

    private static func pinnedAssignment(_ directive: Directive, at location: String) -> HaulTargetPlanner.Assignment {
        HaulTargetPlanner.Assignment(
            controllerCode: directive.deviceCode, location: location,
            directive: HaulTargetPlanner.ferry
        )
    }

    /// Whether `world` already reports `assignment` in force on its controller.
    /// Read off the controller's own `ami_directive` block, so the run needs no
    /// column to remember assignments. `confirm` needs the looser check instead.
    static func isInForce(_ assignment: HaulTargetPlanner.Assignment, in world: WorldSnapshot) -> Bool {
        guard let controller = world.device(assignment.controllerCode),
              controller.currentDirective == assignment.directive,
              let config = controller.currentDirectiveConfig
        else { return false }
        return config["collect"]?.stringValue == assignment.location
            && config["deliver"]?.stringValue == deliverySink(in: world)
    }

    /// Whether `controller` runs ANY config this run could have issued, whichever
    /// pile it names. **Only meaningful on a row read AFTER the dispatch** — the
    /// pre-dispatch config satisfies it exactly, so `confirm` must order the two.
    static func hasTakenSomeHaulConfig(_ controller: Device, delivery: String) -> Bool {
        guard let currentDirective = controller.currentDirective,
              [HaulTargetPlanner.ferry, HaulTargetPlanner.shuttle].contains(currentDirective),
              let sink = controller.currentDirectiveConfig?["deliver"]?.stringValue
        else { return false }
        // The fallback counts too: the sink is DERIVED, so a hub that flickers
        // between dispatch and confirm would otherwise read a landed command as
        // refused. `isInForce` stays strict, so the repoint still happens.
        return sink == delivery || sink == deliveryLocation
    }

    // MARK: - Re-entry budget

    /// How many times, contiguously, `controllerCode` has entered `dispatching`
    /// since `directive` last left the loop or an operator resolved a stall.
    /// **Must stay scoped to ONE controller** — an unscoped count reaches the
    /// limit on the first healthy pass of an N-controller fleet.
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

    /// Confirm `directive`'s tagged fleet exists in `world`, buying a tag read when
    /// the local rows are empty or stale. Tag scope is the only one that sees every
    /// member regardless of state.
    private func preflight(_ directive: Directive, _ world: WorldSnapshot) -> MissionAction {
        if Self.pinnedSource(of: directive) != nil {
            let keeper = world.device(directive.deviceCode)
            let believable = keeper.map {
                world.now.timeIntervalSince($0.updatedAt) <= Self.stagingFreshness
            } ?? false
            guard believable else {
                return .refreshDevices(
                    deviceCodes: [directive.deviceCode], thenStall: .noHaulControllerTagged
                )
            }
            return .advanceStep(nextStep: Step.surveying)
        }
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

    /// Refresh the stockpile census, gated on `world`'s freshest read so the 5s
    /// tick cannot multiply into requests. `thenStall: nil` never escalates — a
    /// stale census is a lull, not a fault.
    private func survey(_ directive: Directive, _ world: WorldSnapshot) -> MissionAction {
        let newest = world.footprints.values.map(\.fetchedAt).max()
        if let newest, world.now.timeIntervalSince(newest) < Self.pollInterval {
            return .advanceStep(nextStep: Step.assigning)
        }
        return .refreshFootprint(nextStep: Step.assigning, thenStall: nil)
    }

    /// Pin ONE pending controller for `dispatching` to command, or move on when
    /// every controller in `world` already matches. N controllers settle over N
    /// ticks, keeping the one-action-per-tick contract.
    private func assign(_ directive: Directive, _ world: WorldSnapshot) -> MissionAction {
        if let pinned = Self.pinnedSource(of: directive) {
            let assignment = Self.pinnedAssignment(directive, at: pinned)
            if Self.isInForce(assignment, in: world) {
                return .advanceStep(nextStep: Step.hauling)
            }
            return .assignController(deviceCode: assignment.controllerCode, nextStep: Step.dispatching)
        }
        let tag = Self.fleetTag(of: directive)
        guard !Self.controllers(in: world, tag: tag).isEmpty else {
            // Local silence is not evidence — `noHaulControllerTagged` belongs to a
            // fresh TAG READ finding nothing.
            return .refreshFleet(tag: tag, thenStall: .noHaulControllerTagged)
        }
        let assignments = Self.plans(directive, world)
        guard let pending = assignments.first(where: { !Self.isInForce($0, in: world) }) else {
            // Never `.done`: the Salvage Run keeps making new piles under this one,
            // so an empty frontier is a lull.
            return .advanceStep(nextStep: Step.hauling)
        }
        logger.debug("haul run \(directive.id, privacy: .public): pinning \(pending.controllerCode, privacy: .public)")
        return .assignController(deviceCode: pending.controllerCode, nextStep: Step.dispatching)
    }

    /// Issue the command `assigning` chose, against the controller `directive`
    /// pinned. Re-derives the target from `world` — the run stores no assignment
    /// state beyond `controllerCode`.
    private func dispatchAssignment(_ directive: Directive, _ world: WorldSnapshot) -> MissionAction {
        guard let controllerCode = directive.controllerCode else {
            return .advanceStep(nextStep: Step.assigning)
        }
        guard world.device(controllerCode) != nil else {
            // Gone from the account, not merely untagged — this lookup ignores the
            // tag filter. A configuration problem, not a lull.
            return .stall(.unreachableDevice)
        }
        let pending: HaulTargetPlanner.Assignment
        if let pinned = Self.pinnedSource(of: directive) {
            pending = Self.pinnedAssignment(directive, at: pinned)
        } else if let planned = Self.plans(directive, world).first(where: { $0.controllerCode == controllerCode }) {
            pending = planned
        } else {
            // Census moved since `assign` ran; let it re-plan.
            return .advanceStep(nextStep: Step.assigning)
        }
        if Self.isInForce(pending, in: world) {
            return .advanceStep(nextStep: Step.assigning)
        }
        guard Self.dispatchAttemptCount(directive, world, controllerCode: controllerCode) <= Self.dispatchAttemptLimit else {
            logger.notice("haul run \(directive.id, privacy: .public): \(controllerCode, privacy: .public) exhausted its dispatch-attempt budget — stalling")
            return .stall(.commandRejected)
        }
        logger.info("haul run \(directive.id, privacy: .public): pointing \(pending.controllerCode, privacy: .public) at \(pending.location, privacy: .public)")
        return .dispatch(
            kind: .setDirective,
            deviceCode: pending.controllerCode,
            params: CommandParams(directive: pending.directive, configuration: [
                "collect": .string(pending.location),
                "deliver": .string(Self.deliverySink(in: world)),
            ]),
            nextStep: Step.confirming
        )
    }

    /// Poll until the pinned controller reports a config this run could have
    /// issued, then go back to `assigning`. Every path that stays in this step
    /// returns `.wait` — the one action that does not re-stamp `stepStartedAt`,
    /// so anything else makes this step's deadline unreachable.
    private func confirm(_ directive: Directive, _ world: WorldSnapshot) -> MissionAction {
        guard let controllerCode = directive.controllerCode else {
            return .advanceStep(nextStep: Step.assigning)
        }
        guard let controller = world.device(controllerCode) else {
            return .stall(.unreachableDevice)
        }
        guard controller.updatedAt >= directive.stepStartedAt else {
            // Row read BEFORE the command went out, so it cannot say whether the
            // controller took it — and the pre-dispatch config is exactly what
            // `hasTakenSomeHaulConfig` would mistake for evidence.
            //
            // Deadline check comes FIRST: a row that can never be refreshed never
            // satisfies the guard, and a failed read never advances `updatedAt`, so
            // a staleness-first ordering polls `.high` reads forever.
            if world.now.timeIntervalSince(directive.stepStartedAt) >= Self.confirmDeadline {
                return .refreshDevices(deviceCodes: [controllerCode], thenStall: .commandRejected)
            }
            if world.now.timeIntervalSince(controller.updatedAt) > Self.confirmReadInterval {
                return .refreshDevices(deviceCodes: [controllerCode], thenStall: nil)
            }
            return .wait
        }
        if Self.hasTakenSomeHaulConfig(controller, delivery: Self.deliverySink(in: world)) {
            return .advanceStep(nextStep: Step.assigning)
        }
        if world.now.timeIntervalSince(directive.stepStartedAt) < Self.confirmDeadline {
            return .wait
        }
        // Past the deadline, buy one read before giving up — the command may have
        // landed while the local row sat stale.
        return .refreshDevices(deviceCodes: [controllerCode], thenStall: .commandRejected)
    }

    /// Hold for `pollInterval` against `world`'s clock, then survey again. `.wait`
    /// writes nothing, so the interval can be measured without the step resetting
    /// the clock it reads.
    private func haul(_ directive: Directive, _ world: WorldSnapshot) -> MissionAction {
        if world.now.timeIntervalSince(directive.stepStartedAt) < Self.pollInterval {
            return .wait
        }
        return .advanceStep(nextStep: Step.surveying)
    }
}
