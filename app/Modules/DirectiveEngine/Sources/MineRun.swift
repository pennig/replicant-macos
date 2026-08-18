//
//  MineRun.swift
//  Replicould — DirectiveEngine
//
//  Installs a printed mine fleet at a belt: attach the nine carried members to
//  the surge carrier, fly it out, set them down, hand the drones to their
//  controllers, put every controller and bot to work, and fly the carrier home.
//

import Foundation
import GameModels
import GameServices
import OSLog
import UniverseModels
import Utils

private let logger = Logger(subsystem: "name.pennig.replicould", category: "DirectiveEngine")

public struct MineRun: MissionStepMachine {
    public let kind: DirectiveKind = .mineRun
    public var firstStep: String { Step.preflight.rawValue }

    public init() {}

    /// This mission's step vocabulary, as `Directive.step` holds it (D6).
    public enum Step: String, CaseIterable, Sendable {
        case preflight
        /// Attach one carried member per round; `attach` moves one row at a time.
        case attaching
        case confirmingAttach
        case travelling
        case confirmingArrival
        /// Set the whole fleet down at the belt in one command.
        case detaching
        case confirmingDetach
        case adopting
        case confirmingAdopt
        case arming
        case confirmingArm
        /// Reached from `arming` only when the run carries `returnToOrigin`.
        case returning
    }

    /// The cap on one attach confirmation before the run surfaces the command
    /// as rejected.
    public static let attachConfirmDeadline: TimeInterval = 5 * 60

    /// Shared with the Salvage Run so the two cannot disagree about how long a
    /// carrier row may lag the arrival it reflects.
    public static let arrivalConfirmDeadline = TravelTo.arrivalConfirmDeadline

    /// How many rows ride the carrier.
    public static let carriedTotal = MineRecipe.carried.reduce(0) { $0 + $1.quantity }

    /// The directive each installed member ends up running. `gather_evenly`
    /// works the whole belt; `gather_resources` would take one resource type and
    /// strand the rest, so no builder here names it.
    public static let miningDirective = "gather_evenly"
    public static let surveyDirective = "belt_search"
    public static let serviceDirective = "service"

    /// The belt this run delivers to.
    public static func targetBelt(of directive: Directive) -> String? { directive.targets.first }

    /// The one action `directive` calls for against `world`.
    public func nextAction(directive: Directive, world: WorldSnapshot) -> MissionAction {
        guard let carrier = world.device(directive.deviceCode) else {
            return .stall(.unreachableDevice)
        }
        guard let step = Step(rawValue: directive.step) else {
            logger.notice("\(kind.rawValue, privacy: .public) \(directive.id, privacy: .public): unknown step \(directive.step, privacy: .public) — waiting")
            return .wait
        }
        switch step {
        case .preflight: return preflight(directive, carrier, world)
        case .attaching: return attach(directive, carrier, world)
        case .confirmingAttach: return confirmAttach(directive, carrier, world)
        case .travelling: return travel(directive, carrier, world)
        case .confirmingArrival: return confirmArrival(directive, carrier, world)
        case .detaching: return detach(directive, carrier, world)
        case .confirmingDetach: return confirmDetach(directive, carrier, world)
        case .adopting: return adopt(directive, world)
        case .confirmingAdopt: return confirmAdopt(directive, world)
        case .arming: return arm(directive, world)
        case .confirmingArm: return confirmArm(directive, world)
        case .returning: return returnHome(directive, carrier, world)
        }
    }

    /// The run delivers one fleet to one belt and plans no targets of its own.
    public func plan(_ context: RoamContext) -> RoamPlan { .exhausted }

    // MARK: - Membership

