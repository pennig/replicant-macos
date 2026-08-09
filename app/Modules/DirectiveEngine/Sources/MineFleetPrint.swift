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

    /// Route `directive`'s current step against `world`. Stalls when the hub row
    /// `directive.deviceCode` names has left the fleet — substituting another
    /// printer would be a fabrication.
    public func nextAction(directive: Directive, world: WorldSnapshot) -> MissionAction {
        guard let hub = world.device(directive.deviceCode) else {
            return .stall(.unreachableDevice)
        }
        switch directive.step {
        case Step.printing: return printing(directive, hub, world)
        default: return stocking(directive, hub, world)
        }
    }

    // MARK: - Deciding

    /// Recipe slots not yet standing free at `location`, plus the carrier slot
    /// when no carrier — tagged or not — is idle there to fly the fleet out.
    static func remaining(at location: String, in world: WorldSnapshot) -> [String: Int] {
        var missing = MineRecipe.shortfall(at: location, in: world.devices.values)
        guard MineRecipe.idleCarrier(at: location, in: world.devices.values) == nil else {
            return missing
        }
        let spare = world.devices.values.contains {
            $0.deviceType == MineRecipe.carrierDeviceType
                && !$0.hasTag(MineRecipe.carrierTag)
                && $0.location == location && $0.status == "idle"
        }
        if !spare { missing[MineRecipe.carrierDeviceType] = 1 }
        return missing
    }

    /// The order jobs are dispatched in: recipe order, with the carrier last —
    /// the fleet it carries is worth printing before the vehicle stands idle.
    private static var jobOrder: [String] {
        MineRecipe.all.map(\.deviceType) + [MineRecipe.carrierDeviceType]
    }

    /// Start one print at `hub`'s location, or decline. **Every declining branch
    /// is a `.wait`, never a `.stall`** — short stock idles against a hub buffer
    /// that refills from salvage. The one stall is a hub with no location.
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

    /// Wait for the printed rows to appear at `hub`'s location, then hand back to
    /// `stocking`. Count-based, so a superseded print op cannot strand it: any row
    /// filling a recipe slot counts, whichever job produced it.
    private func printing(_ directive: Directive, _ hub: Device, _ world: WorldSnapshot) -> MissionAction {
        guard let location = hub.location else { return .stall(.unreachableDevice) }
        if Self.remaining(at: location, in: world).isEmpty {
            return .advanceStep(nextStep: Step.stocking)
        }
        if world.openOperation(for: hub.deviceCode) != nil { return .wait }
        // No open op and slots still empty: the clone landed and the shortfall
        // moved, or the print failed — either way, re-decide.
        if world.now.timeIntervalSince(directive.stepStartedAt) > RestockRun.printDeadline {
            logger.notice("mine fleet print \(directive.id, privacy: .public): print produced nothing within the deadline — re-deciding")
        }
        return .advanceStep(nextStep: Step.stocking)
    }

    /// The print run never roams: it plans no targets, so `context` is unread.
    public func plan(_ context: RoamContext) -> RoamPlan { .exhausted }
}
