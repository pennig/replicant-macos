//
//  RelayRun.swift
//  Replicould — DirectiveEngine
//
//  Grow the FTL mesh by one system: acquire a relay, get it aboard the carrier,
//  fly it to the target's Lagrange point, deploy it, activate it in-situ, and
//  confirm the mesh actually grew. The `tendMesh` goal's hands — everything
//  above this in the brain merely decides WHERE; this is what goes and does it.
//
//  One-shot by design. A Relay Run meshes exactly one system and finishes; the
//  brain launches a fresh directive for the next one, which is why `plan(_:)`
//  never roams.
//
//  **Composition (v1): autofactory + co-located carrier.** The relay is printed
//  AT the hub (`enqueue_print` on the autofactory) and taken aboard a HEAVEN
//  vessel that is already parked at the hub's location. Verified against the
//  live fleet on 2026-08-03: autofactory `43C9B54A` and heaven_vessel `C7836770`
//  both sit at `AINALRAM-BELT-1`, so the co-location the composition assumes is
//  real. The alternative — a print-VESSEL, collapsing printer and carrier into
//  one device — is not built: this account has no such device, and the
//  autofactory is the only print-capable thing in the fleet.
//
//  Ownership is the carrier `deviceCode` and nothing else (brain-primitive
//  contracts, ticket 05): the relay is held by transitive stow rather than by
//  any lease field, and the hub's print queue is shared and NEVER leased.
//
//  Pure by contract, like every mission: no I/O, no clock reads (time comes from
//  `world.now`), no randomness. Every effect is the returned `MissionAction`.
//

import Foundation
import GameModels
import GameServices
import OSLog
import UniverseModels
import Utils

// Category matches `SalvageRun`/`DirectiveExecutor` rather than the brain's
// `Brain` category: this is a mission machine, and a run's log lines are read
// alongside the engine's, not alongside the planner's.
private let logger = Logger(subsystem: "name.pennig.replicould", category: "DirectiveEngine")

public struct RelayRun: MissionStepMachine {
    public let kind: DirectiveKind = .relayRun
    public var firstStep: String { Step.acquire }

    /// The per-type resource reserve floor `R` — the rail that vetoes a print
    /// which would drop the hub below the stock its other consumers need
    /// (brain-goal-decision-policy, ticket 03's spend ceiling).
    ///
    /// **Deliberately unarmed in production (`nil`), and deliberately not a
    /// literal.** The calibrated value is a later task, and inventing one here
    /// would ship a number that reads as measured when it is a guess — the
    /// expensive direction to be wrong in, since too high never prints and too
    /// low drains the hub. `nil` means "the rail is not armed yet": the veto is
    /// structurally in place, wired at the one point it can do any good (before
    /// the `enqueue_print`), and turning it on is a one-value change.
    ///
    /// Injectable rather than a `static let` so the veto's behaviour is provable
    /// under test without a calibrated constant existing yet.
    public let reserveFloor: Int?

    public init(reserveFloor: Int? = nil) {
        self.reserveFloor = reserveFloor
    }

    /// This mission's step vocabulary. Plain strings because `Directive.step` is
    /// deliberately untyped — each kind owns its own vocabulary.
    ///
    /// Read the pairs: `stowing`/`confirmingStow`, `emplacing`→`activating`,
    /// `activating`/`confirmingRelay`. Every one of them is a DISPATCH step
    /// whose command carries no `Operation` row, split from the step that polls
    /// for it to take. See `trackedKinds` for why that split is mandatory.
    public enum Step {
        /// Decide where the relay comes from, and start it coming. Branches on
        /// `Directive.sourceRelayCode`: nil prints a fresh one at the hub (built),
        /// non-nil reclaims an existing one (a later task — see `acquire`).
        public static let acquire = "acquire"
        /// Poll for the printed clone to appear in the fleet.
        public static let printing = "printing"
        /// Dispatch `stow` at the relay, naming the carrier.
        public static let stowing = "stowing"
        /// Poll the relay's own `stowedInDeviceCode`. Split from `stowing`
        /// because `stow` is immediate and carries no `Operation` row.
        public static let confirmingStow = "confirmingStow"
        /// Fly the carrier to the target system.
        public static let travelling = "travelling"
        /// Fly the last hop to the target's Lagrange point, then `deploy` the
        /// relay there.
        public static let emplacing = "emplacing"
        /// Dispatch `activate` at the just-deployed relay. Dispatch-only.
        public static let activating = "activating"
        /// Poll for `statusBase == "relaying"`, backstopped by
        /// `SalvageRun.activationDeadline`. Split from `activating` for the same
        /// reason `confirmingStow` is split from `stowing`.
        public static let confirmingRelay = "confirmingRelay"
        /// Confirm the run's actual deliverable: the TARGET SYSTEM is meshed.
        public static let settling = "settling"
    }

