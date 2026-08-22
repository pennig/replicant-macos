//
//  RestockRun.swift
//  Replicould — DirectiveEngine
//
//  Keeps idle FTL relays standing at the print hub, ahead of demand: something
//  has to PUT spares in the Relay Run pool (`RelayRun.idleRelays`), or it only
//  drains and every run pays a print's wait before it can leave.
//
//  **Owned by the HUB device, not a carrier.** The hub's print queue is shared
//  and never leased, so holding the autofactory in a directive costs the fleet
//  no capacity — no carrier, no drone, nothing another mission wants.
//
//  **Persistent.** It idles rather than completing, so an operator sees and
//  cancels one row instead of a directive per relay.
//

import Foundation
import GameModels
import GameServices
import OSLog
import UniverseModels
import Utils

private let logger = Logger(subsystem: "name.pennig.replicould", category: "DirectiveEngine")

public struct RestockRun: MissionStepMachine {
    public let kind = DirectiveKind.restockRun

    /// The reserve rail, injected exactly as `RelayRun` injects it so the two
    /// cannot disagree about what "too poor to print" means.
    public let reserveFloors: [String: Double]?

    /// Build a run whose print veto reads `reserveFloors`, the rail's per-type
    /// stock floor unless a caller overrides it.
    public init(reserveFloors: [String: Double]? = BrainCeiling.reserveFloors) {
        self.reserveFloors = reserveFloors
    }

    /// This mission's step vocabulary, as `Directive.step` holds it (D6).
    public enum Step: String, CaseIterable, Sendable {
        /// Decide whether to print, and start one if so.
        case stocking
        /// Wait for the clone to become a device row.
        case printing
    }

    public var firstStep: String { Step.stocking.rawValue }

    /// The most idle relays this will leave parked at the hub, per bench.
    public static let idlePerBench = 3

    /// The absolute ceiling, whatever the bench count: capital held as
    /// inventory, never a throughput throttle.
    public static let idleCap = 10

    /// Route `directive`'s current step against `world`. Stalls only when no
    /// hub stands at the run's depot at all — printing somewhere else would
    /// be a fabrication. Every bench busy is a wait, not a stall.
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

    /// Print one relay at `depot`, or decline. Demand nets `idle` against what
    /// is already `onOrder`, so a bench substitution never buys a second relay.
    /// A bench at capacity advances to `printing` to wait, rather than stalling.
    private func stocking(_ directive: Directive, _ depot: String, _ world: WorldSnapshot) -> MissionAction {
        let idle = RelayRun.idleRelays(at: depot, in: world).count
        let onOrder = PrintScheduler.onOrder(for: directive.id, at: depot, in: world)[RelayRun.relayDeviceType] ?? 0
        let benches = PrintScheduler.benches(at: depot, in: world).count
        let desired = Self.desiredIdle(for: directive, benches: benches)
        guard idle + onOrder < desired else { return .wait }

        let order = PrintOrder(deviceType: RelayRun.relayDeviceType, owner: directive.id)
        guard let hub = PrintScheduler.choose(order, at: depot, in: world) else {
            return .advanceStep(nextStep: Step.printing.rawValue)
        }

        // A stale census buys a refresh rather than waiting it out: the only
        // production poll of `LocationInventory` is hourly, far past the rail's
        // own freshness bound, so waiting would confine printing to whatever
        // window that sweep happens to leave open.
        //
        // `thenStall: nil` because restock must never escalate a top-up nobody
        // is waiting on — the price is one census read per tick while demand
        // is unmet.
        let rail = PrintRail(reserveFloors: reserveFloors)
        if rail.stockCensusIsStale(world) {
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
            restock \(directive.id, privacy: .public): printing a relay at \
            \(depot, privacy: .public) — \(idle, privacy: .public) idle of \
            \(desired, privacy: .public) wanted
            """
        )
        return .dispatch(
            kind: .print, deviceCode: hub.device.deviceCode,
            params: CommandParams(deviceType: RelayRun.relayDeviceType),
            nextStep: Step.stocking.rawValue
        )
    }

    /// How many idle relays the hub should hold for `directive`: its own
    /// `targets` count, capped at `idlePerBench` times `benches` and at
    /// `idleCap` overall.
    static func desiredIdle(for directive: Directive, benches: Int) -> Int {
        min(idleCap, idlePerBench * benches, directive.targets.count)
    }

    // MARK: - Holding the deadline

    /// The fan-out happens in `stocking`, which re-enters itself; this step
    /// exists only to hold a deadline while a busy bench or a landing clone
    /// leaves nothing else to decide.
    private func printing(_ directive: Directive, _ depot: String, _ world: WorldSnapshot) -> MissionAction {
        let benches = PrintScheduler.benches(at: depot, in: world).count
        if RelayRun.idleRelays(at: depot, in: world).count >= Self.desiredIdle(for: directive, benches: benches) {
            return .advanceStep(nextStep: Step.stocking.rawValue)
        }
        if world.now.timeIntervalSince(directive.stepStartedAt) <= PrintJob.deadline { return .wait }
        logger.notice("restock \(directive.id, privacy: .public): print produced no relay within the deadline — re-deciding")
        return .advanceStep(nextStep: Step.stocking.rawValue)
    }

    /// Restock never roams: it plans no targets, so `context` is unread.
    public func plan(_ context: RoamContext) -> RoamPlan { .exhausted }
}
