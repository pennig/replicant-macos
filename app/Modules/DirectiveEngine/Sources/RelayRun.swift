//
//  RelayRun.swift
//  Replicould — DirectiveEngine
//
//  Grows the FTL mesh by one system: acquire a relay, stow it aboard the carrier,
//  fly to the target's Lagrange point, deploy, activate in-situ, confirm the mesh
//  grew. One-shot. Two sources converge at `stowing` — a nil `sourceRelayCode`
//  PRINTS a fresh relay, non-nil RECLAIMS the named one, and the reclaim path
//  needs a carrier hosting a replicant, gated by `carrierRetainsAuthority`.
//  Pure — time is `world.now`, every effect is the returned `MissionAction`.
//

import Foundation
import GameModels
import GameServices
import OSLog
import UniverseModels
import Utils

private let logger = Logger(subsystem: "name.pennig.replicould", category: "DirectiveEngine")

public struct RelayRun: MissionStepMachine {
    public let kind: DirectiveKind = .relayRun
    public var firstStep: String { Step.acquire.rawValue }

    /// Total-stock floor the print step checks before spending; nil leaves the rail
    /// unarmed. A PROXY for `BrainCeiling`'s per-type reserve, since
    /// `LocationFootprint` carries only a total — and NOT the sum of the six
    /// per-type floors, which undershoots badly.
    public let reserveFloor: Int?

    public init(reserveFloor: Int? = BrainCeiling.aggregateSpendFloor) {
        self.reserveFloor = reserveFloor
    }

    /// This mission's step vocabulary, as the bare strings `Directive.step` holds.
    /// The dispatch/poll pairs exist because `deactivate`, `stow`, `deploy` and
    /// `activate` carry no `Operation` row. The two sources meet at `stowing`.
    public enum Step: String, CaseIterable, Sendable {
        /// Decide where the relay comes from, and start it coming. Branches on
        /// `Directive.sourceRelayCode`: nil prints a fresh one at the hub,
        /// non-nil reclaims the existing one it names.
        case acquire
        /// Poll for the printed clone to appear in the fleet.
        case printing
        /// RECLAIM PATH. Fly the carrier to where the source relay stands,
        /// BEFORE anything irreversible happens to it. Travel is a tracked
        /// kind, so this step may re-dispatch into itself.
        case fetching
        /// RECLAIM PATH. Dispatch `deactivate` at the source relay.
        /// Dispatch-only.
        case deactivating
        /// RECLAIM PATH. Poll for the source relay to stop relaying. Split from
        /// `deactivating` because `deactivate` is classified `.immediate` by
        /// `CommandClient` and carries no `Operation` row.
        case confirmingIdle
        /// Dispatch `stow` at the relay, naming the carrier.
        case stowing
        /// Poll the relay's own `stowedInDeviceCode`. Split from `stowing`
        /// because `stow` is immediate and carries no `Operation` row.
        case confirmingStow
        /// Fly the carrier to the target system.
        case travelling
        /// Fly the last hop to the target's Lagrange point, then `deploy` the
        /// relay there.
        case emplacing
        /// Dispatch `activate` at the just-deployed relay. Dispatch-only.
        case activating
        /// Poll for `statusBase == "relaying"`, backstopped by
        /// `activationDeadline`. Split from `activating` because `activate` is
        /// immediate and carries no `Operation` row.
        case confirmingRelay
        /// Confirm the run's actual deliverable: the TARGET SYSTEM is meshed.
        case settling
        /// Fly the carrier back to the hub so the next run can use it. Entered
        /// from `settling` only when the run carries `returnToOrigin`.
        case returning
    }

    // MARK: - Constants

    /// The device type this run plants.
    public static let relayDeviceType = SalvageRun.relayDeviceType

    /// A `stow` is immediate server-side, so this only covers the confirm-read.
    public static let stowDeadline: TimeInterval = 5 * 60

    /// How long a just-deployed relay may take to come up `relaying` before the
    /// run surfaces `relayActivationFailed`.
    public static let activationDeadline: TimeInterval = 10 * 60

    /// How old the hub's row may be and still be believed. The print rail's
    /// bound, so the hub-row read and the stock veto cannot drift apart.
    public static let hubFreshness: TimeInterval = PrintRail.hubFreshness

    public static let reclaimDeadline: TimeInterval = stowDeadline

    /// How old the SOURCE relay's row may be and still authorise tearing it down.
    /// Named apart from `hubFreshness` because the two may reasonably diverge —
    /// one gates a spend that can be re-earned, this one gates a teardown.
    public static let reclaimFreshness: TimeInterval = hubFreshness

    /// Floor between confirm-reads while a poll step waits.
    public static let pollInterval: TimeInterval = PrintRail.pollInterval

    // MARK: - Entry