    // MARK: - Constants

    /// The device type this run plants. Verified live 2026-08-03: 17 `ftl_relay`
    /// devices in the fleet, the deployed ones `status == "relaying"` with
    /// `features == ["cruise","relay","stow"]`, parked at L4 points.
    public static let relayDeviceType = SalvageRun.relayDeviceType

    /// The kinds this machine dispatches that DO create an `Operation` row.
    ///
    /// The distinction is the single most consequential thing in this file. A
    /// `.simple` verb (`stow`, `deploy`, `activate`) is classified `.immediate`
    /// by `CommandClient` and tracked with NO operation row at all, so
    /// `world.openOperation(for:)` is permanently nil for it — a guard that can
    /// never fire. And `DirectiveExecutor.apply` re-stamps `stepStartedAt` on
    /// every accepted dispatch, with no same-step exception. So a `.simple`
    /// dispatch whose `nextStep` is its OWN step re-issues the command on every
    /// 5-second tick, forever, against a deadline that can never accumulate
    /// because the step keeps resetting its own clock.
    ///
    /// A TRACKED kind has no such problem: its operation row IS the guard, which
    /// is why `travelling`/`emplacing` may legitimately redispatch travel into
    /// themselves. See the `same-step-dispatch-needs-tracked-op` note.
    public static let trackedKinds: Set<OperationKind> = [.travel, .print]

    /// How long to let a print take before surfacing. The live relay print is
    /// ~800 s, so this is generous by a wide margin — it exists for the print
    /// that never happens (dropped `print.completed`, a job dequeued by hand,
    /// a queue that never reached this job), not for a slow one.
    public static let printDeadline: TimeInterval = 30 * 60

    /// How long to let a `stow` take. Immediate server-side, so all this covers
    /// is the confirm-read that proves it.
    public static let stowDeadline: TimeInterval = 5 * 60

    /// How old the hub's row may be and still be believed. Same value and
    /// reasoning as `SalvageRun.stagingFreshness`: a positive finding read off a
    /// local row is worth only as much as the row.
    public static let hubFreshness: TimeInterval = 5 * 60

    /// Floor between confirm-reads while a poll step waits. Shared with
    /// `SalvageRun` rather than restated — the tick rate and the reason are
    /// identical.
    public static let pollInterval: TimeInterval = SalvageRun.relayPollInterval

    // MARK: - Entry

    public func nextAction(directive: Directive, world: WorldSnapshot) -> MissionAction {
        guard let carrier = world.device(directive.deviceCode) else {
            return .stall(.unreachableDevice)
        }
        switch directive.step {
        case Step.acquire: return acquire(directive, carrier, world)
        case Step.printing: return printing(directive, world)
        case Step.stowing: return stowing(directive, carrier, world)
        case Step.confirmingStow: return confirmStow(directive, carrier, world)
        case Step.travelling: return travel(directive, carrier, world)
        case Step.emplacing: return emplace(directive, carrier, world)
        case Step.activating: return activate(directive, carrier, world)
        case Step.confirmingRelay: return confirmRelay(directive, carrier, world)
        case Step.settling: return settle(directive, world)
        default:
            // An unrecognised step must never dispatch. Waiting is inert and
            // recoverable — the user can cancel, or the step ships.
            logger.notice("relay run \(directive.id, privacy: .public): unknown step \(directive.step, privacy: .public) — waiting")
            return .wait
        }
    }

