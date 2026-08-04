//
//  RestockRun.swift
//  Replicould — DirectiveEngine
//
//  Keeps idle FTL relays standing at the print hub, ahead of demand.
//
//  The Relay Run pool (see `RelayRun.idleRelays`) made a spare relay claimable
//  the moment a carrier lands. This is the other half: something has to PUT
//  spares there, or the pool only ever drains and every run pays a print's wait
//  before it can leave. Printing is the fleet's bottleneck and stays so as
//  carriers are added, so the printer should run whenever there is unmet demand
//  and the reserve allows.
//
//  **Owned by the HUB device, not a carrier.** `enqueue_print` takes a device
//  type and nothing else; the hub's queue is shared and never leased (ticket
//  05), so holding the autofactory in a directive costs the fleet no capacity —
//  no carrier, no drone, nothing that another mission wants.
//
//  **Persistent.** It idles rather than completing, the shape
//  `brain-resource-hub-model` gives the per-site Haul Run: one row an operator
//  can see and cancel, instead of a new directive per relay.
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

    public init(reserveFloor: Int? = BrainCeiling.aggregateSpendFloor) {
        self.reserveFloor = reserveFloor
    }

    public enum Step {
        /// Decide whether to print, and start one if so.
        public static let stocking = "stocking"
        /// Wait for the clone to become a device row.
        public static let printing = "printing"
    }

    public var firstStep: String { Step.stocking }

    /// The most idle relays this will leave parked at the hub.
    ///
    /// **Ten, as a practical ceiling on capital sitting in inventory rather than
    /// held as reserve** — a relay is 370 units across six types, so ten is
    /// 3,700 units parked. It is not a throttle on throughput: demand is the
    /// binding limit long before this is, and the reserve floor binds before
    /// either. It exists so that a world with dozens of reachable targets cannot
    /// turn the whole stockpile into relays nobody is flying yet.
    public static let idleCap = 10

    /// How long a print may go unclaimed before the run gives up waiting and
    /// re-decides. Matches `RelayRun.printDeadline` — the same server-side job.
    public static let printDeadline: TimeInterval = RelayRun.printDeadline

    /// How stale the census may be before a print is vetoed for lack of a
    /// trustworthy reading. Matches `RelayRun.hubFreshness`.
    public static let pollInterval: TimeInterval = RelayRun.pollInterval

    public func nextAction(directive: Directive, world: WorldSnapshot) -> MissionAction {
        guard let hub = world.device(directive.deviceCode) else {
            // The hub row is gone from the fleet. Nothing to print with, and
            // guessing at another printer would be a fabrication.
            return .stall(.unreachableDevice)
        }
        switch directive.step {
        case Step.printing: return printing(directive, hub, world)
        default: return stocking(directive, hub, world)
        }
    }

    // MARK: - Deciding

    /// Print one relay, or wait.
    ///
    /// **Every branch that declines is a `.wait`, never a `.stall`.** A restock
    /// that cannot print right now is the system working: demand is met, or the
    /// cap is reached, or the reserve says not yet. None of those need an
    /// operator, and `brain-robustness-bar` clause 6 is explicit that idle-calm
    /// must not be dressed up as a halt. The only stall here is a hub that has
    /// left the fleet.
    private func stocking(_ directive: Directive, _ hub: Device, _ world: WorldSnapshot) -> MissionAction {
        guard let location = hub.location else { return .stall(.unreachableDevice) }

        let idle = RelayRun.idleRelays(at: location, in: world).count
        let desired = Self.desiredIdle(for: directive)
        guard idle < desired else { return .wait }

        // One print in flight at a time. NOT a throttle — one autofactory prints
        // one relay at a time regardless — but a correctness guard:
        // `CommandClient` supersedes any other open op on a device, so a second
        // dispatch would silently orphan the first's row, which is exactly what
        // stranded two Relay Runs on 2026-08-04.
        if world.openOperation(for: hub.deviceCode) != nil { return .wait }

        // The rail, read through `RelayRun`'s own veto so the two cannot drift.
        // A stale census is not evidence either way, and unlike `RelayRun.acquire`
        // there is nothing here worth refreshing FOR: no carrier is waiting on
        // the answer, and the census refreshes on its own cadence. Waiting is
        // both cheaper and safer than spending a read to hurry a top-up.
        let rail = RelayRun(reserveFloor: reserveFloor)
        if rail.footprintCensusIsStale(world) { return .wait }
        if rail.printStockIsShort(at: location, world) { return .wait }

        logger.info(
            """
            restock \(directive.id, privacy: .public): printing a relay at \
            \(location, privacy: .public) — \(idle, privacy: .public) idle of \
            \(desired, privacy: .public) wanted
            """
        )
        return .dispatch(
            kind: .print, deviceCode: hub.deviceCode,
            params: CommandParams(deviceType: RelayRun.relayDeviceType),
            nextStep: Step.printing
        )
    }

    /// How many idle relays the hub should be holding: unmet demand, capped.
    ///
    /// **Demand is grow targets, not a fixed buffer** — the rule is "churn them
    /// out as long as there are targets to emplace them", so the stopping
    /// condition is the work running out.
    ///
    /// **Read off the directive's own `targets`, and it has to be.** Demand is a
    /// galaxy-wide judgement over `ValueCatalog`/`GrowRanking`, which run on a
    /// `WorldView`; a mission gets a `WorldSnapshot`, whose `systems` and
    /// `siteAssays` are deliberately SCOPED to the directive's own targets so a
    /// run never decodes the whole catalogue. So the mission cannot compute this
    /// and must be told. The brain — restock's only planner — keeps the list
    /// current (`Brain.tendRestock`), which also makes the row read honestly:
    /// the systems it lists are exactly the ones it is printing for.
    static func desiredIdle(for directive: Directive) -> Int {
        min(idleCap, directive.targets.count)
    }

    // MARK: - Waiting on the clone

    /// Wait for the printed relay to land in the fleet, then go back to
    /// deciding.
    ///
    /// **It does not care WHICH relay arrived**, unlike `RelayRun.printing`,
    /// which has to identify its own clone to fly it somewhere. This run only
    /// tops up a pool: any relay reaching the hub's idle stock satisfies it, so
    /// a superseded op — the failure that stranded two runs — cannot strand this
    /// one. It re-decides from the pool count and prints again if still short.
    private func printing(_ directive: Directive, _ hub: Device, _ world: WorldSnapshot) -> MissionAction {
        guard let location = hub.location else { return .stall(.unreachableDevice) }
        // The pool grew, or demand fell, or the cap was reached — whatever the
        // reason, there is nothing to wait for.
        if RelayRun.idleRelays(at: location, in: world).count >= Self.desiredIdle(for: directive) {
            return .advanceStep(nextStep: Step.stocking)
        }
        if world.openOperation(for: hub.deviceCode) != nil { return .wait }
        // No open op and the pool is still short: either the clone landed and
        // demand moved, or the print failed. Either way the answer is the same —
        // go back and decide again. The deadline is what stops a silent
        // never-arriving print from parking this step forever.
        if world.now.timeIntervalSince(directive.stepStartedAt) > Self.printDeadline {
            logger.notice("restock \(directive.id, privacy: .public): print produced no relay within the deadline — re-deciding")
        }
        return .advanceStep(nextStep: Step.stocking)
    }

    /// Restock never plans targets — it has none. Required by the protocol.
    public func plan(_ context: RoamContext) -> RoamPlan { .exhausted }
}
