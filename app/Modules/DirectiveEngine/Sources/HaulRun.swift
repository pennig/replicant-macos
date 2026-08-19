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
    public var firstStep: String { Step.preflight.rawValue }

    public init() {}

    /// This mission's step vocabulary, as `Directive.step` holds it (D6).
    public enum Step: String, CaseIterable, Sendable {
        /// Prove the tagged fleet exists before anything is commanded.
        case preflight
        /// Refresh the stockpile census the target ranking is read from.
        case surveying
        /// Pin the one controller this evaluation wants to repoint.
        case assigning
        /// Issue the command `assigning` chose, against the controller it pinned.
        /// Must dispatch with `nextStep: .confirming`, never itself — `set_directive`
        /// creates no tracked `Operation`, so a self-naming step re-issues forever.
        case dispatching
        /// Poll until the pinned controller reports, on a row read AFTER the
        /// dispatch, some config this run could have issued, then hand back to
        /// `assigning`. Waits or reads, never dispatches.
        case confirming
        /// The quiet step between census reads.
        case hauling
    }

    /// The fleet tag a row falls back to when it carries none of its own.
    public static let defaultFleetTag = FleetTag(goal: .haul)

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
        guard let step = Step(rawValue: directive.step) else {
            logger.notice("\(kind.rawValue, privacy: .public) \(directive.id, privacy: .public): unknown step \(directive.step, privacy: .public) — waiting")
            return .wait
        }
        switch step {
        case .preflight: return preflight(directive, world)
        case .surveying: return survey(directive, world)
        case .assigning: return assign(directive, world)
        case .dispatching: return dispatchAssignment(directive, world)
        case .confirming: return confirm(directive, world)
        case .hauling: return haul(directive, world)
        }
    }

    /// Never `.exhausted` — that would finish a run which has no finish line.
    public func plan(_ context: RoamContext) -> RoamPlan { .idle }

    // MARK: - Fleet

    /// Every device in `devices` matching `tag` (see `isFleetTagged`) and
    /// offering `ferry`, sorted by code so a controller keeps its rank across
    /// evaluations. Resolved by TAG, never location — untagging is the opt-out.
    public static func controllers(in devices: some Sequence<Device>, tag: FleetTag) -> [Device] {
        devices
            .filter { isFleetTagged($0, tag: tag) }
            .filter { $0.availableDirectives.contains(requiredDirective) }
            .sorted { $0.deviceCode < $1.deviceCode }
    }

    /// `theatreDepot`, when given, scopes the result through `belongs` (see
    /// `haul-run-theatre-scoped-controllers.md`); nil preserves the old read.
    public static func controllers(in world: WorldSnapshot, tag: FleetTag, theatreDepot: String? = nil) -> [Device] {
        let matched = controllers(in: world.devices.values, tag: tag)
        // The goal test states this overload's contract: a theatre scopes a
        // haul fleet, never a per-belt ferry's. Every caller is pinned-guarded.
        guard let theatreDepot, tag.goal == .haul else { return matched }
        return matched.filter { belongs($0, to: theatreDepot, resolver: world.theatreResolver) }
    }

    /// Whether `depot` may spend `device` — `FleetMembership.isDeployable`:
    /// its fleet by tag or location, and placeable by the census.
    public static func belongs(_ device: Device, to depot: String, resolver: TheatreResolver) -> Bool {
        FleetMembership.isDeployable(device, toDepot: depot, goal: .haul, resolver: resolver)
    }

    /// The tag `Brain.ensureHaul` stamps for a theatre at `depot`.
    public static func fleetTag(forTheatre depot: String) -> FleetTag {
        FleetTag(goal: .haul, scope: .theatre(depot: depot))
    }

    /// Whether `device` matches `tag`, or — only when `tag` is a per-theatre
    /// derivation of the default and `device` names no theatre of its own —
    /// the bare default it falls back from.
    static func isFleetTagged(_ device: Device, tag: FleetTag) -> Bool {
        if device.carries(tag, policy: .exact) { return true }
        guard tag.goal == .haul, tag.isScoped, device.scopedTag(for: .haul) == nil else { return false }
        return device.carries(defaultFleetTag, policy: .exact)
    }

    private static func fleetTag(of directive: Directive) -> FleetTag {
        directive.fleetTag.flatMap(FleetTag.init(parsing:)) ?? defaultFleetTag
    }

    /// Where `directive` delivers: its own theatre's depot, or `deliveryLocation`
    /// when the row is unstamped or its theatre is non-operational.
    public static func deliverySink(in world: WorldSnapshot, for directive: Directive) -> String {
        world.theatreDepot(for: directive) ?? deliveryLocation
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
    public static func currentHaulTarget(devices: [Device], tag: FleetTag, delivery: String) -> String? {
        devices
            .filter { isFleetTagged($0, tag: tag) }
            .sorted { $0.deviceCode < $1.deviceCode }
            .lazy
            .compactMap { drainedPile(of: $0, delivery: delivery) }
            .first
    }

    private static func plans(_ directive: Directive, _ world: WorldSnapshot) -> [HaulTargetPlanner.Assignment] {
        HaulTargetPlanner.assignments(
            controllers: controllers(in: world, tag: fleetTag(of: directive), theatreDepot: directive.theatreDepot),
            footprints: world.footprints.mapValues(\.resources),
            components: world.components,
            positions: world.starPositions,
            delivery: deliverySink(in: world, for: directive),
            depots: Set(world.theatres.map(\.depot))
        )
    }

    /// The one collect location a per-mine row is pinned to, or nil for the
    /// general drainer. A pinned row drives only its own `deviceCode`.
    public static func pinnedSource(of directive: Directive) -> String? {
        directive.targets.first
    }

    private static func pinnedAssignment(
        _ directive: Directive, at location: String, in world: WorldSnapshot
    ) -> HaulTargetPlanner.Assignment {
        HaulTargetPlanner.Assignment(
            controllerCode: directive.deviceCode, location: location,
            directive: HaulTargetPlanner.verb(from: location, to: deliverySink(in: world, for: directive))
        )
    }

    /// Whether `world` already reports `assignment` in force on its controller.
    /// Read off the controller's own `ami_directive` block, so the run needs no
    /// column to remember assignments. `confirm` needs the looser check instead.
    static func isInForce(
        _ assignment: HaulTargetPlanner.Assignment, in world: WorldSnapshot, for directive: Directive
    ) -> Bool {
        guard let controller = world.device(assignment.controllerCode),
              controller.currentDirective == assignment.directive,
              let config = controller.currentDirectiveConfig
        else { return false }
        return config["collect"]?.stringValue == assignment.location
            && config["deliver"]?.stringValue == deliverySink(in: world, for: directive)
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
            case Step.dispatching.rawValue:
                if entry.deviceCode == controllerCode { count += 1 }
            case Step.assigning.rawValue, Step.confirming.rawValue:
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
            return .advanceStep(nextStep: Step.surveying.rawValue)
        }
        let tag = Self.fleetTag(of: directive)
        let found = Self.controllers(in: world, tag: tag, theatreDepot: directive.theatreDepot)
        let stale = found.isEmpty || found.contains {
            world.now.timeIntervalSince($0.updatedAt) > Self.stagingFreshness
        }
        if stale {
            return .refreshFleet(tag: tag, thenStall: .noHaulControllerTagged)
        }
        return .advanceStep(nextStep: Step.surveying.rawValue)
    }

    /// Refresh the stockpile census, gated on `world`'s freshest read so the 5s
    /// tick cannot multiply into requests. `thenStall: nil` never escalates — a
    /// stale census is a lull, not a fault.
    private func survey(_ directive: Directive, _ world: WorldSnapshot) -> MissionAction {
        let newest = world.footprints.values.map(\.fetchedAt).max()
        if let newest, world.now.timeIntervalSince(newest) < Self.pollInterval {
            return .advanceStep(nextStep: Step.assigning.rawValue)
        }
        return .refreshFootprint(nextStep: Step.assigning.rawValue, thenStall: nil)
    }

    /// Pin ONE pending controller for `dispatching` to command, or move on when
    /// every controller in `world` already matches. N controllers settle over N
    /// ticks, keeping the one-action-per-tick contract.
    private func assign(_ directive: Directive, _ world: WorldSnapshot) -> MissionAction {
        // A theatre gone `.claimed` while another stands operational must not
        // repoint cargo at the fallback sink — wait for it to recover.
        guard !world.theatreWentClaimed(for: directive) else { return .wait }
        if let pinned = Self.pinnedSource(of: directive) {
            let assignment = Self.pinnedAssignment(directive, at: pinned, in: world)
            if Self.isInForce(assignment, in: world, for: directive) {
                return .advanceStep(nextStep: Step.hauling.rawValue)
            }
            return .assignController(deviceCode: assignment.controllerCode, nextStep: Step.dispatching.rawValue)
        }
        let tag = Self.fleetTag(of: directive)
        guard !Self.controllers(in: world, tag: tag, theatreDepot: directive.theatreDepot).isEmpty else {
            // Local silence is not evidence — `noHaulControllerTagged` belongs to a
            // fresh TAG READ finding nothing.
            return .refreshFleet(tag: tag, thenStall: .noHaulControllerTagged)
        }
        let assignments = Self.plans(directive, world)
        guard let pending = assignments.first(where: { !Self.isInForce($0, in: world, for: directive) }) else {
            // Never `.done`: the Salvage Run keeps making new piles under this one,
            // so an empty frontier is a lull.
            return .advanceStep(nextStep: Step.hauling.rawValue)
        }
        logger.debug("haul run \(directive.id, privacy: .public): pinning \(pending.controllerCode, privacy: .public)")
        return .assignController(deviceCode: pending.controllerCode, nextStep: Step.dispatching.rawValue)
    }

    /// Issue the command `assigning` chose, against the controller `directive`
    /// pinned. Re-derives the target from `world` — the run stores no assignment
    /// state beyond `controllerCode`.
    private func dispatchAssignment(_ directive: Directive, _ world: WorldSnapshot) -> MissionAction {
        guard !world.theatreWentClaimed(for: directive) else { return .wait }
        guard let controllerCode = directive.controllerCode else {
            return .advanceStep(nextStep: Step.assigning.rawValue)
        }
        guard world.device(controllerCode) != nil else {
            // Gone from the account, not merely untagged — this lookup ignores the
            // tag filter. A configuration problem, not a lull.
            return .stall(.unreachableDevice)
        }
        let pending: HaulTargetPlanner.Assignment
        if let pinned = Self.pinnedSource(of: directive) {
            pending = Self.pinnedAssignment(directive, at: pinned, in: world)
        } else if let planned = Self.plans(directive, world).first(where: { $0.controllerCode == controllerCode }) {
            pending = planned
        } else {
            // Census moved since `assign` ran; let it re-plan.
            return .advanceStep(nextStep: Step.assigning.rawValue)
        }
        if Self.isInForce(pending, in: world, for: directive) {
            return .advanceStep(nextStep: Step.assigning.rawValue)
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
                "deliver": .string(Self.deliverySink(in: world, for: directive)),
            ]),
            nextStep: Step.confirming.rawValue
        )
    }

    /// Poll until the pinned controller reports a config this run could have
    /// issued, then go back to `assigning`. Every path that stays in this step
    /// returns `.wait` — the one action that does not re-stamp `stepStartedAt`,
    /// so anything else makes this step's deadline unreachable.
    private func confirm(_ directive: Directive, _ world: WorldSnapshot) -> MissionAction {
        guard let controllerCode = directive.controllerCode else {
            return .advanceStep(nextStep: Step.assigning.rawValue)
        }
        guard let controller = world.device(controllerCode) else {
            return .stall(.unreachableDevice)
        }
        // A stale row's pre-dispatch config is exactly what `hasTakenSomeHaulConfig`
        // would mistake for evidence, so success is judged only on a fresh row.
        if world.isFresh(controller, since: directive.stepStartedAt),
           Self.hasTakenSomeHaulConfig(controller, delivery: Self.deliverySink(in: world, for: directive)) {
            return .advanceStep(nextStep: Step.assigning.rawValue)
        }
        let ctx = StepContext(directive: directive, world: world, step: directive.step)
        var ladder = ConfirmRow(deadline: Self.confirmDeadline, onExpiry: .readThenStall(.commandRejected))
        ladder.readInterval = Self.confirmReadInterval
        return switch ladder.verdict([controller], ctx) {
        case let .act(action): action
        case .judge: .wait
        }
    }

    /// Hold for `pollInterval` against `world`'s clock, then survey again. `.wait`
    /// writes nothing, so the interval can be measured without the step resetting
    /// the clock it reads.
    private func haul(_ directive: Directive, _ world: WorldSnapshot) -> MissionAction {
        if world.now.timeIntervalSince(directive.stepStartedAt) < Self.pollInterval {
            return .wait
        }
        return .advanceStep(nextStep: Step.surveying.rawValue)
    }
}