    /// A Relay Run is one-shot: the brain launches a fresh directive per target,
    /// so an emptied queue ends THIS run rather than cueing a roam. Answered
    /// explicitly rather than left to a default because the protocol has none —
    /// a machine that forgot to answer would silently idle every run of its kind.
    public func plan(_ context: RoamContext) -> RoamPlan { .exhausted }

    // MARK: - Fleet queries

    /// The print hub this run may use: a print-capable device AT the carrier's
    /// own location.
    ///
    /// Co-location is the whole composition, not a convenience — the printed
    /// clone materialises at the printer, and only a carrier already standing
    /// there can take it aboard. A hub elsewhere in the galaxy is no more use
    /// than no hub at all, so it deliberately does not match.
    ///
    /// `Device.isPrintHub` keys off `enqueue_print` in `availableCommands`
    /// rather than on device type, which is what makes it match the live
    /// autofactory at a BELT location without this file knowing what an
    /// autofactory is.
    static func hub(near carrier: Device, in world: WorldSnapshot) -> Device? {
        guard let location = carrier.location else { return nil }
        return world.devices.values
            .filter { $0.isPrintHub && $0.location == location }
            .min { $0.deviceCode < $1.deviceCode }
    }

    /// The device code of the clone this run printed, from the completed
    /// `enqueue_print` operation's result.
    ///
    /// This — not "a relay appeared near the hub" — is how print completion is
    /// detected, and the difference is not academic: the live hub already has
    /// two idle relays parked at it (`B94C05A8`, `8B55ED07`), so a presence
    /// check would read one of THOSE as this run's clone, skip the print, and
    /// then try to fly away with a relay it never acquired.
    ///
    /// `new_device_code` is where the server names the clone; `GameSync.deviceRoute`
    /// reads the same key off `print.completed` to fold the clone into the local
    /// fleet with one `.high` read, and `Reconciler.completeOpenOperation` files
    /// the event's payload under `detail.result` on the op this directive
    /// dispatched. `WorldSnapshot.dispatchedOperations` is scoped to exactly the
    /// ops this directive's own log names, so this can never pick up somebody
    /// else's print.
    static func printedRelayCode(in world: WorldSnapshot) -> String? {
        world.dispatchedOperations.values
            .filter { $0.kind == OperationKind.print.rawValue && $0.status == .completed }
            .max { $0.lastConfirmedAt < $1.lastConfirmedAt }?
            .detail["result"]?["new_device_code"]?.stringValue
    }

    /// Whether a print this directive dispatched is still in flight. `print` is a
    /// TRACKED kind (`.enqueued`), so unlike the `.simple` verbs it genuinely has
    /// a row to ask about.
    static func printInFlight(in world: WorldSnapshot) -> Bool {
        world.dispatchedOperations.values
            .contains { $0.kind == OperationKind.print.rawValue && $0.status.isOpen }
    }

    /// The relay this run is moving, wherever it currently is.
    ///
    /// Resolution order matters. The printed clone is named by code, so it stays
    /// resolvable through every state change the run puts it through — stowed,
    /// travelling (location nil), deployed, relaying — which the location- and
    /// stow-based lookups each stop answering at some point in the sequence. The
    /// fallbacks cover the run that never printed at all: a relay the operator
    /// had already staged aboard the carrier, or (post-`deploy`, when
    /// `stowedInDeviceCode` has just been cleared) one standing where the
    /// carrier stands.
    static func relay(for directive: Directive, carrier: Device, in world: WorldSnapshot) -> Device? {
        if let code = printedRelayCode(in: world), let printed = world.device(code) { return printed }
        return SalvageRun.relay(aboard: carrier, in: world)
            ?? SalvageRun.deployedRelay(near: carrier, in: world)
    }

