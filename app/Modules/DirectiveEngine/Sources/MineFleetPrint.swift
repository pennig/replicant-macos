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

    /// This mission's step vocabulary, as the bare strings `Directive.step` holds.
    public enum Step {
        /// Decide what the fleet is missing, and start one print if anything is.
        public static let stocking = "stocking"
        /// Wait for the printed devices to become rows.
        public static let printing = "printing"
    }

    public var firstStep: String { Step.stocking }

    /// Route `directive`'s current step against `world`. Stalls when no printer at
    /// the run's depot can take a job — printing somewhere else would be a
    /// fabrication, but printing at the same bench with a free hub is not.
    public func nextAction(directive: Directive, world: WorldSnapshot) -> MissionAction {
        guard let hub = Self.printer(for: directive, in: world) else {
            return .stall(.unreachableDevice)
        }
        switch directive.step {
        case Step.printing: return printing(directive, hub, world)
        default: return stocking(directive, hub, world)
        }
    }

    /// The hub to print with: the row's own while it still accepts jobs, else the
    /// lowest-coded able hub at the same depot. A hub keeps advertising
    /// `enqueue_print` while packed or under way, so only status separates them.
    static func printer(for directive: Directive, in world: WorldSnapshot) -> Device? {
        let pinned = world.device(directive.deviceCode)
        guard let depot = directive.theatreDepot ?? pinned?.location else { return nil }
        if let pinned, pinned.acceptsPrintJobs, pinned.location == depot { return pinned }
        return world.devices.values
            .filter { $0.acceptsPrintJobs && $0.location == depot && !$0.isCarrierHull }
            .min { $0.deviceCode < $1.deviceCode }
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

    /// Whether every row `remaining(at:)` judges predates this step. `printing`
    /// hands back only once the print op has closed, so such rows are rows from
    /// before the clone landed — and a landed clone reads as an empty slot.
    static func fleetEvidenceIsStale(
        _ directive: Directive, at location: String, in world: WorldSnapshot
    ) -> Bool {
        let newest = world.devices.values
            .filter { $0.location == location }
            .map(\.updatedAt)
            .max()
        guard let newest else { return true }
        return newest < directive.stepStartedAt
    }

    /// Start one print at `hub`'s location, or decline. Short stock idles against a
    /// hub buffer that refills from salvage; only an unreadable hub — gone from the
    /// fleet, without a location, or a sweep that will not land — escalates.
    private func stocking(_ directive: Directive, _ hub: Device, _ world: WorldSnapshot) -> MissionAction {
        guard let location = hub.location else { return .stall(.unreachableDevice) }

        let missing = Self.remaining(at: location, in: world)
        if missing.isEmpty { return .done }

        // One print in flight at a time: `CommandClient` supersedes any other
        // open op on a device, so a second dispatch orphans the first's row.
        if world.openOperation(for: hub.deviceCode) != nil { return .wait }

        // The rail, read through `RelayRun`'s own veto so the two cannot drift.
        // Nothing polls `LocationFootprint`, so a stale census buys its own read.
        let rail = RelayRun(reserveFloor: reserveFloor)
        if rail.footprintCensusIsStale(world) {
            return .refreshFootprint(nextStep: Step.stocking, thenStall: nil)
        }
        if rail.printStockIsShort(at: location, world) { return .wait }

        // Last moment before an irreversible spend, and the one read that can
        // settle it: a clone is PRESENT at the hub, so one scoped sweep sees it.
        if Self.fleetEvidenceIsStale(directive, at: location, in: world) {
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
            params: CommandParams(deviceType: type, quantity: quantity, printTags: [tag]),
            nextStep: Step.printing
        )
    }

    // MARK: - Waiting on the clones

    /// Wait for the printed rows to appear at `hub`'s location. A multi-quantity
    /// job may settle one op per clone, so only a full fleet or the deadline hands
    /// back to `stocking` — an op-close proves nothing about the rows.
    private func printing(_ directive: Directive, _ hub: Device, _ world: WorldSnapshot) -> MissionAction {
        guard let location = hub.location else { return .stall(.unreachableDevice) }
        if Self.remaining(at: location, in: world).isEmpty {
            return .advanceStep(nextStep: Step.stocking)
        }
        if world.openOperation(for: hub.deviceCode) != nil { return .wait }
        if world.now.timeIntervalSince(directive.stepStartedAt) <= RestockRun.printDeadline {
            return .wait
        }
        logger.notice("mine fleet print \(directive.id, privacy: .public): print produced nothing within the deadline — re-deciding")
        return .advanceStep(nextStep: Step.stocking)
    }

    /// The print run never roams: it plans no targets, so `context` is unread.
    public func plan(_ context: RoamContext) -> RoamPlan { .exhausted }
}
