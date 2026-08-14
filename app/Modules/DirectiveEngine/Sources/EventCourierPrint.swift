//
//  EventCourierPrint.swift
//  Replicould — DirectiveEngine
//
//  Stands up the event convoy's replicant courier at the theatre depot.
//

import Foundation
import GameModels
import GameServices
import OSLog

private let logger = Logger(subsystem: "name.pennig.replicould", category: "DirectiveEngine")

public struct EventCourierPrint: MissionStepMachine {
    public let kind = DirectiveKind.eventCourierPrint
    public let reserveFloor: Int?

    public init(reserveFloor: Int? = BrainCeiling.aggregateSpendFloor) {
        self.reserveFloor = reserveFloor
    }

    public enum Step {
        public static let printing = "printing"
        public static let awaitingClone = "awaitingClone"
        public static let replicating = "replicating"
        public static let stowing = "stowing"
        public static let confirmingStow = "confirmingStow"
    }

    /// How long `stowing` waits for a replicant to appear before handing back to
    /// `replicating`, which stalls for the operator.
    public static let replicateDeadline: TimeInterval = 5 * 60
    /// How long `confirmingStow` waits for the matrix to read as aboard.
    public static let stowConfirmDeadline: TimeInterval = 5 * 60

    public var firstStep: String { Step.printing }

    /// A courier is a container at `depot` that hosts a replicant.
    public static func courierStands(at depot: String, in world: WorldSnapshot) -> Bool {
        world.devices.values.contains {
            $0.deviceType == EventRun.courierDeviceType && $0.location == depot
                && world.replicantHostDevices.contains($0.deviceCode)
        }
    }

    /// The one device that may still replicate. A matrix loses the `matrix`
    /// feature once used, and the verb with it, so the command list is the test.
    public static func replicationSource(in world: WorldSnapshot) -> Device? {
        world.devices.values
            .filter { $0.features.contains("matrix") && $0.availableCommands.contains("replicate") }
            .sorted { $0.deviceCode < $1.deviceCode }
            .first
    }

    public func nextAction(directive: Directive, world: WorldSnapshot) -> MissionAction {
        guard let depot = world.theatreDepot(for: directive) else { return .stall(.unreachableDevice) }
        if Self.courierStands(at: depot, in: world) { return .done }

        switch directive.step {
        case Step.awaitingClone: return awaitingClone(directive, depot, world)
        case Step.replicating: return replicating(directive, depot, world)
        case Step.stowing: return stowing(directive, depot, world)
        case Step.confirmingStow: return confirmingStow(directive, depot, world)
        default: return printing(directive, depot, world)
        }
    }

    private func container(at depot: String, in world: WorldSnapshot) -> Device? {
        world.devices.values
            .filter { $0.deviceType == EventRun.courierDeviceType && $0.location == depot }
            .min { $0.deviceCode < $1.deviceCode }
    }

    /// The freshly-replicated host still standing outside `box` — what `stowing`
    /// loads. The box itself is excluded: nothing stows into itself.
    private func loadable(into box: Device, in world: WorldSnapshot) -> Device? {
        world.devices.values
            .filter {
                world.replicantHostDevices.contains($0.deviceCode)
                    && $0.deviceCode != box.deviceCode
                    && $0.stowedInDeviceCode != box.deviceCode
            }
            .min { $0.deviceCode < $1.deviceCode }
    }

    private func printing(
        _ directive: Directive, _ depot: String, _ world: WorldSnapshot
    ) -> MissionAction {
        if container(at: depot, in: world) != nil {
            return .advanceStep(nextStep: Step.replicating)
        }
        guard let printer = world.device(directive.deviceCode) else { return .stall(.unreachableDevice) }
        if world.openOperation(for: printer.deviceCode) != nil { return .wait }
        let rail = RelayRun(reserveFloor: reserveFloor)
        if rail.footprintCensusIsStale(world) {
            return .refreshFootprint(nextStep: Step.printing, thenStall: nil)
        }
        if rail.printStockIsShort(at: depot, world) { return .wait }
        if MineFleetPrint.fleetEvidenceIsStale(directive, at: depot, in: world) {
            return .refreshDevicesInSystem(designation: depot, thenStall: .unreachableDevice)
        }
        logger.info(
            """
            event courier print \(directive.id, privacy: .public): printing a courier at \
            \(depot, privacy: .public)
            """
        )
        return .dispatch(
            kind: .print, deviceCode: printer.deviceCode,
            params: CommandParams(
                deviceType: EventRun.courierDeviceType, quantity: 1, printTags: [EventRun.rootTag]
            ),
            nextStep: Step.awaitingClone
        )
    }

    private func awaitingClone(
        _ directive: Directive, _ depot: String, _ world: WorldSnapshot
    ) -> MissionAction {
        if container(at: depot, in: world) != nil { return .advanceStep(nextStep: Step.replicating) }
        if world.openOperation(for: directive.deviceCode) != nil { return .wait }
        if world.now.timeIntervalSince(directive.stepStartedAt) <= RestockRun.printDeadline {
            return .wait
        }
        return .advanceStep(nextStep: Step.printing)
    }

    /// Hand the one replication to the operator. It is irreversible and happens
    /// once per courier, ever, so the engine asks rather than dispatches; the
    /// run resumes here the moment a replicant stands outside the container.
    private func replicating(
        _ directive: Directive, _ depot: String, _ world: WorldSnapshot
    ) -> MissionAction {
        guard let box = container(at: depot, in: world) else {
            return .advanceStep(nextStep: Step.printing)
        }
        if loadable(into: box, in: world) != nil {
            return .advanceStep(nextStep: Step.stowing)
        }
        guard Self.replicationSource(in: world) != nil else {
            return .stall(.unreachableDevice, detail: "no empty replicant matrix at \(depot)")
        }
        return .stall(.awaitingCourierReplication, detail: depot)
    }

    /// Load the new replicant's matrix into the container. Hands back to
    /// `replicating` once the deadline proves no replicant arrived, which
    /// surfaces the ask rather than waiting on it forever.
    private func stowing(
        _ directive: Directive, _ depot: String, _ world: WorldSnapshot
    ) -> MissionAction {
        guard let box = container(at: depot, in: world) else {
            return .advanceStep(nextStep: Step.printing)
        }
        guard let matrix = loadable(into: box, in: world) else {
            if world.now.timeIntervalSince(directive.stepStartedAt) <= Self.replicateDeadline {
                return .wait
            }
            logger.notice("event courier print \(directive.id, privacy: .public): no replicant to stow within the deadline — re-deciding")
            return .advanceStep(nextStep: Step.replicating)
        }
        return .dispatch(
            kind: .stow, deviceCode: matrix.deviceCode,
            params: CommandParams(target: box.deviceCode), nextStep: Step.confirmingStow
        )
    }

    /// Judge the stow on the rows it moved. `stow` is immediate and untracked,
    /// so this step's deadline is the only bound on one the server refused; the
    /// success exit is `courierStands`, which `nextAction` checks first.
    private func confirmingStow(
        _ directive: Directive, _ depot: String, _ world: WorldSnapshot
    ) -> MissionAction {
        guard let box = container(at: depot, in: world) else {
            return .advanceStep(nextStep: Step.printing)
        }
        let subject = loadable(into: box, in: world) ?? box
        return MissionConfirm.ladder(
            [subject], directive, world,
            deadline: Self.stowConfirmDeadline, thenStall: .commandRejected
        )
    }

    public func plan(_ context: RoamContext) -> RoamPlan { .exhausted }
}