    /// Whether the reserve rail vetoes a print at `location`.
    ///
    /// Unknown is never short — the house invariant. No census row for the hub's
    /// location means nobody has told us the stock, which is a different fact
    /// from being told it is low, and vetoing on silence would deadlock the run
    /// against a table this mission never refreshes.
    ///
    /// Reads the location's TOTAL holdings, which is all `LocationFootprint`
    /// carries today. The rail is specified per RESOURCE TYPE
    /// (brain-resource-hub-model, ticket 06), and the per-type stockpile record
    /// it needs is a later task; when it lands, this is the one place that
    /// changes.
    func printStockIsShort(at location: String, _ world: WorldSnapshot) -> Bool {
        guard let floor = reserveFloor else { return false }
        guard let footprint = world.footprints[location] else { return false }
        return footprint.resources < floor
    }

    // MARK: - Acquire

    /// Where this run's relay comes from, and the command that starts it coming.
    ///
    /// Two branches by `Directive.sourceRelayCode`, and only the first is built:
    /// nil prints a fresh relay at the hub; non-nil names an existing, useless
    /// relay to RECLAIM and redeploy (`tendMesh`'s prune half — a later task).
    /// The unbuilt branch waits rather than falling through into the print path:
    /// falling through would spend 370 units and ~800 s printing a relay the
    /// plan had already decided to source for free, which is precisely the
    /// mistake the field exists to prevent.
    private func acquire(_ directive: Directive, _ carrier: Device, _ world: WorldSnapshot) -> MissionAction {
        if let source = directive.sourceRelayCode {
            logger.notice("relay run \(directive.id, privacy: .public): reclaim of \(source, privacy: .public) is not built yet — waiting")
            return .wait
        }
        // A relay already aboard is a relay this run does not have to print.
        // Also what makes a relaunch mid-run idempotent.
        if SalvageRun.relay(aboard: carrier, in: world) != nil {
            return .advanceStep(nextStep: Step.travelling)
        }
        guard let hub = Self.hub(near: carrier, in: world) else {
            // Nothing print-capable where the carrier stands. The composition
            // cannot proceed and guessing at another location would be a
            // fabrication, so surface it.
            logger.notice("relay run \(directive.id, privacy: .public): no print hub at \(carrier.location ?? "nowhere", privacy: .public)")
            return .stall(.unreachableDevice)
        }
        // The stock reading below is only worth as much as the rows behind it,
        // and this is the last moment before a real resource spend. One
        // authoritative read, carrying a stall so a read that keeps failing
        // surfaces rather than re-firing every tick.
        if world.now.timeIntervalSince(hub.updatedAt) > Self.hubFreshness {
            return .refreshDevices(deviceCodes: [hub.deviceCode], thenStall: .unreachableDevice)
        }
        // The reserve rail is a VETO, so it sits BEFORE the command it vetoes.
        // Checking after the dispatch would surface a stall about resources
        // that were already committed.
        if let location = hub.location, printStockIsShort(at: location, world) {
            return .stall(.printStockShort)
        }
        // `enqueue_print` takes a device type and nothing else — no location,
        // no resource bill. The hub's queue is shared and never leased, so a
        // job already in it is expected and this simply queues behind it.
        return .dispatch(
            kind: .print, deviceCode: hub.deviceCode,
            params: CommandParams(deviceType: Self.relayDeviceType),
            nextStep: Step.printing
        )
    }