    /// The carried members by type: rows attached to the carrier first, topped
    /// up from the free fleet at its location and capped per recipe slot — a
    /// choice that does not move as attachment proceeds.
    public static func members(
        of directive: Directive, in world: WorldSnapshot
    ) -> [String: [Device]] {
        guard let carrier = world.device(directive.deviceCode) else { return [:] }
        let rows = Array(world.devices.values)
        let free = carrier.location.map { MineRecipe.unassignedFleet(at: $0, in: rows) } ?? [:]
        var out: [String: [Device]] = [:]
        for (type, quantity) in MineRecipe.carried {
            let aboard = rows
                .filter {
                    $0.deviceType == type && $0.carries(MineRecipe.fleetTag, policy: .exact)
                        && $0.attachedToDeviceCode == carrier.deviceCode
                }
                .sorted { $0.deviceCode < $1.deviceCode }
            let taken = Set(aboard.map(\.deviceCode))
            let topUp = (free[type] ?? []).filter { !taken.contains($0.deviceCode) }
            out[type] = Array((aboard + topUp).prefix(quantity))
        }
        return out
    }

    /// Every carried member as one list, lowest-coded first — the order attach
    /// dispatches follow, so a re-evaluation reaches for the same row.
    static func roster(of directive: Directive, in world: WorldSnapshot) -> [Device] {
        members(of: directive, in: world)
            .values
            .flatMap { $0 }
            .sorted { $0.deviceCode < $1.deviceCode }
    }

    /// The carried members standing at the belt, by type, lowest-coded first.
    /// Adoption and arming move neither location nor tag, so this roster holds
    /// still while both loops run — unlike `members(of:in:)`, which does not.
    static func landed(of directive: Directive, in world: WorldSnapshot) -> [String: [Device]] {
        guard let belt = targetBelt(of: directive) else { return [:] }
        var out: [String: [Device]] = [:]
        for (type, quantity) in MineRecipe.carried {
            out[type] = world.devices.values
                .filter {
                    $0.deviceType == type && $0.carries(MineRecipe.fleetTag, policy: .exact) && $0.location == belt
                }
                .sorted { $0.deviceCode < $1.deviceCode }
                .prefix(quantity)
                .map { $0 }
        }
        return out
    }

    /// The two self-moving members serving `directive`'s belt, resolved at the
    /// delivery sink. The pair THIS belt already owns is matched first: the tag
    /// and the sink are shared, so spare free pairs stand there too.
    static func transport(
        of directive: Directive, in world: WorldSnapshot
    ) -> (controller: Device, freighter: Device)? {
        guard let belt = targetBelt(of: directive) else { return nil }
        let sink = HaulRun.deliverySink(in: world, for: directive)
        let rows = Array(world.devices.values)
        let free = MineRecipe.unassignedFleet(at: sink, in: rows)
        let controller = rows
            .filter {
                $0.deviceType == "ami_transport_controller" && $0.carries(MineRecipe.fleetTag, policy: .exact)
                    && $0.location == sink
                    && $0.currentDirectiveConfig?["collect"]?.stringValue == belt
            }
            .min { $0.deviceCode < $1.deviceCode }
            ?? free["ami_transport_controller"]?.first
        guard let controller else { return nil }
        let freighter = rows
            .filter {
                $0.deviceType == "cargo_freighter" && $0.carries(MineRecipe.fleetTag, policy: .exact)
                    && $0.location == sink
                    && $0.controllerDeviceCode == controller.deviceCode
            }
            .min { $0.deviceCode < $1.deviceCode }
            ?? free["cargo_freighter"]?.first
        guard let freighter else { return nil }
        return (controller, freighter)
    }

    /// The whole installed fleet: every carried slot filled at the belt, plus
    /// the two controllers and the transport pair the adopt and arm halves both
    /// have to find in it.
    private struct Installation {
        let landed: [String: [Device]]
        let mining: Device
        let survey: Device
        let transport: (controller: Device, freighter: Device)
    }

    private static func installation(
        of directive: Directive, in world: WorldSnapshot
    ) -> Installation? {
        let landed = landed(of: directive, in: world)
        guard !MineRecipe.carried.contains(where: { (landed[$0.deviceType]?.count ?? 0) < $0.quantity }),
              let mining = landed["ami_mining_controller"]?.first,
              let survey = landed["ami_survey_controller"]?.first,
              let transport = transport(of: directive, in: world)
        else { return nil }
        return Installation(landed: landed, mining: mining, survey: survey, transport: transport)
    }