    /// Route `directive`'s current step against `world`, stalling if the carrier
    /// has left the fleet — it is the run's only lease, so no substitute exists.
    /// Every other device is re-derived from `world` each evaluation.
    public func nextAction(directive: Directive, world: WorldSnapshot) -> MissionAction {
        guard let carrier = world.device(directive.deviceCode) else {
            return .stall(.unreachableDevice)
        }
        guard let step = Step(rawValue: directive.step) else {
            // Waiting is inert and recoverable; guessing would command the fleet.
            logger.notice("\(kind.rawValue, privacy: .public) \(directive.id, privacy: .public): unknown step \(directive.step, privacy: .public) — waiting")
            return .wait
        }
        switch step {
        case .acquire: return acquire(directive, carrier, world)
        case .printing: return printing(directive, carrier, world)
        case .fetching: return fetch(directive, carrier, world)
        case .deactivating: return deactivateSource(directive, carrier, world)
        case .confirmingIdle: return confirmIdle(directive, carrier, world)
        case .stowing: return stowing(directive, carrier, world)
        case .confirmingStow: return confirmStow(directive, carrier, world)
        case .travelling: return travel(directive, carrier, world)
        case .emplacing: return emplace(directive, carrier, world)
        case .activating: return activate(directive, carrier, world)
        case .confirmingRelay: return confirmRelay(directive, carrier, world)
        case .settling: return settle(directive, world)
        case .returning: return returnHome(directive, carrier, world)
        }
    }

    /// A Relay Run is one-shot: the brain launches a fresh directive per target,
    /// so an emptied queue ends THIS run rather than cueing a roam, whatever
    /// `context` holds.
    public func plan(_ context: RoamContext) -> RoamPlan { .exhausted }

    // MARK: - Fleet queries

    /// A print-capable device at `carrier`'s OWN location, or nil. Co-location is
    /// the whole composition — the clone materialises at the printer, and only a
    /// carrier standing there can take it aboard. **The carrier is considered
    /// last**: a HEAVEN vessel advertises `enqueue_print` too and must never
    /// shadow a dedicated printer beside it.
    static func hub(near carrier: Device, in world: WorldSnapshot) -> Device? {
        guard let location = carrier.location else { return nil }
        let printers = world.devices.values
            .filter { $0.acceptsPrintJobs && $0.location == location }
        return printers
            .filter { $0.deviceCode != carrier.deviceCode }
            .min { $0.deviceCode < $1.deviceCode }
            ?? printers.min { $0.deviceCode < $1.deviceCode }
    }

    /// The clone's device code, read off the completed `enqueue_print` operation.
    /// Detected by OPERATION RESULT, never by "a relay appeared near the hub" — a
    /// hub holding idle spares would have one of those read as this run's clone.
    static func printedRelayCode(in world: WorldSnapshot) -> String? {
        world.dispatchedOperations.values
            .filter { $0.kind == OperationKind.print.rawValue && $0.status == .completed }
            .max { $0.lastConfirmedAt < $1.lastConfirmedAt }?
            .detail["result"]?["new_device_code"]?.stringValue
    }

    /// The device a completed print named, **only if it is actually a relay**. The
    /// type check is the whole safety here: the hub's queue is shared, and a job
    /// finishing ahead of ours closes OUR operation row and stamps ITS device code
    /// as our clone.
    static func printedRelay(in world: WorldSnapshot) -> Device? {
        guard let code = printedRelayCode(in: world), let device = world.device(code) else { return nil }
        guard device.deviceType == relayDeviceType else { return nil }
        return device
    }

    /// The status a printed-but-unplanted relay wears.
    static let idleRelayStatus = "inactive"

    /// The one thing `activate` and `confirmRelay` must agree about — they are a
    /// dispatch/poll pair, and disagreement bounces a run between them.
    static let relayingStatus = "relaying"

    /// Relays at `location` belonging to nobody — **the pool this capability draws
    /// stock from**, ordered by device code. Ownership is decided by the CLAIM
    /// rather than provenance, so a run never proves a relay is *its* clone, only
    /// that nobody else took it. That is what makes a superseded print survivable.
    static func idleRelays(at location: String, in world: WorldSnapshot) -> [Device] {
        world.devices.values
            .filter {
                $0.deviceType == relayDeviceType
                    && $0.location == location
                    && $0.stowedInDeviceCode == nil
                    && $0.statusBase == idleRelayStatus
                    && !$0.isBusy
            }
            .sorted { $0.deviceCode < $1.deviceCode }
    }

    /// Where `directive` stands in the line of Relay Runs waiting for stock at
    /// `location` (0 = next) — **the FIFO rule, and the whole of the claim's
    /// safety.** Runs evaluate as independent tasks with nothing serialising the
    /// claim, so each computes the same queue from the same snapshot and takes the
    /// relay at its own position. Ordered by `createdAt`, id as tie-break.
    ///
    /// **`.paused` holds no place in line** — the one status where this and
    /// `DirectiveStatus.openCases` disagree, because a paused run at the head would
    /// otherwise starve every other run at that hub. `.needsAttention` IS counted.
    static func queuePosition(_ directive: Directive, at location: String, in world: WorldSnapshot) -> Int {
        let waiting = world.peers
            .filter { peer in
                guard peer.kind == .relayRun else { return false }
                guard peer.status == .running || peer.status == .needsAttention else { return false }
                guard let carrier = world.device(peer.deviceCode), carrier.location == location else { return false }
                return SalvageRun.relay(aboard: carrier, in: world) == nil
            }
            .sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
        // Not in the list means nothing to defer to — head of a queue of one.
        return waiting.firstIndex { $0.id == directive.id } ?? 0
    }

    /// The relay `directive` may take off `location`'s pool, if any. **Claims by
    /// queue POSITION, not "the first one"** — concurrent runs claim DISJOINT
    /// relays, so two `stow` commands in the same instant cannot contend. Nil means
    /// "no stock for me" and the caller prints, which is the only condition under
    /// which this capability spends resources.
    static func claimableRelay(
        _ directive: Directive, at location: String, in world: WorldSnapshot
    ) -> Device? {
        let pool = idleRelays(at: location, in: world)
        let position = queuePosition(directive, at: location, in: world)
        return position < pool.count ? pool[position] : nil
    }

