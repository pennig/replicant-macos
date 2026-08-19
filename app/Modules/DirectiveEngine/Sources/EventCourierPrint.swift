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

    public enum Step: String, CaseIterable, Sendable {
        case printing
        case awaitingClone
        case replicating
    }

    public var firstStep: String { Step.printing.rawValue }

    /// A courier of ours standing at `depot`, by the one predicate `EventRun`
    /// also selects on — so what this reports ready is what a convoy can fly.
    /// Resolved through its host: a courier home aboard a carrier is home.
    public static func courierStands(at depot: String, in world: WorldSnapshot) -> Bool {
        world.devices.values.contains {
            EventRun.isCourier($0, in: world)
                && EventRun.standingLocation(of: $0, in: world) == depot
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

        guard let step = Step(rawValue: directive.step) else {
            logger.notice("\(kind.rawValue, privacy: .public) \(directive.id, privacy: .public): unknown step \(directive.step, privacy: .public) — waiting")
            return .wait
        }
        switch step {
        case .awaitingClone: return awaitingClone(directive, depot, world)
        case .replicating: return replicating(directive, depot, world)
        case .printing: return printing(directive, depot, world)
        }
    }

    /// Only a container carrying this run's own print tag: replicating into
    /// another automation's would produce a host `courierStands` never accepts.
    private func container(at depot: String, in world: WorldSnapshot) -> Device? {
        world.devices.values
            .filter { EventRun.isCourierHull($0) && $0.location == depot }
            .min { $0.deviceCode < $1.deviceCode }
    }

    /// A busy bench waits; no bench at all stalls — the same split every
    /// print site makes.
    private func printing(
        _ directive: Directive, _ depot: String, _ world: WorldSnapshot
    ) -> MissionAction {
        if container(at: depot, in: world) != nil {
            return .advanceStep(nextStep: Step.replicating.rawValue)
        }
        let ctx = StepContext(directive: directive, world: world, step: directive.step)
        guard PrintJob(depot: depot).hasBench(ctx) else { return .stall(.unreachableDevice) }
        let order = PrintOrder(
            deviceType: EventRun.courierDeviceType, quantity: 1, tags: [EventRun.rootTag],
            owner: directive.id
        )
        guard let printer = PrintJob(depot: depot).bench(ctx, for: order) else { return .wait }
        let rail = PrintRail(reserveFloor: reserveFloor)
        if rail.footprintCensusIsStale(world) {
            return .refreshFootprint(nextStep: Step.printing.rawValue, thenStall: nil)
        }
        if rail.printStockIsShort(at: depot, world) { return .wait }
        if PrintJob.fleetEvidenceIsStale(directive, at: depot, in: world) {
            return .refreshDevicesInSystem(designation: depot, thenStall: .unreachableDevice)
        }
        logger.info(
            """
            event courier print \(directive.id, privacy: .public): printing a courier at \
            \(depot, privacy: .public)
            """
        )
        return .dispatch(
            kind: .print, deviceCode: printer.device.deviceCode,
            params: CommandParams(
                deviceType: EventRun.courierDeviceType, quantity: 1, printTags: [EventRun.rootTag.string]
            ),
            nextStep: Step.awaitingClone.rawValue
        )
    }

    private func awaitingClone(
        _ directive: Directive, _ depot: String, _ world: WorldSnapshot
    ) -> MissionAction {
        if container(at: depot, in: world) != nil { return .advanceStep(nextStep: Step.replicating.rawValue) }
        if world.now.timeIntervalSince(directive.stepStartedAt) > PrintJob.deadline {
            return .advanceStep(nextStep: Step.printing.rawValue)
        }
        // Substitution may have put the job on a bench the launch pin does not
        // name, so the ops table answers this, not the bench chooser.
        let ctx = StepContext(directive: directive, world: world, step: directive.step)
        if PrintJob(depot: depot).stillPrinting(ctx) { return .wait }
        return .advanceStep(nextStep: Step.printing.rawValue)
    }

    /// Hand the one replication to the operator: it is irreversible, happens
    /// once per courier ever, and the container is itself the cradle to
    /// replicate into. `courierStands` is the only exit.
    private func replicating(
        _ directive: Directive, _ depot: String, _ world: WorldSnapshot
    ) -> MissionAction {
        guard container(at: depot, in: world) != nil else {
            return .advanceStep(nextStep: Step.printing.rawValue)
        }
        guard Self.replicationSource(in: world) != nil else {
            return .stall(.unreachableDevice, detail: "no empty replicant matrix at \(depot)")
        }
        return .stall(.awaitingCourierReplication, detail: depot)
    }

    public func plan(_ context: RoamContext) -> RoamPlan { .exhausted }
}