    /// Poll for the printed clone to become a device row.
    ///
    /// Split from `acquire` even though `print` is a tracked kind, because the
    /// completion this waits for is not the operation closing but the CLONE
    /// arriving — two facts that land in separate transactions.
    private func printing(_ directive: Directive, _ world: WorldSnapshot) -> MissionAction {
        let code = Self.printedRelayCode(in: world)
        // The positive first: the clone is in the fleet and the run may move on.
        if let code, world.device(code) != nil {
            return .advanceStep(nextStep: Step.stowing)
        }
        // Deadline BEFORE the read (see `confirm-steps-need-fresh-evidence`,
        // half two): the read below only advances on success, so a
        // staleness-first ordering would never reach the backstop while reads
        // keep failing.
        if world.now.timeIntervalSince(directive.stepStartedAt) > Self.printDeadline {
            return .stall(.noRelayCoLocated)
        }
        if Self.printInFlight(in: world) { return .wait }
        if let code {
            // The completion named a device the fleet has not got. `GameSync`
            // already spends a `.high` read on exactly this code off
            // `print.completed`; this is the backstop for that read failing.
            // One authoritative read of a named code is conclusive — a row it
            // cannot produce will not appear by waiting — so it carries a stall
            // rather than looping.
            return .refreshDevices(deviceCodes: [code], thenStall: .noRelayCoLocated)
        }
        return .wait
    }

    // MARK: - Stowing

    /// Put the relay aboard the carrier, so it travels as cargo.
    ///
    /// The relay MUST ride aboard rather than fly itself: transport is gated by
    /// don't-strand (brain-primitive-contracts), and a relay that flew itself to
    /// an unmeshed system would be uncommandable the moment it got there.
    private func stowing(_ directive: Directive, _ carrier: Device, _ world: WorldSnapshot) -> MissionAction {
        guard let relay = Self.relay(for: directive, carrier: carrier, in: world) else {
            return .stall(.noRelayCoLocated)
        }
        // Already aboard — either the co-located carrier took the clone by
        // itself (the composition's premise) or this step is being re-entered.
        // Either way, re-issuing `stow` would be a pointless POST.
        if relay.stowedInDeviceCode == carrier.deviceCode {
            return .advanceStep(nextStep: Step.travelling)
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
            nextStep: Step.confirmingStow
        )
    }

    /// Poll the relay's own `stowedInDeviceCode`.
    ///
    /// The relay's column, never the carrier's `stowed_devices` blob: the blob
    /// is not a reliable inverse of it — a real vessel's listed one unrelated
    /// device while six drones claimed to be aboard — so a gate reading the
    /// carrier end can be permanently unsatisfiable.
    private func confirmStow(_ directive: Directive, _ carrier: Device, _ world: WorldSnapshot) -> MissionAction {
        guard let relay = Self.relay(for: directive, carrier: carrier, in: world) else {
            return .stall(.noRelayCoLocated)
        }
        if relay.stowedInDeviceCode == carrier.deviceCode {
            return .advanceStep(nextStep: Step.travelling)
        }
        if world.now.timeIntervalSince(directive.stepStartedAt) > Self.stowDeadline {
            return .stall(.noRelayCoLocated)
        }
        // Nothing else moves this row: `stow` emits no operation and the stow
        // event's field application only lands if the event arrives at all. A
        // bare wait would sit on a stale row for the whole deadline and then
        // stall on a relay that is actually aboard. Throttled on the row's own
        // `updatedAt`, which is what a successful read advances.
        if world.now.timeIntervalSince(relay.updatedAt) > Self.pollInterval {
            return .refreshDevices(deviceCodes: [relay.deviceCode], thenStall: nil)
        }
        return .wait
    }

    // MARK: - Travel

    private func travel(_ directive: Directive, _ carrier: Device, _ world: WorldSnapshot) -> MissionAction {
        guard let target = directive.currentTarget else { return .done }
        if SalvageRun.system(of: carrier) == target {
            // Somebody meshed this system while we were in flight (another run,
            // a hub built here). Planting a second relay would spend one for
            // nothing, so skip straight to the confirmation — the run's goal is
            // already met and the relay stays aboard for the next errand.
            //
            // Read off DEVICE rows, never `ftlLinks`: a just-activated relay
            // produces no link rows at all.
            let meshed = SalvageTargetPlanner.meshSystems(in: Array(world.devices.values)).contains(target)
            return .advanceStep(nextStep: meshed ? Step.settling : Step.emplacing)
        }
        // An open op means the trip is under way — expected, and the guard that
        // stops a second travel landing on top of the first. This is exactly
        // what a `.simple` verb cannot have.
        if world.openOperation(for: carrier.deviceCode) != nil { return .wait }
        // …and the guard for the gap between that op closing and the arrival's
        // location write landing, in which the check above says "not there yet"
        // about a carrier that already is.
        if let unconfirmed = SalvageRun.travelPositionUnconfirmed(carrier, world) { return unconfirmed }
        return .dispatch(
            kind: .travel, deviceCode: carrier.deviceCode,
            params: CommandParams(destination: target), nextStep: Step.travelling
        )
    }