    /// Whether a print this directive dispatched is still in flight, per
    /// `world`'s operation rows. `print` is a TRACKED kind (`.enqueued`), so
    /// unlike the `.simple` verbs it genuinely has a row to ask about.
    static func printInFlight(in world: WorldSnapshot) -> Bool {
        world.dispatchedOperations.values
            .contains { $0.kind == OperationKind.print.rawValue && $0.status.isOpen }
    }

    /// Why `printing` never got a relay, for the one log line the stall emits. The
    /// superseded case most needs naming: `.superseded` is neither `.completed` nor
    /// open, so both `printedRelayCode` and `printInFlight` go quiet and the run
    /// degrades to a stall whose display name names neither cause nor remedy.
    static func printDiagnosis(in world: WorldSnapshot) -> String {
        let prints = world.dispatchedOperations.values
            .filter { $0.kind == OperationKind.print.rawValue }
        if prints.isEmpty { return "no print was ever dispatched" }
        if prints.contains(where: { $0.status == .superseded }) {
            return "our print op was superseded — something else dispatched a print at the shared hub"
        }
        if let code = printedRelayCode(in: world) {
            guard let device = world.device(code) else {
                return "the print named \(code) but no row for it ever arrived"
            }
            return "the print named \(code), which is a \(device.deviceType), not a \(relayDeviceType)"
        }
        return "no print completed, and none is in flight"
    }

    /// The relay `directive` is moving, wherever it currently is. Resolution order
    /// matters: a relay named by CODE stays resolvable through every state the run
    /// puts it through, which the location- and stow-based lookups each stop
    /// answering partway. Every lookup filters on `deviceType` — each caller issues
    /// a command at what this returns.
    static func relay(for directive: Directive, carrier: Device, in world: WorldSnapshot) -> Device? {
        if let code = directive.sourceRelayCode,
           let source = world.device(code),
           source.deviceType == relayDeviceType {
            return source
        }
        // The stamped claim outranks every derived lookup below it, and is the
        // only one that survives `deploy` emptying the hold.
        if let code = directive.claimedRelayCode,
           let claimed = world.device(code),
           claimed.deviceType == relayDeviceType {
            return claimed
        }
        // Aboard BEFORE the print and the pool: a relay in the hold is settled,
        // and either of those can name a DIFFERENT relay than the one this run
        // is carrying — the pool at a hub with spares on it, the print when the
        // run took stock rather than waiting for its own clone.
        if let aboard = SalvageRun.relay(aboard: carrier, in: world) { return aboard }
        if let printed = printedRelay(in: world) { return printed }
        // The pool claim, so `stowing` commands exactly the relay `acquire` took.
        // Queue-checked, unlike the co-location fallback below it.
        if let location = carrier.location,
           let claimed = claimableRelay(directive, at: location, in: world) {
            return claimed
        }
        return SalvageRun.deployedRelay(near: carrier, in: world)
    }

    // MARK: - Acquire

    /// Where `directive`'s relay comes from, and the command that starts it coming.
    /// Branches on `sourceRelayCode`: nil PRINTS at the hub, non-nil RECLAIMS a
    /// named relay for free. The branches never fall through into one another —
    /// falling through to the print would spend resources the plan already decided
    /// to source free, which is why the reserve rail is unreachable from reclaim.
    private func acquire(_ directive: Directive, _ carrier: Device, _ world: WorldSnapshot) -> MissionAction {
        if let source = directive.sourceRelayCode {
            return reclaim(directive, carrier, world, source: source)
        }
        // A relay already aboard is one this run need not print, and is what makes
        // a relaunch mid-run idempotent.
        if let aboard = SalvageRun.relay(aboard: carrier, in: world) {
            return .claimRelay(deviceCode: aboard.deviceCode, nextStep: Step.travelling.rawValue)
        }
        // Before the hub lookup, so it holds even where the printer has gone away,
        // and before the rail, since existing stock spends nothing.
        if let location = carrier.location,
           let spare = Self.claimableRelay(directive, at: location, in: world) {
            logger.notice("relay run \(directive.id, privacy: .public): claiming idle relay \(spare.deviceCode, privacy: .public) at \(location, privacy: .public) — no print needed")
            return .advanceStep(nextStep: Step.stowing.rawValue)
        }
        guard let hub = Self.hub(near: carrier, in: world) else {
            // Guessing at another location would be a fabrication.
            logger.notice("relay run \(directive.id, privacy: .public): no print hub at \(carrier.location ?? "nowhere", privacy: .public)")
            return .stall(.unreachableDevice)
        }
        // Last moment before a real resource spend, so the rows behind the stock
        // reading get one authoritative read.
        if world.now.timeIntervalSince(hub.updatedAt) > Self.hubFreshness {
            return .refreshDevices(deviceCodes: [hub.deviceCode], thenStall: .unreachableDevice)
        }
        // A VETO sits BEFORE the command it vetoes; checking after would stall
        // about resources already committed. `.printStockShort` rather than nil
        // because this gates an irreversible spend, so a persistently-unreadable
        // census must reach bounded-retry-then-escalate instead of retrying forever.
        let rail = PrintRail(reserveFloor: reserveFloor)
        if reserveFloor != nil, rail.footprintCensusIsStale(world) {
            return .refreshFootprint(nextStep: Step.acquire.rawValue, thenStall: .printStockShort)
        }
        if let location = hub.location, rail.printStockIsShort(at: location, world) {
            // The most safety-relevant veto here, so it names the condition that
            // fired. No flood risk — the stall halts the run.
            let why = rail.printStockShortDiagnosis(at: location, world)
            logger.notice("relay run \(directive.id, privacy: .public): print stock short at \(location, privacy: .public) — \(why, privacy: .public)")
            return .stall(.printStockShort)
        }
        // `enqueue_print` takes a device type and nothing else. The hub's queue is
        // shared and never leased, so this simply queues behind whatever is in it.
        return .dispatch(
            kind: .print, deviceCode: hub.deviceCode,
            params: CommandParams(deviceType: Self.relayDeviceType),
            nextStep: Step.printing.rawValue
        )
    }

