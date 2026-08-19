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

    /// Route `directive`'s current step against `world`. Stalls when no printer at
    /// the run's depot can take a job — printing somewhere else would be a
    /// fabrication, but printing at the same bench with a free hub is not.
    public func nextAction(directive: Directive, world: WorldSnapshot) -> MissionAction {
        guard let depot = PrintJob.depot(for: directive, in: world),
              let hub = PrintJob(depot: depot).bench(
                  StepContext(directive: directive, world: world, step: directive.step)
              )
        else { return .stall(.unreachableDevice) }
        guard let step = Step(rawValue: directive.step) else {
            logger.notice("\(kind.rawValue, privacy: .public) \(directive.id, privacy: .public): unknown step \(directive.step, privacy: .public) — waiting")
            return .wait
        }
        switch step {
        case .printing: return printing(directive, hub, world)
        case .stocking: return stocking(directive, hub, world)
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

    /// Start one print at `hub`'s location, or decline. Short stock idles against a
    /// hub buffer that refills from salvage; only an unreadable hub — gone from the
    /// fleet, without a location, or a sweep that will not land — escalates.
    private func stocking(_ directive: Directive, _ hub: Device, _ world: WorldSnapshot) -> MissionAction {
        guard let location = hub.location else { return .stall(.unreachableDevice) }

        let missing = Self.remaining(at: location, in: world)
        if missing.isEmpty { return .done }

        // A correctness guard against orphaning our own open op, not a
        // throttle — owner-scoped, so a co-tenant's job here is never ours to wait on.
        if world.openOperation(for: hub.deviceCode, owner: directive.id) != nil { return .wait }

        // The rail, held once in `PrintRail` so no print site can drift from it.
        // Nothing polls `LocationFootprint`, so a stale census buys its own read.
        let rail = PrintRail(reserveFloor: reserveFloor)
        if rail.footprintCensusIsStale(world) {
            return .refreshFootprint(nextStep: Step.stocking.rawValue, thenStall: nil)
        }
        if rail.printStockIsShort(at: location, world) { return .wait }

        // Last moment before an irreversible spend, and the one read that can
        // settle it: a clone is PRESENT at the hub, so one scoped sweep sees it.
        if PrintJob.fleetEvidenceIsStale(directive, at: location, in: world) {
            return .refreshDevicesInSystem(designation: location, thenStall: .unreachableDevice)
        }

        guard let type = Self.jobOrder.first(where: { missing[$0] != nil }),
              let quantity = missing[type]
        else { return .wait }

        let tag = type == MineRecipe.carrierDeviceType ? MineRecipe.carrierTag : MineRecipe.fleetTag
        logger.info(
            """
            mine fleet print \(directive.id, privacy: .public): printing \
            \(quantity, privacy: .public) × \(type, privacy: .public) at \
            \(location, privacy: .public)
            """
        )
        return .dispatch(
            kind: .print, deviceCode: hub.deviceCode,
            params: CommandParams(deviceType: type, quantity: quantity, printTags: [tag.string]),
            nextStep: Step.printing.rawValue
        )
    }

    // MARK: - Waiting on the clones

    /// Wait for the printed rows to appear at `hub`'s location. A multi-quantity
    /// job may settle one op per clone, so only a full fleet or the deadline hands
    /// back to `stocking` — an op-close proves nothing about the rows.
    private func printing(_ directive: Directive, _ hub: Device, _ world: WorldSnapshot) -> MissionAction {
        guard let location = hub.location else { return .stall(.unreachableDevice) }
        if Self.remaining(at: location, in: world).isEmpty {
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
