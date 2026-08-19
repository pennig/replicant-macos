//
//  MineFleetPrint.swift
//  Replicould — DirectiveEngine
//
//  Prints the `MineRecipe` fleet one job per tick at the hub owning the row.
//

import Foundation
import GameModels
import GameServices
import OSLog
import UniverseModels
import Utils

private let logger = Logger(subsystem: "name.pennig.replicould", category: "DirectiveEngine")

public struct MineFleetPrint: MissionStepMachine {
    public let kind = DirectiveKind.mineFleetPrint

    /// The reserve rail, injected exactly as `RelayRun` and `RestockRun` inject
    /// it so the three cannot disagree about what "too poor to print" means.
    public let reserveFloor: Int?

    public init(reserveFloor: Int? = BrainCeiling.aggregateSpendFloor) {
        self.reserveFloor = reserveFloor
    }

    /// This mission's step vocabulary, as `Directive.step` holds it (D6).
    public enum Step: String, CaseIterable, Sendable {
        /// Decide what the fleet is missing, and start one print if anything is.
        case stocking
        /// Wait for the printed devices to become rows.
        case printing
    }

    public var firstStep: String { Step.stocking.rawValue }

    /// Route `directive`'s current step against `world`. Stalls only when no
    /// printer stands at the run's depot at all — every bench busy is the
    /// system working, and `stocking`/`printing` wait on it instead.
    public func nextAction(directive: Directive, world: WorldSnapshot) -> MissionAction {
        guard let depot = PrintJob.depot(for: directive, in: world) else {
            return .stall(.unreachableDevice)
        }
        let ctx = StepContext(directive: directive, world: world, step: directive.step)
        guard PrintJob(depot: depot).hasBench(ctx) else { return .stall(.unreachableDevice) }
        guard let step = Step(rawValue: directive.step) else {
            logger.notice("\(kind.rawValue, privacy: .public) \(directive.id, privacy: .public): unknown step \(directive.step, privacy: .public) — waiting")
            return .wait
        }
        switch step {
        case .printing: return printing(directive, depot, world)
        case .stocking: return stocking(directive, depot, world)
        }
    }

    // MARK: - Deciding

    /// Recipe slots not yet standing free at `location`, plus the carrier slot
    /// whenever `MineRecipe.idleCarrier` — the launcher's own query — finds none.
    static func remaining(at location: String, in world: WorldSnapshot) -> [String: Int] {
        var missing = MineRecipe.shortfall(at: location, in: world.devices.values)
        if MineRecipe.idleCarrier(at: location, in: world.devices.values) == nil {
            missing[MineRecipe.carrierDeviceType] = 1
        }
        return missing
    }

    /// The order jobs are dispatched in: recipe order, with the carrier last —
    /// the fleet it carries is worth printing before the vehicle stands idle.
    private static var jobOrder: [String] {
        MineRecipe.all.map(\.deviceType) + [MineRecipe.carrierDeviceType]
    }

    /// Start one print per missing type, netted against `PrintScheduler.onOrder`
    /// first so a type already ordered elsewhere is never ordered twice. A busy
    /// bench holds via `printing` rather than stalling.
    private func stocking(_ directive: Directive, _ depot: String, _ world: WorldSnapshot) -> MissionAction {
        var missing = Self.remaining(at: depot, in: world)
        for (type, onOrder) in PrintScheduler.onOrder(for: directive.id, at: depot, in: world) {
            guard let count = missing[type] else { continue }
            missing[type] = count > onOrder ? count - onOrder : nil
        }
        if missing.isEmpty { return .done }

        guard let type = Self.jobOrder.first(where: { missing[$0] != nil }),
              let quantity = missing[type]
        else { return .wait }
        let tag = type == MineRecipe.carrierDeviceType ? MineRecipe.carrierTag : MineRecipe.fleetTag

        let job = PrintOrder(deviceType: type, quantity: quantity, tags: [tag], owner: directive.id)
        guard let chosen = PrintScheduler.choose(job, at: depot, in: world) else {
            return .advanceStep(nextStep: Step.printing.rawValue)
        }

        // The rail, held once in `PrintRail` so no print site can drift from it.
        // Nothing polls `LocationFootprint`, so a stale census buys its own read.
        let rail = PrintRail(reserveFloor: reserveFloor)
        if rail.footprintCensusIsStale(world) {
            return .refreshFootprint(nextStep: Step.stocking.rawValue, thenStall: nil)
        }
        if rail.printStockIsShort(at: depot, world) { return .wait }

        // Last moment before an irreversible spend, and the one read that can
        // settle it: a clone is PRESENT at the hub, so one scoped sweep sees it.
        if PrintJob.fleetEvidenceIsStale(directive, at: depot, in: world) {
            return .refreshDevicesInSystem(designation: depot, thenStall: .unreachableDevice)
        }

        logger.info(
            """
            mine fleet print \(directive.id, privacy: .public): printing \
            \(quantity, privacy: .public) × \(type, privacy: .public) at \
            \(depot, privacy: .public)
            """
        )
        return .dispatch(
            kind: .print, deviceCode: chosen.device.deviceCode,
            params: CommandParams(deviceType: type, quantity: quantity, printTags: [tag.string]),
            nextStep: Step.stocking.rawValue
        )
    }

    // MARK: - Holding the deadline

    /// The fan-out happens in `stocking`, which re-enters itself; this step
    /// exists only to hold a deadline while a busy bench or a landing clone
    /// leaves nothing else to decide.
    private func printing(_ directive: Directive, _ depot: String, _ world: WorldSnapshot) -> MissionAction {
        if Self.remaining(at: depot, in: world).isEmpty {
            return .advanceStep(nextStep: Step.stocking.rawValue)
        }
        // A bench is shared and `openOperation` is keyed by device alone, so gating
        // the deadline on one lets a co-tenant's print park this run past it.
        if world.now.timeIntervalSince(directive.stepStartedAt) <= PrintJob.deadline {
            return .wait
        }
        logger.notice("mine fleet print \(directive.id, privacy: .public): print produced nothing within the deadline — re-deciding")
        return .advanceStep(nextStep: Step.stocking.rawValue)
    }

    /// The print run never roams: it plans no targets, so `context` is unread.
    public func plan(_ context: RoamContext) -> RoamPlan { .exhausted }
}