    /// Poll for `directive`'s printed clone to become a device row, or for a relay
    /// `carrier` may claim off the hub pool. Split from `acquire` even though
    /// `print` is tracked, because what this waits for is not the operation closing
    /// but the CLONE arriving — two facts landing in separate transactions.
    private func printing(_ directive: Directive, _ carrier: Device, _ world: WorldSnapshot) -> MissionAction {
        // The type check is what stops a shared-queue mix-up being adopted.
        if Self.printedRelay(in: world) != nil {
            return .advanceStep(nextStep: Step.stowing.rawValue)
        }
        // A run whose print was superseded can never resolve a clone by code even
        // though the server printed it and it is standing right there. Claiming off
        // the pool makes that survivable, queue-ordered so it cannot jump the line.
        if let location = carrier.location,
           let spare = Self.claimableRelay(directive, at: location, in: world) {
            logger.notice("relay run \(directive.id, privacy: .public): claiming relay \(spare.deviceCode, privacy: .public) from the hub pool at \(location, privacy: .public)")
            return .advanceStep(nextStep: Step.stowing.rawValue)
        }
        // Deadline BEFORE the read (`confirm-steps-need-fresh-evidence`): the
        // read below only advances on success, so a staleness-first ordering
        // would never reach the backstop while reads keep failing.
        if world.now.timeIntervalSince(directive.stepStartedAt) > PrintJob.deadline {
            logger.notice("relay run \(directive.id, privacy: .public): print produced no relay — \(Self.printDiagnosis(in: world), privacy: .public)")
            return .stall(.noRelayCoLocated)
        }
        if Self.printInFlight(in: world) { return .wait }
        // Gated on the row being ABSENT, not merely on the code existing: a row of
        // the wrong type is as well-read as it will get, and falls to the deadline.
        if let code = Self.printedRelayCode(in: world), world.device(code) == nil {
            return .refreshDevices(deviceCodes: [code], thenStall: .noRelayCoLocated)
        }
        return .wait
    }

    /// The loss to report when `directive` finds `target` already meshed, nil when
    /// finishing costs the mesh nothing. On the print path that race is free money;
    /// on the RECLAIM path the run has already de-meshed the source's system, so it
    /// finishes one node down and must not do so silently.
    static func meshRaceLoss(_ directive: Directive, target: String) -> String? {
        guard let source = directive.sourceRelayCode else { return nil }
        return """
            \(target) was meshed by something else while \(source) was in flight — the run finishes, \
            but it already de-meshed \(source)'s own system to get here, so the fleet is net one relay \
            down until \(source) (still aboard) is planted somewhere
            """
    }

    // MARK: - Reclaim

    /// The outcome of the confirm-read that must precede anything irreversible
    /// on the reclaim path.
    enum SourceConfirmation {
        /// The row is fresh, and the relay it describes is still the deployed,
        /// useless relay the plan named.
        case confirmed(Device)
        /// Do this instead — one authoritative read, or a stall.
        case act(MissionAction)
    }

    /// Whether `source` is still a relay this run may reclaim: an `ftl_relay`,
    /// stowed aboard nothing, with a location, and `relaying` — the deployed state
    /// prune actually judged. `statusBase`, never `status`: the backend appends a
    /// parenthetical to some statuses, and a raw comparison would tear down
    /// infrastructure on a misparse.
    static func sourceIsReclaimable(_ source: Device) -> Bool {
        source.deviceType == relayDeviceType
            && source.stowedInDeviceCode == nil
            && source.location != nil
            && source.statusBase == "relaying"
    }

    /// WHICH condition disqualified the source relay, in the same branch order
    /// `sourceIsReclaimable` tests them so the two can only agree. The stall's
    /// display name names neither cause nor remedy, and the four conditions want
    /// four different responses from an operator.
    static func reclaimDiagnosis(_ code: String, _ world: WorldSnapshot) -> String {
        guard let source = world.device(code) else {
            return "no row for \(code) ever arrived, even after an authoritative read"
        }
        if source.deviceType != relayDeviceType {
            return "\(code) is a \(source.deviceType), not a \(relayDeviceType)"
        }
        if let holder = source.stowedInDeviceCode {
            return "\(code) is stowed aboard \(holder) — something else has already taken it"
        }
        guard let location = source.location else {
            return "\(code) has no location — it is in transit, so there is nothing to fly to"
        }
        if source.statusBase != "relaying" {
            return "\(code) at \(location) reads \(source.statusBase), not relaying — it is no longer the deployed relay the plan judged useless"
        }
        return "\(code) at \(location) is reclaimable"
    }

