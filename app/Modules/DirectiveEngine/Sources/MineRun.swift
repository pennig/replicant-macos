//
//  MineRun.swift
//  Replicould — DirectiveEngine
//
//  Ferries a printed mine fleet to a belt: attach the nine carried members to
//  the surge carrier, fly it out, and set them down at the belt.
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
    public var firstStep: String { Step.preflight }

    public init() {}

    /// This mission's step vocabulary, as the bare strings `Directive.step` holds.
    public enum Step {
        public static let preflight = "preflight"
        /// Attach one carried member per round; `attach` moves one row at a time.
        public static let attaching = "attaching"
        public static let confirmingAttach = "confirmingAttach"
        public static let travelling = "travelling"
        public static let confirmingArrival = "confirmingArrival"
        /// Set the whole fleet down at the belt in one command.
        public static let detaching = "detaching"
        public static let confirmingDetach = "confirmingDetach"
        public static let adopting = "adopting"
        public static let confirmingAdopt = "confirmingAdopt"
        public static let arming = "arming"
        public static let confirmingArm = "confirmingArm"
    }

    /// The cap on one attach confirmation before the run surfaces the command
    /// as rejected.
    public static let attachConfirmDeadline: TimeInterval = 5 * 60

    /// Shared with the Salvage Run so the two cannot disagree about how long a
    /// carrier row may lag the arrival it reflects.
    public static let arrivalConfirmDeadline = SalvageRun.arrivalConfirmDeadline

    /// Floor between confirm-reads of a row a step is waiting on.
    public static let confirmReadInterval: TimeInterval = 30

    /// How many rows ride the carrier.
    public static let carriedTotal = MineRecipe.carried.reduce(0) { $0 + $1.quantity }

    /// The belt this run delivers to.
    public static func targetBelt(of directive: Directive) -> String? { directive.targets.first }

    /// The one action `directive` calls for against `world`. The last four steps
    /// belong to the adopt-and-arm half and hold still until it lands.
    public func nextAction(directive: Directive, world: WorldSnapshot) -> MissionAction {
        guard let carrier = world.device(directive.deviceCode) else {
            return .stall(.unreachableDevice)
        }
        switch directive.step {
        case Step.preflight: return preflight(directive, carrier, world)
        case Step.attaching: return attach(directive, carrier, world)
        case Step.confirmingAttach: return confirmAttach(directive, carrier, world)
        case Step.travelling: return travel(directive, carrier, world)
        case Step.confirmingArrival: return confirmArrival(directive, carrier, world)
        case Step.detaching: return detach(directive, carrier, world)
        case Step.confirmingDetach: return confirmDetach(directive, carrier, world)
        case Step.adopting, Step.confirmingAdopt, Step.arming, Step.confirmingArm:
            return .wait
        default:
            logger.notice("mine run \(directive.id, privacy: .public): unknown step \(directive.step, privacy: .public) — waiting")
            return .wait
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
                    $0.deviceType == type && $0.hasTag(MineRecipe.fleetTag)
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

    // MARK: - Steps

    /// Prove the belt is commandable and the fleet is whole before spending the
    /// carrier on the trip.
    private func preflight(
        _ directive: Directive, _ carrier: Device, _ world: WorldSnapshot
    ) -> MissionAction {
        guard let belt = Self.targetBelt(of: directive) else { return .stall(.unreachableDevice) }
        let rows = Array(world.devices.values)
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
        if MineRecipe.installedBelts(in: rows, hub: RelayRun.hubLocation(in: world)).contains(belt) {
            return .done
        }
        return .advanceStep(nextStep: Step.attaching)
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
            return .advanceStep(nextStep: Step.travelling)
        }
        return .dispatch(
            kind: .attach, deviceCode: carrier.deviceCode,
            params: CommandParams(devices: [next.deviceCode]), nextStep: Step.confirmingAttach
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
        guard let next = loose.first else { return .advanceStep(nextStep: Step.attaching) }
        let rounds = MissionLogBudget.dispatchRounds(
            world, dispatch: Step.attaching, confirm: Step.confirmingAttach
        )
        if roster.count - loose.count >= rounds { return .advanceStep(nextStep: Step.attaching) }
        return Self.confirmLadder(
            [next], directive, world,
            deadline: Self.attachConfirmDeadline, thenStall: .commandRejected
        )
    }

    /// Fly the loaded carrier to the belt.
    private func travel(
        _ directive: Directive, _ carrier: Device, _ world: WorldSnapshot
    ) -> MissionAction {
        guard let belt = Self.targetBelt(of: directive) else { return .stall(.unreachableDevice) }
        if carrier.location == belt { return .advanceStep(nextStep: Step.detaching) }
        if world.openOperation(for: carrier.deviceCode) != nil { return .wait }
        // The equality check above misreads a row still lagging an arrival.
        if let unconfirmed = SalvageRun.travelPositionUnconfirmed(carrier, world) { return unconfirmed }
        return .dispatch(
            kind: .travel, deviceCode: carrier.deviceCode,
            params: CommandParams(destination: belt), nextStep: Step.confirmingArrival
        )
    }

    /// Judge the flight: the carrier's own row, read since the travel was
    /// ordered, has to place it at the belt.
    private func confirmArrival(
        _ directive: Directive, _ carrier: Device, _ world: WorldSnapshot
    ) -> MissionAction {
        guard let belt = Self.targetBelt(of: directive) else { return .stall(.unreachableDevice) }
        if carrier.updatedAt >= directive.stepStartedAt, carrier.location == belt {
            return .advanceStep(nextStep: Step.detaching)
        }
        if world.openOperation(for: carrier.deviceCode) != nil { return .wait }
        return Self.confirmLadder(
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
        guard !aboard.isEmpty else { return .advanceStep(nextStep: Step.adopting) }
        return .dispatch(
            kind: .detach, deviceCode: carrier.deviceCode,
            params: CommandParams(devices: aboard.map(\.deviceCode)), nextStep: Step.confirmingDetach
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
            $0.updatedAt >= directive.stepStartedAt
                && $0.attachedToDeviceCode == nil && $0.location == belt
        }
        if landed { return .advanceStep(nextStep: Step.adopting) }
        return Self.confirmLadder(
            roster, directive, world,
            deadline: Self.attachConfirmDeadline, thenStall: .commandRejected
        )
    }

    // MARK: - Confirming reads

    /// The ladder every confirm step ends with. The deadline is read FIRST: a
    /// failing read never advances `updatedAt`, so the other order loops forever
    /// at one high-priority read per tick.
    private static func confirmLadder(
        _ rows: [Device], _ directive: Directive, _ world: WorldSnapshot,
        deadline: TimeInterval, thenStall: DirectiveAttentionReason
    ) -> MissionAction {
        let codes = rows.map(\.deviceCode)
        if world.now.timeIntervalSince(directive.stepStartedAt) > deadline {
            return .refreshDevices(deviceCodes: codes, thenStall: thenStall)
        }
        guard rows.contains(where: { $0.updatedAt < directive.stepStartedAt }) else { return .wait }
        let lastLook = rows.map(\.updatedAt).min() ?? .distantPast
        if world.now.timeIntervalSince(lastLook) > Self.confirmReadInterval {
            return .refreshDevices(deviceCodes: codes, thenStall: nil)
        }
        return .wait
    }
}