    // MARK: - Adoption

    /// One controller and the members it must take under control.
    struct Adoption: Equatable {
        let controller: Device
        let members: [Device]

        var pending: [Device] {
            members.filter { $0.controllerDeviceCode != controller.deviceCode }
        }
    }

    /// The three adoptions in dependency order, or nil when the fleet cannot be
    /// assembled from local rows.
    static func adoptions(of directive: Directive, in world: WorldSnapshot) -> [Adoption]? {
        guard let fleet = installation(of: directive, in: world) else { return nil }
        return [
            Adoption(controller: fleet.mining, members: fleet.landed["mining_drone"] ?? []),
            Adoption(controller: fleet.survey, members: fleet.landed["survey_drone"] ?? []),
            Adoption(controller: fleet.transport.controller, members: [fleet.transport.freighter]),
        ]
    }

    // MARK: - Arming

    /// The five arm targets, in dependency order. Adoption happens strictly
    /// before arming: an armed controller with no adopted drones coordinates
    /// nothing.
    struct ArmTarget: Equatable {
        let deviceCode: String
        let directive: String
        let configuration: [String: JSONValue]?
    }

    static func armTargets(of directive: Directive, in world: WorldSnapshot) -> [ArmTarget]? {
        guard let belt = targetBelt(of: directive),
              let fleet = installation(of: directive, in: world)
        else { return nil }
        var out = [
            ArmTarget(
                deviceCode: fleet.mining.deviceCode, directive: miningDirective, configuration: nil
            ),
            ArmTarget(
                deviceCode: fleet.survey.deviceCode, directive: surveyDirective, configuration: nil
            ),
        ]
        out += (fleet.landed["service_bot"] ?? []).map {
            ArmTarget(deviceCode: $0.deviceCode, directive: serviceDirective, configuration: nil)
        }
        let sink = HaulRun.deliverySink(in: world, for: directive)
        out.append(ArmTarget(
            deviceCode: fleet.transport.controller.deviceCode,
            directive: HaulTargetPlanner.verb(from: belt, to: sink),
            configuration: ["collect": .string(belt), "deliver": .string(sink)]
        ))
        return out
    }

    /// Whether `device` already runs `target`'s directive and configuration.
    static func isInForce(_ target: ArmTarget, _ device: Device) -> Bool {
        guard device.currentDirective == target.directive else { return false }
        guard let wanted = target.configuration else { return true }
        let config = device.currentDirectiveConfig
        guard config?["collect"]?.stringValue == wanted["collect"]?.stringValue else { return false }
        // The sink is DERIVED, so a hub flickering between dispatch and confirm
        // would otherwise read a landed ferry as refused.
        let deliver = config?["deliver"]?.stringValue
        return deliver == wanted["deliver"]?.stringValue || deliver == HaulRun.deliveryLocation
    }

    /// How far `target` has got: 0 not in force, 1 in force but not running,
    /// 2 running. Monotone, so one dispatch that lands raises it by at least one.
    static func armState(_ target: ArmTarget, in world: WorldSnapshot) -> Int {
        guard let device = world.device(target.deviceCode), isInForce(target, device) else {
            return 0
        }
        return device.currentDirectiveStatus == "active" ? 2 : 1
    }

    // MARK: - Steps

