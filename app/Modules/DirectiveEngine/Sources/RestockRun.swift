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
    public let reserveFloor: Int?

    /// Build a run whose print veto reads `reserveFloor`, the rail's aggregate
    /// stock floor unless a caller overrides it.
    public init(reserveFloor: Int? = BrainCeiling.aggregateSpendFloor) {
        self.reserveFloor = reserveFloor
    }

    /// This mission's step vocabulary, as `Directive.step` holds it (D6).
    public enum Step: String, CaseIterable, Sendable {
        /// Decide whether to print, and start one if so.
        case stocking
        /// Wait for the clone to become a device row.
        case printing
    }

    public var firstStep: String { Step.stocking.rawValue }

    /// The most idle relays this will leave parked at the hub.
    ///
    /// A ceiling on capital held as inventory rather than reserve, never a
    /// throttle on throughput — demand and then the reserve floor both bind
    /// before it, so re-tuning it as a throughput knob moves nothing.
    public static let idleCap = 10

    /// Route `directive`'s current step against `world`.
    ///
    /// Stalls only when no hub stands at the run's depot at all: printing
    /// somewhere else would be a fabrication. Every bench busy is a wait.
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

    /// Print one relay at `depot`, or wait, judging `directive`'s demand against
    /// `world`'s idle pool and census.
    ///
    /// **Every branch that declines is a `.wait`, never a `.stall`** — demand
    /// met, cap reached, a busy bench, or the reserve saying not yet are all the
    /// system working, and dressing idle calm up as a halt spends an operator's
    /// attention on nothing. `nextAction` already proved `depot` has a printer.
    private func stocking(_ directive: Directive, _ depot: String, _ world: WorldSnapshot) -> MissionAction {
        let idle = RelayRun.idleRelays(at: depot, in: world).count
        let desired = Self.desiredIdle(for: directive)
        guard idle < desired else { return .wait }

        let ctx = StepContext(directive: directive, world: world, step: directive.step)
        let order = PrintOrder(deviceType: RelayRun.relayDeviceType, owner: directive.id)
        guard let hub = PrintJob(depot: depot).bench(ctx, for: order) else { return .wait }

        // The rail, held once in `PrintRail` so no print site can drift from it.
        //
        // A stale census buys a refresh rather than waiting it out, because
        // **nothing polls `LocationFootprint`** — `refreshFootprint()`'s only
        // production callers are a mission's own `.refreshFootprint` action and
        // the Locations screen — so waiting confines printing to the window
        // after some OTHER mission happens to refresh, and widening the
        // freshness bound only moves that dead line. The read is bought only
        // once every guard above has said this run wants to print, so its cost
        // tracks wanting stock rather than existing. The gate must stay
        // TABLE-WIDE: a per-location one self-loops, whereas a refresh that
        // succeeds while still omitting the hub is positive evidence and falls
        // through to the fail-closed `printStockIsShort`. `thenStall: nil`
        // because restock must never escalate a top-up nobody is waiting on —
        // the price is one census read per tick while demand is unmet.
        let rail = PrintRail(reserveFloor: reserveFloor)
        if rail.footprintCensusIsStale(world) {
            return .refreshFootprint(nextStep: Step.stocking.rawValue, thenStall: nil)
        }
        if rail.printStockIsShort(at: depot, world) { return .wait }

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
            nextStep: Step.printing.rawValue
        )
    }

    /// How many idle relays the hub should hold for `directive`: its own
    /// `targets` count, capped at `idleCap`.
    ///
    /// **Read off `targets` because the mission cannot compute demand.** Demand
    /// is a galaxy-wide judgement over `ValueCatalog`/`GrowRanking`, which run on
    /// a `WorldView`, while a mission's `WorldSnapshot` scopes `systems` and
    /// `siteAssays` to this directive's own targets — so deriving it here would
    /// only ever see what the row already names. `Brain.tendRestock` keeps the
    /// list current.
    static func desiredIdle(for directive: Directive) -> Int {
        min(idleCap, directive.targets.count)
    }

    // MARK: - Waiting on the clone

    /// Wait for a printed relay to reach `world`'s idle pool, then hand back to
    /// `stocking`. Doesn't care WHICH relay arrived, unlike `RelayRun.printing`
    /// — any relay topping the pool up survives a superseded print op.
    private func printing(_ directive: Directive, _ depot: String, _ world: WorldSnapshot) -> MissionAction {
        if RelayRun.idleRelays(at: depot, in: world).count >= Self.desiredIdle(for: directive) {
            return .advanceStep(nextStep: Step.stocking.rawValue)
        }
        if world.now.timeIntervalSince(directive.stepStartedAt) > PrintJob.deadline {
            logger.notice("restock \(directive.id, privacy: .public): print produced no relay within the deadline — re-deciding")
            return .advanceStep(nextStep: Step.stocking.rawValue)
        }
        let ctx = StepContext(directive: directive, world: world, step: directive.step)
        if PrintJob(depot: depot).stillPrinting(ctx) { return .wait }
        return .advanceStep(nextStep: Step.stocking.rawValue)
    }

    /// Restock never roams: it plans no targets, so `context` is unread.
    public func plan(_ context: RoamContext) -> RoamPlan { .exhausted }
}