    /// Fresh evidence about the relay `code` names before `directive` acts on it.
    /// An absent or too-old row buys ONE authoritative read; only a row young
    /// enough to mean something is judged. **A disqualifying judgement STALLS** —
    /// it neither proceeds nor falls back to printing, which would spend resources
    /// the plan declined on evidence the plan was wrong. The stall is NOT
    /// self-healing: the brain retries the same directive with the same source.
    static func confirmSource(
        _ directive: Directive, _ code: String, _ world: WorldSnapshot
    ) -> SourceConfirmation {
        guard let source = world.device(code) else {
            return .act(.refreshDevices(deviceCodes: [code], thenStall: .unreachableDevice))
        }
        if world.now.timeIntervalSince(source.updatedAt) > Self.reclaimFreshness {
            return .act(.refreshDevices(deviceCodes: [code], thenStall: .unreachableDevice))
        }
        guard sourceIsReclaimable(source) else {
            let why = reclaimDiagnosis(code, world)
            logger.notice("relay run \(directive.id, privacy: .public): refusing to reclaim — \(why, privacy: .public)")
            return .act(.stall(.unreachableDevice))
        }
        return .confirmed(source)
    }

    /// Route a reclaim-sourced `directive` into its own sub-sequence. No reserve
    /// rail runs here and none should — reclaim consumes no resources, structurally
    /// so, since this returns before `acquire` reaches any footprint read.
    private func reclaim(
        _ directive: Directive, _ carrier: Device, _ world: WorldSnapshot, source code: String
    ) -> MissionAction {
        // Already aboard means this is a re-entry; starting over would
        // `deactivate` a relay that is currently cargo. Type-filtered, or a plan
        // hint naming a stowed mining drone would commit the run to hauling it.
        if let aboard = world.device(code),
           aboard.deviceType == Self.relayDeviceType,
           aboard.stowedInDeviceCode == carrier.deviceCode {
            return .advanceStep(nextStep: Step.travelling.rawValue)
        }
        switch Self.confirmSource(directive, code, world) {
        case let .act(action): return action
        // The carrier must be standing with it before anything is done to it.
        case .confirmed: return .advanceStep(nextStep: Step.fetching.rawValue)
        }
    }

    /// Fly `carrier` to where `directive`'s source relay stands, before anything
    /// irreversible happens to it. **The order is a safety property**: `deactivate`
    /// drops that system out of the mesh, and authority reaches a device only
    /// through a subgraph holding a stationary replicant, so a relay deactivated
    /// from across the galaxy can become uncommandable exactly when the run needs
    /// to `stow` it. Freshness is NOT re-confirmed per pass — this step re-enters
    /// every tick for the whole trip; the confirm sits at the two decision points.
    private func fetch(_ directive: Directive, _ carrier: Device, _ world: WorldSnapshot) -> MissionAction {
        guard let code = directive.sourceRelayCode else {
            return .advanceStep(nextStep: Step.acquire.rawValue)
        }
        guard let source = world.device(code) else {
            return .refreshDevices(deviceCodes: [code], thenStall: .unreachableDevice)
        }
        guard let point = source.location else {
            logger.notice("relay run \(directive.id, privacy: .public): cannot fetch — \(Self.reclaimDiagnosis(code, world), privacy: .public)")
            return .stall(.unreachableDevice)
        }
        let ctx = StepContext(directive: directive, world: world, step: directive.step)
        let leg = TravelTo(
            deviceCode: carrier.deviceCode, destination: point,
            arrivalTest: .exactLocation, confirmStep: nil
        )
        return switch leg.next(ctx) {
        case let .action(action): action
        case .finished: .advanceStep(nextStep: Step.deactivating.rawValue)
        case .more, .noSubject: .stall(.unreachableDevice)
        }
    }

    /// Issue `deactivate` once at `directive`'s source relay, `carrier` standing
    /// alongside. Dispatch-only: `deactivate` is `.simple` and creates no
    /// `Operation` row, so naming this step as `nextStep` would re-issue it at the
    /// live API every tick forever.
    private func deactivateSource(
        _ directive: Directive, _ carrier: Device, _ world: WorldSnapshot
    ) -> MissionAction {
        guard let code = directive.sourceRelayCode else { return .advanceStep(nextStep: Step.acquire.rawValue) }
        // Fresh evidence immediately before the irreversible act — the confirm
        // `acquire` bought may be a whole interstellar trip old by now.
        let source: Device
        switch Self.confirmSource(directive, code, world) {
        case let .act(action): return action
        case let .confirmed(device): source = device
        }
        // `sourceIsReclaimable` has already proven the relay HAS a location, so
        // this is genuinely "are they in the same place" and not a nil match.
        guard source.location == carrier.location else {
            // Re-entered without the carrier having made the trip (a directive
            // relaunched at this step, a carrier sent elsewhere in between).
            // Go and fetch it rather than deactivating something out of reach.
            return .advanceStep(nextStep: Step.fetching.rawValue)
        }
        return .dispatch(
            kind: OperationKind.simple("deactivate"), deviceCode: source.deviceCode,
            params: CommandParams(), nextStep: Step.confirmingIdle.rawValue
        )
    }