    /// Prove the belt is commandable and the fleet is whole before spending the
    /// carrier on the trip.
    private func preflight(
        _ directive: Directive, _ carrier: Device, _ world: WorldSnapshot
    ) -> MissionAction {
        guard let belt = Self.targetBelt(of: directive) else { return .stall(.unreachableDevice) }
        let rows = Array(world.devices.values)
        let depots = Set(world.theatres.filter(\.isOperational).map(\.depot))
        // A mine on any operational depot is invisible to `installedBelts`,
        // which excludes every depot: a row aimed there is malformed by construction.
        if depots.contains(belt) { return .stall(.unreachableDevice) }
        // Off the mesh nothing at the belt can be commanded, and that is not a
        // fleet gap: `.mineFleetIncomplete` is reserved for those.
        guard SalvageTargetPlanner.meshSystems(in: rows).contains(SiteAssay.system(of: belt)) else {
            return .stall(.unreachableDevice)
        }
        let members = Self.members(of: directive, in: world)
        let short = MineRecipe.carried.contains { (members[$0.deviceType]?.count ?? 0) < $0.quantity }
        if short {
            // A negative finding over local rows: the tag scope is the only one
            // that sees an attached or stowed member, so buy it before stalling.
            return .refreshFleet(tag: MineRecipe.fleetTag, thenStall: .mineFleetIncomplete)
        }
        if MineRecipe.installedBelts(in: rows, hubs: depots).contains(belt) { return .done }
        return .advanceStep(nextStep: Step.attaching.rawValue)
    }

    /// Attach the next loose member. One per round: `attach` moves one row and
    /// is immediate, so the dispatch must hand to a confirming step.
    private func attach(
        _ directive: Directive, _ carrier: Device, _ world: WorldSnapshot
    ) -> MissionAction {
        let roster = Self.roster(of: directive, in: world)
        let loose = roster.filter { $0.attachedToDeviceCode != carrier.deviceCode }
        guard let next = loose.first else {
            guard roster.count == Self.carriedTotal else {
                return .refreshFleet(tag: MineRecipe.fleetTag, thenStall: .mineFleetIncomplete)
            }
            return .advanceStep(nextStep: Step.travelling.rawValue)
        }
        return .dispatch(
            kind: .attach, deviceCode: carrier.deviceCode,
            params: CommandParams(devices: [next.deviceCode]), nextStep: Step.confirmingAttach.rawValue
        )
    }

    /// Judge the attach just ordered, looping back for the next member.
    ///
    /// The dispatch's own confirm-read of the moved row lands BEFORE the step is
    /// stamped, so the loop's round count — not row freshness — proves it landed.
    private func confirmAttach(
        _ directive: Directive, _ carrier: Device, _ world: WorldSnapshot
    ) -> MissionAction {
        let roster = Self.roster(of: directive, in: world)
        let loose = roster.filter { $0.attachedToDeviceCode != carrier.deviceCode }
        guard let next = loose.first else { return .advanceStep(nextStep: Step.attaching.rawValue) }
        let rounds = MissionLogBudget.dispatchRounds(
            world, dispatch: Step.attaching.rawValue, confirm: Step.confirmingAttach.rawValue
        )
        if roster.count - loose.count >= rounds { return .advanceStep(nextStep: Step.attaching.rawValue) }
        return MissionConfirm.ladder(
            [next], directive, world,
            deadline: Self.attachConfirmDeadline, thenStall: .commandRejected
        )
    }

    /// Fly the loaded carrier to the belt.
    private func travel(
        _ directive: Directive, _ carrier: Device, _ world: WorldSnapshot
    ) -> MissionAction {
        guard let belt = Self.targetBelt(of: directive) else { return .stall(.unreachableDevice) }
        let ctx = StepContext(directive: directive, world: world, step: directive.step)
        let leg = TravelTo(
            deviceCode: carrier.deviceCode, destination: belt,
            arrivalTest: .exactLocation, confirmStep: Step.confirmingArrival.rawValue
        )
        return switch leg.next(ctx) {
        case let .action(action): action
        case .finished: .advanceStep(nextStep: Step.detaching.rawValue)
        case .more, .noSubject: .stall(.unreachableDevice)
        }
    }

    /// Judge the flight: the carrier's own row, read since the travel was
    /// ordered, has to place it at the belt.
    private func confirmArrival(
        _ directive: Directive, _ carrier: Device, _ world: WorldSnapshot
    ) -> MissionAction {
        guard let belt = Self.targetBelt(of: directive) else { return .stall(.unreachableDevice) }
        if world.isFresh(carrier, since: directive.stepStartedAt), carrier.location == belt {
            return .advanceStep(nextStep: Step.detaching.rawValue)
        }
        if world.openOperation(for: carrier.deviceCode) != nil { return .wait }
        return MissionConfirm.ladder(
            [carrier], directive, world,
            deadline: Self.arrivalConfirmDeadline, thenStall: .vesselPositionUnconfirmed
        )
    }