    /// What to do about a target system whose catalogue blob still isn't cached.
    ///
    /// Same shape and same ordering as `SalvageRun.unresolvedSystem`, and for
    /// the same reason: `.wait` is the only action that leaves `stepStartedAt`
    /// alone, so the deadline can only accumulate while the step waits, and
    /// requesting a refresh on every pass would reset the very clock the
    /// backstop measures from.
    private func unresolvedSystem(
        _ directive: Directive, _ world: WorldSnapshot, target: String
    ) -> MissionAction {
        if world.now.timeIntervalSince(directive.stepStartedAt) <= SalvageRun.systemResolutionDeadline {
            return .wait
        }
        if SalvageRun.stepEntryCount(directive, world) <= SalvageRun.systemRefreshAttempts {
            return .refreshSystem(designation: target, nextStep: directive.step)
        }
        return .stall(.salvageSystemUnresolved)
    }

    // MARK: - Emplace

    /// Fly the last hop to the target's Lagrange point, then deploy the relay
    /// there.
    ///
    /// A relay needs a gravitationally stable point (an L4/L5) to mesh its
    /// system, and every system's entry point is itself an L4 — which is where
    /// a bare-designation travel already landed the carrier, so the hop is
    /// usually free. `SalvageRun.lagrangePoint(in:)` is shared rather than
    /// re-derived: it is a fact about the game, not about salvage, and it
    /// carries a live-verified correction (the system-level locations endpoint
    /// returns no per-planet Lagrange sites) that must not be forked.
    ///
    /// An uncached catalogue blob and a system that genuinely has no stable
    /// point are split, because conflating them silently forfeits the mesh: the
    /// first is "we don't know yet" and waits.
    private func emplace(_ directive: Directive, _ carrier: Device, _ world: WorldSnapshot) -> MissionAction {
        guard let target = directive.currentTarget else { return .done }
        guard let system = world.system(target) else {
            return unresolvedSystem(directive, world, target: target)
        }
        guard let point = SalvageRun.lagrangePoint(in: system) else {
            // A cached system with no L4 anywhere can never be meshed, so unlike
            // a Salvage Run — which still has ore to take — this run has nothing
            // left to do. Surfaced under the nearest existing reason: the
            // catalogue cannot tell us where to plant. (The reason set is closed
            // by design; a `relayTargetUnemplaceable` of its own belongs with the
            // brain wiring that would have to classify it.)
            logger.notice("relay run \(directive.id, privacy: .public): \(target, privacy: .public) has no Lagrange point")
            return .stall(.salvageSystemUnresolved)
        }
        guard let relay = Self.relay(for: directive, carrier: carrier, in: world) else {
            return .stall(.noRelayCoLocated)
        }
        if carrier.location != point {
            if world.openOperation(for: carrier.deviceCode) != nil { return .wait }
            // The `!=` above is the check that misreads a row still lagging the
            // previous arrival; prove the row post-dates that arrival first.
            if let unconfirmed = SalvageRun.travelPositionUnconfirmed(carrier, world) { return unconfirmed }
            return .dispatch(
                kind: .travel, deviceCode: carrier.deviceCode,
                params: CommandParams(destination: point), nextStep: Step.emplacing
            )
        }
        // No `openOperation` guard: `deploy` is untracked, so the lookup is
        // always nil — a guard that can never fire is noise, not safety. The
        // safety is that this hands off to a DIFFERENT step.
        return .dispatch(
            kind: OperationKind.simple("deploy"), deviceCode: relay.deviceCode,
            params: CommandParams(), nextStep: Step.activating
        )
    }