    /// Poll `world` for the `deactivate` dispatched at `directive`'s source
    /// relay to take, so `carrier` may then stow it.
    ///
    /// Never dispatches: the verb carries no operation row, so an
    /// `openOperation` check here could never be non-nil and could not stop a
    /// same-step redispatch — and a redispatching poll step would reset the very
    /// clock `reclaimDeadline` measures from.
    private func confirmIdle(
        _ directive: Directive, _ carrier: Device, _ world: WorldSnapshot
    ) -> MissionAction {
        guard let code = directive.sourceRelayCode else { return .advanceStep(nextStep: Step.acquire.rawValue) }
        guard let source = world.device(code) else { return .stall(.unreachableDevice) }
        // The stow already took (a lost step move, a relaunch). Nothing left to
        // confirm about a relay that is cargo.
        if source.stowedInDeviceCode == carrier.deviceCode {
            return .advanceStep(nextStep: Step.travelling.rawValue)
        }
        // The success condition, stated as the inverse of the ONE mesh authority
        // this file recognises (`Device.isActiveRelay` and
        // `SalvageTargetPlanner.meshSystems`, both keyed on exactly `relaying`)
        // rather than as a fresh status string of its own. The deactivate having
        // taken means this system is now OFF the mesh, so the very next command
        // must clear the authority gate first — `carrierRetainsAuthority`.
        if source.statusBase != "relaying" { return carrierRetainsAuthority(directive, carrier, world) }
        // No staleness gate: `.age(pollInterval)` makes the ladder's freshness
        // check the same test as its own throttle, matching the old plain poll.
        let ctx = StepContext(directive: directive, world: world, step: directive.step)
        var ladder = ConfirmRow(deadline: Self.reclaimDeadline, onExpiry: .stallNow(.unreachableDevice))
        ladder.watermark = .age(Self.pollInterval)
        ladder.readInterval = Self.pollInterval
        let verdict = ladder.verdict([source], ctx)
        if case .act(.stall) = verdict {
            logger.notice("relay run \(directive.id, privacy: .public): \(code, privacy: .public) never stopped relaying after deactivate")
        }
        return switch verdict {
        case let .act(action): action
        case .judge: .wait
        }
    }

    /// Can `carrier` still command anything at this system? **The check the
    /// reclaim path's safety rests on** — the deactivate took the source's system
    /// off the mesh, so authority there now needs a replicant PHYSICALLY PRESENT, a
    /// precondition nowhere in these types. The gate asks the server's own
    /// `in_control_range` instead, and is permissive on a missing field.
    ///
    /// **Keyed on a WATERMARK, not age — young is not the same as AFTER.**
    /// `fetching` writes the carrier's row on arrival while the mesh is still up,
    /// so a seconds-old row can be entirely pre-deactivate. The age bound stays
    /// alongside as the backstop for a row that has since gone unread.
    private func carrierRetainsAuthority(
        _ directive: Directive, _ carrier: Device, _ world: WorldSnapshot
    ) -> MissionAction {
        if !world.isFresh(carrier, since: directive.stepStartedAt)
            || world.now.timeIntervalSince(carrier.updatedAt) > Self.reclaimFreshness {
            return .refreshDevices(deviceCodes: [carrier.deviceCode], thenStall: .unreachableDevice)
        }
        guard !carrier.isOutOfControlRange else {
            logger.notice("relay run \(directive.id, privacy: .public): \(carrier.deviceCode, privacy: .public) reports out of control range at \(carrier.location ?? "nowhere", privacy: .public) — the deactivate took this system off the mesh and nothing here can be commanded, so the stow is not dispatched")
            return .stall(.unreachableDevice)
        }
        return .advanceStep(nextStep: Step.stowing.rawValue)
    }

    // MARK: - Stowing

    /// Put `directive`'s relay aboard `carrier`, so it travels as cargo.
    ///
    /// The relay MUST ride aboard rather than fly itself: transport is gated by
    /// don't-strand (`brain-primitive-contracts`), and a relay that flew itself
    /// to an unmeshed system would be uncommandable the moment it got there.
    private func stowing(_ directive: Directive, _ carrier: Device, _ world: WorldSnapshot) -> MissionAction {
        guard let relay = Self.relay(for: directive, carrier: carrier, in: world) else {
            return .stall(.noRelayCoLocated)
        }
        // Already aboard — either the co-located carrier took the clone by
        // itself (the composition's premise) or this step is being re-entered.
        if relay.stowedInDeviceCode == carrier.deviceCode {
            return .claimRelay(deviceCode: relay.deviceCode, nextStep: Step.travelling.rawValue)
        }
        guard let location = carrier.location, relay.location == location else {
            // A relay somewhere else cannot be stowed onto this carrier;
            // POSTing a command that must be rejected helps nobody.
            logger.notice("relay run \(directive.id, privacy: .public): relay \(relay.deviceCode, privacy: .public) is not with the carrier")
            return .stall(.noRelayCoLocated)
        }
        // Issued ON the device being stowed, with the carrier as `target` — the
        // inverse would stow the vessel into the relay.
        return .dispatch(
            kind: .stow, deviceCode: relay.deviceCode,
            params: CommandParams(target: carrier.deviceCode),
            nextStep: Step.confirmingStow.rawValue
        )
    }

    /// Poll `world` for the relay's own `stowedInDeviceCode` to name `carrier`.
    ///
    /// The relay's column, never the carrier's `stowed_devices` blob: the blob
    /// is not a reliable inverse of it, so a gate reading the carrier end can be
    /// permanently unsatisfiable.
    private func confirmStow(_ directive: Directive, _ carrier: Device, _ world: WorldSnapshot) -> MissionAction {
        guard let relay = Self.relay(for: directive, carrier: carrier, in: world) else {
            return .stall(.noRelayCoLocated)
        }
        if relay.stowedInDeviceCode == carrier.deviceCode {
            return .claimRelay(deviceCode: relay.deviceCode, nextStep: Step.travelling.rawValue)
        }
        // No staleness gate: `.age(pollInterval)` makes the ladder's freshness
        // check the same test as its own throttle, matching the old plain poll.
        let ctx = StepContext(directive: directive, world: world, step: directive.step)
        var ladder = ConfirmRow(deadline: Self.stowDeadline, onExpiry: .stallNow(.noRelayCoLocated))
        ladder.watermark = .age(Self.pollInterval)
        ladder.readInterval = Self.pollInterval
        return switch ladder.verdict([relay], ctx) {
        case let .act(action): action
        case .judge: .wait
        }
    }