    /// Set the whole fleet down in one command: `detach` takes every code at once.
    private func detach(
        _ directive: Directive, _ carrier: Device, _ world: WorldSnapshot
    ) -> MissionAction {
        let aboard = Self.roster(of: directive, in: world)
            .filter { $0.attachedToDeviceCode == carrier.deviceCode }
        guard !aboard.isEmpty else { return .advanceStep(nextStep: Step.adopting.rawValue) }
        return .dispatch(
            kind: .detach, deviceCode: carrier.deviceCode,
            params: CommandParams(devices: aboard.map(\.deviceCode)), nextStep: Step.confirmingDetach.rawValue
        )
    }

    /// Judge the detach: every member loose, standing at the belt, on a row read
    /// since the command went out.
    private func confirmDetach(
        _ directive: Directive, _ carrier: Device, _ world: WorldSnapshot
    ) -> MissionAction {
        guard let belt = Self.targetBelt(of: directive) else { return .stall(.unreachableDevice) }
        let roster = Self.roster(of: directive, in: world)
        guard roster.count == Self.carriedTotal else {
            return .refreshFleet(tag: MineRecipe.fleetTag, thenStall: .mineFleetIncomplete)
        }
        let landed = roster.allSatisfy {
            world.isFresh($0, since: directive.stepStartedAt)
                && $0.attachedToDeviceCode == nil && $0.location == belt
        }
        if landed { return .advanceStep(nextStep: Step.adopting.rawValue) }
        return MissionConfirm.ladder(
            roster, directive, world,
            deadline: Self.attachConfirmDeadline, thenStall: .commandRejected
        )
    }

    /// Hand the next controller its members. One command per round: `adopt`
    /// takes the whole list at once but is immediate, so the dispatch must hand
    /// to a confirming step.
    private func adopt(_ directive: Directive, _ world: WorldSnapshot) -> MissionAction {
        guard let adoptions = Self.adoptions(of: directive, in: world) else {
            return .refreshFleet(tag: MineRecipe.fleetTag, thenStall: .mineFleetIncomplete)
        }
        guard let next = adoptions.first(where: { !$0.pending.isEmpty }) else {
            return .advanceStep(nextStep: Step.arming.rawValue)
        }
        return .dispatch(
            kind: .adopt, deviceCode: next.controller.deviceCode,
            params: CommandParams(devices: next.pending.map(\.deviceCode)),
            nextStep: Step.confirmingAdopt.rawValue
        )
    }

    /// Judge the adoption just ordered, looping back for the next controller.
    ///
    /// The command's own read of the adopted rows lands BEFORE the step is
    /// stamped, so the loop's round count — not row freshness — proves it landed.
    private func confirmAdopt(_ directive: Directive, _ world: WorldSnapshot) -> MissionAction {
        guard let adoptions = Self.adoptions(of: directive, in: world) else {
            return .refreshFleet(tag: MineRecipe.fleetTag, thenStall: .mineFleetIncomplete)
        }
        let done = adoptions.prefix { $0.pending.isEmpty }.count
        guard done < adoptions.count else { return .advanceStep(nextStep: Step.adopting.rawValue) }
        let rounds = MissionLogBudget.dispatchRounds(
            world, dispatch: Step.adopting.rawValue, confirm: Step.confirmingAdopt.rawValue
        )
        if done >= rounds { return .advanceStep(nextStep: Step.adopting.rawValue) }
        return MissionConfirm.ladder(
            adoptions[done].pending, directive, world,
            deadline: Self.attachConfirmDeadline, thenStall: .commandRejected
        )
    }