    /// Issue `activate` once, in-situ. Dispatch-only, deliberately.
    ///
    /// In-situ is not a preference: pre-activating a relay and then moving it
    /// does NOT mesh (live-tested, brain-primitive-contracts). The relay comes
    /// up where it is going to stay, with the carrier present.
    private func activate(_ directive: Directive, _ carrier: Device, _ world: WorldSnapshot) -> MissionAction {
        // `deploy` cleared the relay's `stowedInDeviceCode` the moment it
        // landed, so the aboard-query stops finding it at exactly the point this
        // step needs it. `relay(for:carrier:in:)` resolves by code first for
        // that reason.
        guard let relay = Self.relay(for: directive, carrier: carrier, in: world) else {
            return .stall(.relayActivationFailed)
        }
        return .dispatch(
            kind: OperationKind.simple("activate"), deviceCode: relay.deviceCode,
            params: CommandParams(), nextStep: Step.confirmingRelay
        )
    }

    /// Poll for the dispatched `activate` to take.
    ///
    /// Never dispatches. `activate` carries no operation row, so an
    /// `openOperation` check here could never be non-nil and could not stop a
    /// same-step redispatch — and a redispatching poll step would reset the very
    /// clock `activationDeadline` measures from, leaving a relay that never came
    /// up being `activate`d at the live API forever.
    private func confirmRelay(_ directive: Directive, _ carrier: Device, _ world: WorldSnapshot) -> MissionAction {
        guard let relay = Self.relay(for: directive, carrier: carrier, in: world) else {
            return .stall(.relayActivationFailed)
        }
        // `statusBase`, not `status`: the backend appends a parenthetical
        // parameter to some statuses, and a raw comparison would read a live
        // relay as dead.
        if relay.statusBase == "relaying" { return .advanceStep(nextStep: Step.settling) }
        if world.now.timeIntervalSince(directive.stepStartedAt) > SalvageRun.activationDeadline {
            return .stall(.relayActivationFailed)
        }
        // Nothing else moves this row — the `relay.*` SSE route only invalidates
        // FTL-mesh freshness, it does not re-read the device — so a bare wait
        // can sit on a stale row for the whole deadline and then stall on a
        // relay that came up fine.
        if world.now.timeIntervalSince(relay.updatedAt) > Self.pollInterval {
            return .refreshDevices(deviceCodes: [relay.deviceCode], thenStall: nil)
        }
        return .wait
    }

    /// Confirm the run's actual deliverable: the TARGET SYSTEM is meshed.
    ///
    /// Stated in terms of the goal rather than the device, which is a different
    /// claim from `confirmingRelay`'s: a relay can report `relaying` at a
    /// location in the wrong system (a mis-aimed emplacement, a stale row from a
    /// previous errand) and grow nobody's frontier where this run was sent.
    ///
    /// Read through DEVICE rows — `SalvageTargetPlanner.meshSystems(in:)`, the
    /// same predicate `Device.isActiveRelay` uses — and never through
    /// `ftlLinks`: a just-activated relay has produced no link rows yet, so a
    /// link-based read would report failure on a perfect run.
    private func settle(_ directive: Directive, _ world: WorldSnapshot) -> MissionAction {
        guard let target = directive.currentTarget else { return .done }
        guard SalvageTargetPlanner.meshSystems(in: Array(world.devices.values)).contains(target) else {
            logger.notice("relay run \(directive.id, privacy: .public): \(target, privacy: .public) still reads as unmeshed after activation")
            return .stall(.relayActivationFailed)
        }
        logger.info("relay run \(directive.id, privacy: .public): \(target, privacy: .public) is meshed")
        return .done
    }
}