    // MARK: - Travel

    /// Fly `carrier` to `directive`'s target system, per `world`.
    private func travel(_ directive: Directive, _ carrier: Device, _ world: WorldSnapshot) -> MissionAction {
        guard let target = directive.currentTarget else { return .done }
        let ctx = StepContext(directive: directive, world: world, step: directive.step)
        let leg = TravelTo(
            deviceCode: carrier.deviceCode, destination: target,
            arrivalTest: .system, confirmStep: nil
        )
        switch leg.next(ctx) {
        case let .action(action): return action
        case .more, .noSubject: return .stall(.unreachableDevice)
        case .finished: break   // arrived — the fork below decides where to
        }
        // Somebody meshed this system while we were in flight. Planting a
        // second relay would spend one for nothing, so skip straight to the
        // confirmation and keep the relay aboard for the next errand.
        //
        // Read off DEVICE rows, never `ftlLinks`: a just-activated relay
        // produces no link rows at all.
        let meshed = SalvageTargetPlanner.meshSystems(in: Array(world.devices.values)).contains(target)
        // …but the paragraph above is only true of a PRINTED relay. A
        // reclaim reached this branch having already torn its source's
        // system off the mesh, so finishing here is a net loss dressed as a
        // success. It still finishes; it does not do so quietly.
        if meshed, let loss = Self.meshRaceLoss(directive, target: target) {
            logger.warning("relay run \(directive.id, privacy: .public): \(loss, privacy: .public)")
        }
        return .advanceStep(nextStep: meshed ? Step.settling.rawValue : Step.emplacing.rawValue)
    }

    /// Wait out `SalvageRun.systemResolutionDeadline`, spend `.refreshSystem`
    /// in the following `unresolvedReadBand`, wait out the rest of
    /// `systemUnresolvedRetryWindow`, then stall — for an uncached `target`.
    private func unresolvedSystem(
        _ directive: Directive, _ world: WorldSnapshot, target: String
    ) -> MissionAction {
        let sinceDeadline = world.now.timeIntervalSince(directive.stepStartedAt)
            - SalvageRun.systemResolutionDeadline
        if sinceDeadline <= 0 {
            return .wait
        }
        if sinceDeadline <= SalvageRun.unresolvedReadBand {
            return .refreshSystem(designation: target, nextStep: directive.step)
        }
        if sinceDeadline <= SalvageRun.systemUnresolvedRetryWindow {
            return .wait
        }
        return .stall(.salvageSystemUnresolved)
    }

    // MARK: - Emplace

    /// Fly `carrier` the last hop to `directive`'s target Lagrange point, then
    /// deploy the relay there. A relay needs an L4/L5 to mesh its system, and every
    /// system's entry point is itself an L4, so the hop is usually free. An
    /// uncached catalogue blob and a system with genuinely no stable point are
    /// split — conflating them silently forfeits the mesh.
    private func emplace(_ directive: Directive, _ carrier: Device, _ world: WorldSnapshot) -> MissionAction {
        guard let target = directive.currentTarget else { return .done }
        guard let system = world.system(target) else {
            return unresolvedSystem(directive, world, target: target)
        }
        guard let point = SalvageRun.lagrangePoint(in: system) else {
            // A cached system with no L4 can never be meshed, so this run has
            // nothing left to do — surfaced under the nearest existing reason.
            logger.notice("relay run \(directive.id, privacy: .public): \(target, privacy: .public) has no Lagrange point")
            return .stall(.salvageSystemUnresolved)
        }
        guard let relay = Self.relay(for: directive, carrier: carrier, in: world) else {
            return .stall(.noRelayCoLocated)
        }
        if carrier.location != point {
            let ctx = StepContext(directive: directive, world: world, step: directive.step)
            let leg = TravelTo(
                deviceCode: carrier.deviceCode, destination: point,
                arrivalTest: .exactLocation, confirmStep: nil
            )
            switch leg.next(ctx) {
            case let .action(action): return action
            case .more, .noSubject: return .stall(.unreachableDevice)
            case .finished: break   // standing at the point — deploy below
            }
        }
        // Re-entry after a `deploy` whose step move was lost: re-issuing `deploy`
        // at a deployed relay is rejected, so hand off to activation instead.
        if relay.stowedInDeviceCode == nil, relay.location == point {
            return .advanceStep(nextStep: Step.activating.rawValue)
        }
        // No `openOperation` guard — `deploy` is untracked, so the lookup is always
        // nil. The safety is that this hands off to a DIFFERENT step.
        return .dispatch(
            kind: OperationKind.simple("deploy"), deviceCode: relay.deviceCode,
            params: CommandParams(), nextStep: Step.activating.rawValue
        )
    }