    /// Put the next target to work: name the directive when it is not in force,
    /// `activate` when it is but nothing is running. Re-sending the name would
    /// never touch the status.
    private func arm(_ directive: Directive, _ world: WorldSnapshot) -> MissionAction {
        guard let targets = Self.armTargets(of: directive, in: world) else {
            return .refreshFleet(tag: MineRecipe.fleetTag, thenStall: .mineFleetIncomplete)
        }
        guard let pending = targets.first(where: { Self.armState($0, in: world) < 2 }) else {
            guard directive.returnToOrigin else { return .done }
            return .advanceStep(nextStep: Step.returning.rawValue)
        }
        guard Self.armState(pending, in: world) > 0 else {
            return .dispatch(
                kind: .setDirective, deviceCode: pending.deviceCode,
                params: CommandParams(
                    directive: pending.directive, configuration: pending.configuration
                ),
                nextStep: Step.confirmingArm.rawValue
            )
        }
        return .dispatch(
            kind: OperationKind.simple("activate"), deviceCode: pending.deviceCode,
            params: CommandParams(), nextStep: Step.confirmingArm.rawValue
        )
    }

    /// Judge the arming just ordered, against the verb that went out: a
    /// `set_directive` lands at `armState` 1, an `activate` only at 2. A score
    /// over all five targets would bank a 0-to-2 landing as two rounds' credit.
    private func confirmArm(_ directive: Directive, _ world: WorldSnapshot) -> MissionAction {
        guard let targets = Self.armTargets(of: directive, in: world) else {
            return .refreshFleet(tag: MineRecipe.fleetTag, thenStall: .mineFleetIncomplete)
        }
        guard targets.contains(where: { Self.armState($0, in: world) < 2 }) else {
            return .advanceStep(nextStep: Step.arming.rawValue)
        }
        let ordered = MissionLogBudget.lastDispatch(
            world, dispatch: Step.arming.rawValue, confirm: Step.confirmingArm.rawValue
        )
        if case let .dispatched(kind, deviceCode) = ordered,
           let judged = targets.first(where: { $0.deviceCode == deviceCode }),
           let device = world.device(deviceCode) {
            let landed = kind == OperationKind.setDirective.rawValue
                ? Self.armState(judged, in: world) >= 1
                : Self.armState(judged, in: world) == 2
            return landed ? .advanceStep(nextStep: Step.arming.rawValue) : Self.armLadder(device, directive, world)
        }
        // A resolved stall re-enters holding no record of its own order, and
        // `arming` is the only step that can send one.
        if ordered == .nothingSent { return .advanceStep(nextStep: Step.arming.rawValue) }
        guard let pending = targets.first(where: { Self.armState($0, in: world) < 2 }),
              let device = world.device(pending.deviceCode)
        else { return .refreshFleet(tag: MineRecipe.fleetTag, thenStall: .mineFleetIncomplete) }
        return Self.armLadder(device, directive, world)
    }

    /// Fly the emptied carrier back to its theatre's depot, where the next
    /// install and the print run's carrier slot both look for it. The
    /// destination is the row's own depot, never `originDesignation`.
    private func returnHome(
        _ directive: Directive, _ carrier: Device, _ world: WorldSnapshot
    ) -> MissionAction {
        let ctx = StepContext(directive: directive, world: world, step: directive.step)
        let home = ReturnHome(deviceCodes: [carrier.deviceCode], destination: .theatreDepot)
        return switch home.next(ctx) {
        case let .action(action): action
        // Nowhere to return to is done, not a stall: the mine is installed.
        case .finished, .more: .done
        case .noSubject: noDepot(directive)
        }
    }

    /// Nothing to fly home to. Says so once, then finishes.
    private func noDepot(_ directive: Directive) -> MissionAction {
        logger.notice("mine run \(directive.id, privacy: .public): no depot to return to — leaving the carrier where it stands")
        return .done
    }

    /// The confirm ladder for one arm target, named by the device class an
    /// operator has to go and look at.
    private static func armLadder(
        _ device: Device, _ directive: Directive, _ world: WorldSnapshot
    ) -> MissionAction {
        MissionConfirm.ladder(
            [device], directive, world, deadline: attachConfirmDeadline,
            thenStall: device.deviceType == "service_bot" ? .serviceBotNotArmed : .commandRejected
        )
    }
}