    /// Issue `activate` once at `directive`'s relay, in-situ and with `carrier`
    /// present, judged off `world`. Dispatch-only, deliberately.
    ///
    /// In-situ is not a preference: pre-activating a relay and then moving it
    /// does NOT mesh (`brain-primitive-contracts`). The relay comes up where it
    /// is going to stay.
    private func activate(_ directive: Directive, _ carrier: Device, _ world: WorldSnapshot) -> MissionAction {
        guard let relay = Self.relay(for: directive, carrier: carrier, in: world) else {
            return .stall(.relayActivationFailed)
        }
        // Code-first resolution returns a STILL-STOWED relay where a location-based
        // lookup could not, so "a failed `deploy` cannot reach the dispatch" has to
        // be restored explicitly. Activating cargo is not a thing this run may do.
        guard relay.stowedInDeviceCode == nil else {
            logger.notice("relay run \(directive.id, privacy: .public): \(relay.deviceCode, privacy: .public) is still aboard \(carrier.deviceCode, privacy: .public) — deploy never took")
            return .stall(.relayActivationFailed)
        }
        // **Already up? Hand off rather than command it again.** Otherwise an
        // `activate` whose answer never came back retries into a correct "already
        // active" rejection, which reads as `commandRejected`: retry → dispatch →
        // reject → stall, permanently, beside a relay that is relaying throughout.
        // Read the STATE, not the server's prose, which the backend may reword.
        if relay.statusBase == Self.relayingStatus {
            logger.info("relay run \(directive.id, privacy: .public): \(relay.deviceCode, privacy: .public) is already relaying — confirming rather than re-activating")
            return .advanceStep(nextStep: Step.confirmingRelay.rawValue)
        }
        // The window that check exists for is exactly the one where its row is
        // WRONG, so a row too old to trust buys a read before it buys a command:
        // a stale read is free to be wrong, a duplicate `activate` is not.
        if world.now.timeIntervalSince(relay.updatedAt) > Self.pollInterval {
            return .refreshDevices(deviceCodes: [relay.deviceCode], thenStall: nil)
        }
        return .dispatch(
            kind: OperationKind.simple("activate"), deviceCode: relay.deviceCode,
            params: CommandParams(), nextStep: Step.confirmingRelay.rawValue
        )
    }

    /// Poll for the `activate` dispatched at `directive`'s relay to take. Never
    /// dispatches: `activate` carries no operation row, so a redispatching poll
    /// step would reset the clock `activationDeadline` measures from and re-issue
    /// forever at a relay that never came up.
    private func confirmRelay(_ directive: Directive, _ carrier: Device, _ world: WorldSnapshot) -> MissionAction {
        guard let relay = Self.relay(for: directive, carrier: carrier, in: world) else {
            return .stall(.relayActivationFailed)
        }
        // `statusBase`, not `status` — a raw comparison reads a live relay as dead.
        if relay.statusBase == Self.relayingStatus { return .advanceStep(nextStep: Step.settling.rawValue) }
        // No staleness gate: `.age(pollInterval)` makes the ladder's freshness
        // check the same test as its own throttle, matching the old plain poll.
        let ctx = StepContext(directive: directive, world: world, step: directive.step)
        var ladder = ConfirmRow(
            deadline: Self.activationDeadline, onExpiry: .stallNow(.relayActivationFailed)
        )
        ladder.watermark = .age(Self.pollInterval)
        ladder.readInterval = Self.pollInterval
        return switch ladder.verdict([relay], ctx) {
        case let .act(action): action
        case .judge: .wait
        }
    }

    /// Confirm `directive`'s actual deliverable: the TARGET SYSTEM is meshed. A
    /// different claim from `confirmingRelay`'s — a relay can report `relaying` in
    /// the wrong system. Read through DEVICE rows, never `ftlLinks`: a
    /// just-activated relay has produced no link rows, so a link-based read would
    /// report failure on a perfect run.
    private func settle(_ directive: Directive, _ world: WorldSnapshot) -> MissionAction {
        guard let target = directive.currentTarget else { return .done }
        guard SalvageTargetPlanner.meshSystems(in: Array(world.devices.values)).contains(target) else {
            logger.notice("relay run \(directive.id, privacy: .public): \(target, privacy: .public) still reads as unmeshed after activation")
            return .stall(.relayActivationFailed)
        }
        logger.info("relay run \(directive.id, privacy: .public): \(target, privacy: .public) is meshed")
        guard directive.returnToOrigin else { return .done }
        return .advanceStep(nextStep: Step.returning.rawValue)
    }

    /// Fly `carrier` back to the hub so the next run can use it. **The destination
    /// is the hub LOCATION, re-derived — never `directive.originDesignation`**,
    /// which is a lossy projection to a bare SYSTEM and travels to that system's
    /// entry point, an L4 away from the printer, while `Brain.freeCarrier` demands
    /// an exact match. No hub to fly to is `.done`, not a stall — the relay is
    /// planted and the deliverable is met.
    private func returnHome(_ directive: Directive, _ carrier: Device, _ world: WorldSnapshot) -> MissionAction {
        let ctx = StepContext(directive: directive, world: world, step: directive.step)
        let home = ReturnHome(deviceCodes: [carrier.deviceCode], destination: .theatreDepot)
        return switch home.next(ctx) {
        case let .action(action): action
        case .finished, .more: .done
        case .noSubject: noHub(directive)
        }
    }

    /// Nothing to fly home to. Says so once, then finishes.
    private func noHub(_ directive: Directive) -> MissionAction {
        logger.notice("relay run \(directive.id, privacy: .public): no hub to return to — leaving the carrier where it stands")
        return .done
    }
}
