//
//  RelayRun.swift
//  Replicould — DirectiveEngine
//
//  Grows the FTL mesh by one system: acquire a relay, stow it aboard the
//  carrier, fly to the target's Lagrange point, deploy, activate in-situ,
//  confirm the mesh grew. One-shot — a run meshes exactly one system and
//  finishes.
//
//  Two sources converge at `stowing`: `sourceRelayCode` nil PRINTS a fresh
//  relay at the hub; non-nil RECLAIMS the named one. The reclaim path
//  requires a carrier hosting a replicant — unexpressible in these types,
//  so `carrierRetainsAuthority` gates the `stow` on the server's own
//  `in_control_range`.
//
//  Pure: no I/O, no clock reads (time is `world.now`), no randomness.
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
    public var firstStep: String { Step.acquire }

    /// The total-stock floor this run's print step checks before spending, or
    /// nil to leave the rail unarmed — an unarmed rail has no opinion on stock
    /// and never vetoes.
    ///
    /// A PROXY for `BrainCeiling`'s true per-type reserve, not that reserve
    /// itself: `LocationFootprint` carries one TOTAL holdings count and no
    /// per-type breakdown, so `BrainCeiling.aggregateSpendFloor` stands in — and
    /// it is deliberately NOT the sum of the six per-type floors, which
    /// undershoots badly. `printStockIsShort` is the one place that changes when
    /// a per-type stockpile record exists.
    public let reserveFloor: Int?

    public init(reserveFloor: Int? = BrainCeiling.aggregateSpendFloor) {
        self.reserveFloor = reserveFloor
    }

    /// This mission's step vocabulary. Plain strings because `Directive.step` is
    /// untyped — each kind owns its own vocabulary.
    ///
    /// `deactivating`/`confirmingIdle`, `stowing`/`confirmingStow`,
    /// `emplacing`→`activating` and `activating`/`confirmingRelay` are
    /// dispatch/poll pairs: each command carries no `Operation` row, so the
    /// dispatching step must hand off to a separate polling step. See
    /// `trackedKinds` for why that split is mandatory.
    ///
    /// The two sources meet at `stowing` — the print path arrives via
    /// `printing`, the reclaim path via `confirmingIdle` — and everything from
    /// there to `settling` is one shared tail.
    public enum Step {
        /// Decide where the relay comes from, and start it coming. Branches on
        /// `Directive.sourceRelayCode`: nil prints a fresh one at the hub,
        /// non-nil reclaims the existing one it names.
        public static let acquire = "acquire"
        /// Poll for the printed clone to appear in the fleet.
        public static let printing = "printing"
        /// RECLAIM PATH. Fly the carrier to where the source relay stands,
        /// BEFORE anything irreversible happens to it. Travel is a tracked
        /// kind, so this step may re-dispatch into itself.
        public static let fetching = "fetching"
        /// RECLAIM PATH. Dispatch `deactivate` at the source relay.
        /// Dispatch-only.
        public static let deactivating = "deactivating"
        /// RECLAIM PATH. Poll for the source relay to stop relaying. Split from
        /// `deactivating` because `deactivate` is classified `.immediate` by
        /// `CommandClient` and carries no `Operation` row.
        public static let confirmingIdle = "confirmingIdle"
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
        /// `SalvageRun.activationDeadline`. Split from `activating` because
        /// `activate` is immediate and carries no `Operation` row.
        public static let confirmingRelay = "confirmingRelay"
        /// Confirm the run's actual deliverable: the TARGET SYSTEM is meshed.
        public static let settling = "settling"
        /// Fly the carrier back to the hub so the next run can use it. Entered
        /// from `settling` only when the run carries `returnToOrigin`.
        public static let returning = "returning"
    }

    // MARK: - Constants

    /// The device type this run plants.
    public static let relayDeviceType = SalvageRun.relayDeviceType

    /// The kinds this machine dispatches that DO create an `Operation` row.
    ///
    /// A `.simple` verb (`deactivate`, `stow`, `deploy`, `activate`) creates no
    /// row, so `world.openOperation(for:)` is permanently nil for it — a guard
    /// that can never fire — while `DirectiveExecutor.apply` re-stamps
    /// `stepStartedAt` on every accepted dispatch. A `.simple` dispatch whose
    /// `nextStep` is its OWN step therefore re-issues the command every tick
    /// forever, against a deadline that can never accumulate. A TRACKED kind's
    /// operation row IS that missing guard, so `travelling`/`emplacing` may
    /// legitimately redispatch travel into themselves. See the
    /// `same-step-dispatch-needs-tracked-op` note.
    public static let trackedKinds: Set<OperationKind> = [.travel, .print]

    /// How long to let a print take before surfacing. Generous by a wide margin:
    /// it exists for the print that never happens (a dropped `print.completed`,
    /// a job dequeued by hand, a queue that never reached this job), not for a
    /// slow one.
    public static let printDeadline: TimeInterval = 30 * 60

    /// How long to let a `stow` take. Immediate server-side, so all this covers
    /// is the confirm-read that proves it.
    public static let stowDeadline: TimeInterval = 5 * 60

    /// How old the hub's row may be and still be believed. Same value and
    /// reasoning as `SalvageRun.stagingFreshness`: a positive finding read off a
    /// local row is worth only as much as the row.
    public static let hubFreshness: TimeInterval = 5 * 60

    /// How long to let a `deactivate` take. Immediate server-side like `stow`,
    /// so all this covers is the confirm-read that proves it.
    public static let reclaimDeadline: TimeInterval = stowDeadline

    /// How old the SOURCE relay's row may be and still authorise tearing that
    /// relay down — the same "how old may a POSITIVE finding be and still be
    /// believed" bound as `hubFreshness`, under its own name because the two may
    /// reasonably diverge: one gates a spend that can be re-earned, this one
    /// gates the teardown of working infrastructure.
    public static let reclaimFreshness: TimeInterval = hubFreshness

    /// Floor between confirm-reads while a poll step waits.
    public static let pollInterval: TimeInterval = SalvageRun.relayPollInterval

    // MARK: - Entry

    public func nextAction(directive: Directive, world: WorldSnapshot) -> MissionAction {
        guard let carrier = world.device(directive.deviceCode) else {
            return .stall(.unreachableDevice)
        }
        switch directive.step {
        case Step.acquire: return acquire(directive, carrier, world)
        case Step.printing: return printing(directive, carrier, world)
        case Step.fetching: return fetch(directive, carrier, world)
        case Step.deactivating: return deactivateSource(directive, carrier, world)
        case Step.confirmingIdle: return confirmIdle(directive, carrier, world)
        case Step.stowing: return stowing(directive, carrier, world)
        case Step.confirmingStow: return confirmStow(directive, carrier, world)
        case Step.travelling: return travel(directive, carrier, world)
        case Step.emplacing: return emplace(directive, carrier, world)
        case Step.activating: return activate(directive, carrier, world)
        case Step.confirmingRelay: return confirmRelay(directive, carrier, world)
        case Step.settling: return settle(directive, world)
        case Step.returning: return returnHome(directive, carrier, world)
        default:
            // An unrecognised step must never dispatch. Waiting is inert and
            // recoverable — the user can cancel, or the step ships.
            logger.notice("relay run \(directive.id, privacy: .public): unknown step \(directive.step, privacy: .public) — waiting")
            return .wait
        }
    }

    /// A Relay Run is one-shot: the brain launches a fresh directive per target,
    /// so an emptied queue ends THIS run rather than cueing a roam, whatever
    /// `context` holds.
    public func plan(_ context: RoamContext) -> RoamPlan { .exhausted }

    // MARK: - Fleet queries

    /// The print hub this run may use: a print-capable device in `world` at
    /// `carrier`'s own location, or nil where the carrier stands beside none.
    ///
    /// Co-location is the whole composition: the clone materialises at the
    /// printer, and only a carrier already standing there can take it aboard, so
    /// a hub elsewhere deliberately does not match. `Device.isPrintHub` keys off
    /// `enqueue_print` in `availableCommands` rather than on device type, so it
    /// matches a printer at a BELT location without this file knowing what an
    /// autofactory is.
    ///
    /// **The carrier is considered last.** A HEAVEN vessel advertises
    /// `enqueue_print` too and may legitimately print into its own hold, but it
    /// must never SHADOW a dedicated printer standing beside it — which a
    /// tie-break on device code alone cannot guarantee.
    static func hub(near carrier: Device, in world: WorldSnapshot) -> Device? {
        guard let location = carrier.location else { return nil }
        let printers = world.devices.values
            .filter { $0.isPrintHub && $0.location == location }
        return printers
            .filter { $0.deviceCode != carrier.deviceCode }
            .min { $0.deviceCode < $1.deviceCode }
            ?? printers.min { $0.deviceCode < $1.deviceCode }
    }

    /// The device code of the clone this run printed, read off the completed
    /// `enqueue_print` operation in `world`.
    ///
    /// Print completion is detected by OPERATION RESULT, never by "a relay
    /// appeared near the hub": a hub holding idle spares would have one of THOSE
    /// read as this run's clone, skipping the print and flying away with a relay
    /// the run never acquired. `WorldSnapshot.dispatchedOperations` is scoped to
    /// the ops this directive's own log names, so this can never pick up
    /// somebody else's print.
    static func printedRelayCode(in world: WorldSnapshot) -> String? {
        world.dispatchedOperations.values
            .filter { $0.kind == OperationKind.print.rawValue && $0.status == .completed }
            .max { $0.lastConfirmedAt < $1.lastConfirmedAt }?
            .detail["result"]?["new_device_code"]?.stringValue
    }

    /// The device a completed print in `world` named, **only if it is actually
    /// a relay**.
    ///
    /// The type check is the whole safety of the code-first lookup. The hub's
    /// print queue is SHARED and never leased, and `Reconciler.completeOpenOperation`
    /// closes *the single open op on the hub device*, filing that event's
    /// `new_device_code` onto it — so a job finishing AHEAD of ours closes OUR
    /// operation row and stamps ITS device code as our clone. Unfiltered,
    /// `stowing` would `stow` that foreign live device onto our carrier and
    /// `travelling` would haul it to another system.
    static func printedRelay(in world: WorldSnapshot) -> Device? {
        guard let code = printedRelayCode(in: world), let device = world.device(code) else { return nil }
        guard device.deviceType == relayDeviceType else { return nil }
        return device
    }

    /// The status a printed-but-unplanted relay wears.
    static let idleRelayStatus = "inactive"

    /// The status a planted, live relay wears — the sibling of
    /// `idleRelayStatus` and the one thing `activate` and `confirmRelay` must
    /// agree about. They are a dispatch/poll pair over the same command: if the
    /// step that decides "already up, hand off" and the step that decides
    /// "up, move on" could ever disagree, a run would bounce between them.
    static let relayingStatus = "relaying"

    /// Relays in `world` standing at `location` that belong to nobody: the right
    /// type, at rest, in nothing's hold — **the pool this capability draws its
    /// stock from**, ordered by device code.
    ///
    /// Ownership is decided by the CLAIM (`claimableRelay`) rather than by
    /// provenance, so a run never has to prove a relay is *its* clone — only
    /// that nobody else has taken it. That is what makes a superseded print op
    /// survivable: the relay still arrives, and whoever is next in line takes
    /// it. `stowedInDeviceCode == nil` is the "unclaimed" test, sufficient
    /// because a run claims by STOWING; `!isBusy` keeps a relay mid-command out.
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

    /// Where `directive` stands in the line of Relay Runs, read off `world`,
    /// waiting for stock at `location` (0 = next) — **the FIFO rule, and the
    /// whole of the claim's safety.**
    ///
    /// Relay Runs evaluate as independent `Task`s on independent clocks and
    /// nothing above them serialises the claim, so without an ordering rule two
    /// runs waiting at one hub would `stow` the same relay and one would lose to
    /// a server rejection. Each run instead computes the same queue from the
    /// same snapshot and takes the relay at its own position (`claimableRelay`).
    /// Ordering is by `createdAt` with the id as tie-break — **the run that has
    /// waited longest gets the first relay** — a stable total order, so
    /// independent runs compute it identically.
    ///
    /// Peers count only if they are (a) Relay Runs, (b) still moving, (c)
    /// actually waiting for stock, no relay aboard yet, and (d) waiting at THIS
    /// hub. A run that already has its relay is out of the queue, which is what
    /// lets the line advance.
    ///
    /// **`.paused` holds no place in line**, the one status where
    /// `Brain.owningStatuses` and this queue deliberately disagree: a paused run
    /// still OWNS its carrier, but it is stopped by operator choice and may be
    /// stopped indefinitely, so counting it would let one paused run at the head
    /// starve every other run at that hub. `.needsAttention` IS counted: halted
    /// but live, one `retry` from moving.
    static func queuePosition(_ directive: Directive, at location: String, in world: WorldSnapshot) -> Int {
        let waiting = world.peers
            .filter { peer in
                guard peer.kind == .relayRun else { return false }
                guard peer.status == .running || peer.status == .needsAttention else { return false }
                guard let carrier = world.device(peer.deviceCode), carrier.location == location else { return false }
                return SalvageRun.relay(aboard: carrier, in: world) == nil
            }
            .sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
        // Not in the list means nothing to defer to: either this run is alone,
        // or `peers` is empty because the snapshot was built without it (every
        // pure-function test). Head of a queue of one.
        return waiting.firstIndex { $0.id == directive.id } ?? 0
    }

    /// The relay `directive` may take off `location`'s pool in `world` right
    /// now, if any.
    ///
    /// **Claims by queue POSITION, not "the first one"** — the oldest waiting run
    /// takes the lowest-code relay, the second-oldest the next. Concurrent runs
    /// therefore claim DISJOINT relays and two `stow` commands issued in the same
    /// instant cannot contend, and three spares at the hub serve three runs on
    /// the same tick rather than queueing behind stock that is already there.
    ///
    /// Returning nil means "no stock for me" — the caller prints. That is the
    /// only condition under which this capability spends resources.
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

    /// Why `printing` never got a relay, judged off `world`, for the one log
    /// line the stall emits.
    ///
    /// The superseded case most needs naming: if anything else dispatches a
    /// print at the shared hub after this run does, `CommandClient` supersedes
    /// our row, and `.superseded` is neither `.completed` nor open — so
    /// `printedRelayCode` stays nil and `printInFlight` reads false. Fail-safe
    /// (no loop, no spend), but it degrades to a silent wait and then a stall
    /// whose display name ("No relay aboard") names neither cause nor remedy.
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

    /// The relay `directive` is moving, wherever in `world` it currently is,
    /// with `carrier` as the vessel hauling it.
    ///
    /// Resolution order matters. A relay named by CODE — `sourceRelayCode` on a
    /// reclaim run, the print result on a print run — stays resolvable through
    /// every state change the run puts it through (deployed, inactive, stowed,
    /// in-transit with no location, deployed again, relaying), which the
    /// location- and stow-based lookups each stop answering partway through;
    /// that is why the shared tail needs no reclaim-specific fork. The fallbacks
    /// cover the run that never printed: one already staged aboard the carrier,
    /// one claimed off the hub pool, or one standing where the carrier stands.
    ///
    /// Every lookup filters on `deviceType`. Each caller issues a command at
    /// what this returns, so a `sourceRelayCode` naming a mining drone must
    /// resolve to nothing rather than to that drone.
    static func relay(for directive: Directive, carrier: Device, in world: WorldSnapshot) -> Device? {
        if let code = directive.sourceRelayCode,
           let source = world.device(code),
           source.deviceType == relayDeviceType {
            return source
        }
        if let printed = printedRelay(in: world) { return printed }
        // Aboard BEFORE the pool: once a relay is in the hold it is settled, and
        // asking the pool first at a hub that still has spares standing on it
        // would resolve a DIFFERENT relay than the one this run is carrying.
        if let aboard = SalvageRun.relay(aboard: carrier, in: world) { return aboard }
        // The pool claim, so `stowing` issues its command at exactly the relay
        // `acquire`/`printing` decided to take — stable across the two steps,
        // since the run holds its place in line until it has a relay aboard and
        // the pool is ordered by device code. Queue-checked, unlike the
        // co-location fallback below it.
        if let location = carrier.location,
           let claimed = claimableRelay(directive, at: location, in: world) {
            return claimed
        }
        return SalvageRun.deployedRelay(near: carrier, in: world)
    }

    /// Whether `world`'s stockpile CENSUS — the whole `LocationFootprint` table,
    /// not just the hub's own row — is too old to trust for the reserve check.
    ///
    /// **Deliberately the whole table, never `world.footprints[location]`
    /// alone.** `LocationsClient.refreshFootprint` upserts every location the
    /// API returns in ONE request, so a genuinely-refreshing census advances
    /// EVERY row's `fetchedAt` together. Gating on the table's max therefore
    /// turns "the census refreshed and still doesn't list the hub" into POSITIVE
    /// EVIDENCE: `acquire` falls through to `printStockIsShort`, which vetoes
    /// and stalls. A per-location gate has no such terminating case —
    /// `.refreshFootprint(nextStep: Step.acquire)` self-loops, and
    /// `DirectiveExecutor.move` re-stamps `stepStartedAt` on every re-entry, so
    /// a persistently-missing row is re-requested every tick forever.
    ///
    /// It cannot see a PRESENT hub row that stops being refreshed while other
    /// locations keep the table fresh; that gap is closed at READ time, by
    /// `printStockIsShort`'s `hubFreshness` bound. Bounded to at most one
    /// refresh per `pollInterval`.
    func footprintCensusIsStale(_ world: WorldSnapshot) -> Bool {
        guard let newest = world.footprints.values.map(\.fetchedAt).max() else { return true }
        return world.now.timeIntervalSince(newest) > Self.pollInterval
    }

    /// Whether the reserve rail vetoes a print at `location`, judged off
    /// `world`'s census.
    ///
    /// **Fails CLOSED on unreadable stock once armed — deliberately not
    /// "unknown is never short."** An unarmed rail (`reserveFloor == nil`) has
    /// no opinion and never vetoes. Once armed, a MISSING census row for
    /// `location` is not evidence the stock is fine — it is evidence nobody has
    /// told us — so it vetoes too: the print is a real, irreversible spend, and
    /// "we couldn't read the stock" is not permission to make it. A stall here
    /// is not a dead end: `.printStockShort` carries `BrainDisposition.retry`.
    ///
    /// **A PRESENT-but-old row for `location` is caught too**, on the separate
    /// and more generous `Self.hubFreshness`. `footprintCensusIsStale` is
    /// table-wide, so it proves the census was refreshed SOMEWHERE recently,
    /// never that THIS location was; without this check a hub that stops
    /// appearing in later refreshes would have an arbitrarily old `resources`
    /// reading trusted and permit a print on stale "abundance". It is a
    /// read-time veto that never requests a refresh, so it cannot reopen the
    /// self-loop `footprintCensusIsStale` describes.
    ///
    /// Reads the location's TOTAL holdings, all `LocationFootprint` carries. The
    /// rail is specified per RESOURCE TYPE (see `BrainCeiling`), and this is the
    /// one place that changes when the per-type stockpile record lands.
    func printStockIsShort(at location: String, _ world: WorldSnapshot) -> Bool {
        guard let floor = reserveFloor else { return false }
        guard let footprint = world.footprints[location] else { return true }
        if world.now.timeIntervalSince(footprint.fetchedAt) > Self.hubFreshness { return true }
        return footprint.resources < floor
    }

    /// WHICH of `printStockIsShort`'s three conditions vetoed a print at
    /// `location` in `world`, for the one log line the stall emits — in the same
    /// branch order that function tests them, so the two can only ever agree.
    ///
    /// A single "stock below floor" line would be FALSE on two of the three
    /// branches: a missing census row has no reading to be below anything, and a
    /// stale row's reading may sit comfortably ABOVE the floor and still veto on
    /// its AGE alone — sending an operator after a shortage that does not exist
    /// instead of at a census that stopped listing the hub.
    func printStockShortDiagnosis(at location: String, _ world: WorldSnapshot) -> String {
        let floorText = reserveFloor.map(String.init) ?? "unarmed"
        guard let footprint = world.footprints[location] else {
            return "no census row for it at all (floor \(floorText))"
        }
        // Compared unrounded — `printStockIsShort` compares the raw interval,
        // and rounding before the comparison would disagree with it inside the
        // half-second either side of the bound. Rounded only for display.
        let age = world.now.timeIntervalSince(footprint.fetchedAt)
        if age > Self.hubFreshness {
            return """
                its census row is \(Int(age.rounded()))s old, past the \(Int(Self.hubFreshness))s freshness bound \
                — the reading it carries (\(footprint.resources)) is not trusted, whatever it says
                """
        }
        return "stock \(footprint.resources) below floor \(floorText)"
    }

    // MARK: - Acquire

    /// Where `directive`'s relay comes from, and the command that starts it
    /// coming, with `carrier` as the vessel that will hold it and `world` as the
    /// snapshot every check reads.
    ///
    /// Two branches by `Directive.sourceRelayCode`: nil PRINTS a fresh relay at
    /// the hub; non-nil names an existing, useless relay to RECLAIM and
    /// redeploy, which costs nothing. The branches never fall through into one
    /// another — falling through to the print would spend resources the plan had
    /// already decided to source for free — which is also why the reserve rail
    /// below is unreachable from the reclaim path.
    private func acquire(_ directive: Directive, _ carrier: Device, _ world: WorldSnapshot) -> MissionAction {
        if let source = directive.sourceRelayCode {
            return reclaim(directive, carrier, world, source: source)
        }
        // A relay already aboard is a relay this run does not have to print.
        // Also what makes a relaunch mid-run idempotent.
        if SalvageRun.relay(aboard: carrier, in: world) != nil {
            return .advanceStep(nextStep: Step.travelling)
        }
        // A spare standing here is a relay this run does not have to print.
        // Checked BEFORE the hub lookup so it holds even where the printer has
        // gone away, and before the reserve rail because taking existing stock
        // spends nothing the rail exists to protect.
        if let location = carrier.location,
           let spare = Self.claimableRelay(directive, at: location, in: world) {
            logger.notice("relay run \(directive.id, privacy: .public): claiming idle relay \(spare.deviceCode, privacy: .public) at \(location, privacy: .public) — no print needed")
            return .advanceStep(nextStep: Step.stowing)
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
        // The reserve rail is a VETO, so it sits BEFORE the command it vetoes;
        // checking after the dispatch would surface a stall about resources
        // already committed. A stale CENSUS is not evidence either way, so
        // refresh it first — and only when the rail is armed.
        //
        // `thenStall: .printStockShort` — unlike `HaulRun.survey`'s `nil`, this
        // MUST escalate on a persistently-unreadable census: it gates a real,
        // irreversible spend, so "we still can't read it" has to reach
        // `BrainDisposition.retry`'s bounded-retry-then-escalate rather than
        // retry forever. `nextStep: Step.acquire` documents the shape but is
        // never reached, because a `thenStall` is always given.
        if reserveFloor != nil, footprintCensusIsStale(world) {
            return .refreshFootprint(nextStep: Step.acquire, thenStall: .printStockShort)
        }
        if let location = hub.location, printStockIsShort(at: location, world) {
            // The most safety-relevant veto in this capability, so it leaves a
            // trace naming the condition that actually fired. One line, no flood
            // risk: a stall halts the run rather than re-entering this branch
            // every tick.
            let why = printStockShortDiagnosis(at: location, world)
            logger.notice("relay run \(directive.id, privacy: .public): print stock short at \(location, privacy: .public) — \(why, privacy: .public)")
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

    /// Poll `world` for `directive`'s printed clone to become a device row, or
    /// for a relay `carrier` may claim off the hub pool.
    ///
    /// Split from `acquire` even though `print` is a tracked kind, because the
    /// completion this waits for is not the operation closing but the CLONE
    /// arriving — two facts that land in separate transactions.
    private func printing(_ directive: Directive, _ carrier: Device, _ world: WorldSnapshot) -> MissionAction {
        // The positive first: a clone that is IN the fleet and IS a relay. The
        // type check is what stops a shared-queue mix-up being adopted — see
        // `printedRelay(in:)`.
        if Self.printedRelay(in: world) != nil {
            return .advanceStep(nextStep: Step.stowing)
        }
        // Our own op is not the only way a relay arrives. `CommandClient`
        // supersedes any other open op on the shared hub, so a run whose print
        // was superseded can never resolve a clone by code even though the
        // server printed it and it is standing right there. Claiming off the
        // pool makes that survivable. Queue-ordered, so it cannot jump the line.
        if let location = carrier.location,
           let spare = Self.claimableRelay(directive, at: location, in: world) {
            logger.notice("relay run \(directive.id, privacy: .public): claiming relay \(spare.deviceCode, privacy: .public) from the hub pool at \(location, privacy: .public)")
            return .advanceStep(nextStep: Step.stowing)
        }
        // Deadline BEFORE the read (`confirm-steps-need-fresh-evidence`): the
        // read below only advances on success, so a staleness-first ordering
        // would never reach the backstop while reads keep failing.
        if world.now.timeIntervalSince(directive.stepStartedAt) > Self.printDeadline {
            logger.notice("relay run \(directive.id, privacy: .public): print produced no relay — \(Self.printDiagnosis(in: world), privacy: .public)")
            return .stall(.noRelayCoLocated)
        }
        if Self.printInFlight(in: world) { return .wait }
        // The completion named a device the fleet has not got — the backstop for
        // `GameSync`'s own `.high` read off `print.completed` having failed. One
        // authoritative read of a named code is conclusive, so it carries a
        // stall rather than looping. Gated on the row being ABSENT, not merely
        // on the code existing: a row present but of the wrong type is already
        // as well-read as it will ever be, and falls through to the deadline.
        if let code = Self.printedRelayCode(in: world), world.device(code) == nil {
            return .refreshDevices(deviceCodes: [code], thenStall: .noRelayCoLocated)
        }
        return .wait
    }

    /// The loss to report when `directive` finds `target` already meshed, or nil
    /// when finishing there costs the mesh nothing.
    ///
    /// `travel`'s "somebody meshed this system while we were in flight" branch
    /// skips to `settling` and the run reports `.done`. On the PRINT path that
    /// is free money. On the RECLAIM path the run has already deactivated the
    /// source and de-meshed ITS system, so finishing here leaves the fleet one
    /// mesh node down and calls it success. It still finishes — the deliverable
    /// is genuinely met and the relay is preserved in the hold — but it must not
    /// be SILENT. A pure function rather than a bare log line, for the reason
    /// the other diagnoses are: `os.Logger` output is unreadable from a test.
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

    /// Whether `source` — the relay the plan named — is still a thing this run
    /// may reclaim.
    ///
    /// Four conditions, in the order `reclaimDiagnosis` explains them:
    ///
    /// - it is an `ftl_relay` — these are DISPATCH queries, and `deactivate` at
    ///   a mining drone because the plan hint named one is not a thing this run
    ///   may do;
    /// - it is stowed aboard nothing — a relay somebody else has taken aboard is
    ///   theirs, not ours;
    /// - it has a location — a relay in transit is somewhere unknowable, so
    ///   there is nothing to fly to and nothing to stand beside;
    /// - it is `relaying` — the deployed, active state prune actually judged. An
    ///   already-inactive relay is not the device that assessment covered.
    ///
    /// `statusBase`, never `status`: the backend appends a parenthetical
    /// parameter to some statuses, and a raw comparison would read a live relay
    /// as dead — here, tearing down infrastructure on a misparse.
    static func sourceIsReclaimable(_ source: Device) -> Bool {
        source.deviceType == relayDeviceType
            && source.stowedInDeviceCode == nil
            && source.location != nil
            && source.statusBase == "relaying"
    }

    /// WHICH condition disqualified the source relay `code` names in `world`,
    /// for the one log line the refusal emits — in the same branch order
    /// `sourceIsReclaimable` tests them, so the two can only ever agree.
    ///
    /// The stall's own display name ("Device unreachable") names neither cause
    /// nor remedy, and the four conditions want four different responses from an
    /// operator.
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

    /// The confirm-read every irreversible step of the reclaim path passes
    /// through: fresh evidence about the relay `code` names in `world`, before
    /// `directive` acts on it.
    ///
    /// Three answers, and the ordering is the point. A row that is ABSENT or too
    /// OLD is not evidence of anything — it buys ONE authoritative read,
    /// carrying a stall so a read that keeps failing surfaces after a single
    /// round instead of re-firing every tick. Only a row young enough to mean
    /// something is then judged.
    ///
    /// **A judgement that disqualifies the source STALLS.** It does not proceed,
    /// and — the more tempting mistake — it does not fall back to printing.
    /// Proceeding would `deactivate` a relay other than the one prune assessed,
    /// which is how a load-bearing relay gets torn out and its system's
    /// authority with it; falling back to the print would spend
    /// resources the plan declined to spend, on evidence the plan was WRONG.
    ///
    /// **The stall is NOT self-healing.** `.unreachableDevice` carries
    /// `BrainDisposition.retry`, and the brain retries the SAME directive with
    /// the SAME `sourceRelayCode` — it never re-plans the source, so a
    /// permanently disqualified source costs the whole retry budget and then an
    /// operator escalation, with the carrier leased throughout.
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

    /// Route `directive` — a reclaim-sourced run taking the relay `code` names,
    /// aboard `carrier` — into its own sub-sequence.
    ///
    /// No reserve rail runs on this path and none should: reclaim consumes no
    /// resources. That is structural rather than a flag — this returns before
    /// `acquire` reaches any footprint read at all.
    private func reclaim(
        _ directive: Directive, _ carrier: Device, _ world: WorldSnapshot, source code: String
    ) -> MissionAction {
        // Already aboard: the reclaim has happened and this is a re-entry.
        // Starting over would `deactivate` a relay that is currently cargo.
        //
        // Type-filtered like every other lookup here — without it a plan hint
        // naming a mining drone stowed aboard the carrier would skip the confirm
        // entirely and commit the run to hauling that drone to the target.
        if let aboard = world.device(code),
           aboard.deviceType == Self.relayDeviceType,
           aboard.stowedInDeviceCode == carrier.deviceCode {
            return .advanceStep(nextStep: Step.travelling)
        }
        switch Self.confirmSource(directive, code, world) {
        case let .act(action): return action
        // Confirmed — but the carrier still has to be standing with it before
        // anything is done to it, so the trip comes first. See `fetch`.
        case .confirmed: return .advanceStep(nextStep: Step.fetching)
        }
    }

    /// Fly `carrier` to where `directive`'s source relay stands in `world`,
    /// before anything irreversible happens to it.
    ///
    /// **The order is a safety property, not a convenience.** `deactivate` drops
    /// the relay's system out of the mesh, and per the `ftl-authority-rule` note
    /// command authority reaches a device only through a mesh subgraph holding a
    /// stationary replicant — so a relay deactivated from across the galaxy can
    /// become uncommandable at the very moment the run needs to `stow` it,
    /// stranding it AND having torn its system's link down for nothing.
    ///
    /// Deliberately does NOT re-confirm the source's freshness on every pass:
    /// this step is re-entered on every tick for the whole trip, and a freshness
    /// gate here would issue `.high` reads at that rate for minutes. The confirm
    /// sits at the two DECISION points instead — `acquire`, before the trip is
    /// committed, and `deactivating`, immediately before the irreversible act.
    private func fetch(_ directive: Directive, _ carrier: Device, _ world: WorldSnapshot) -> MissionAction {
        guard let code = directive.sourceRelayCode else {
            // Not a reclaim run at all. Re-derive the branch rather than act on
            // a source that does not exist — `acquire` is a pure function of
            // the same row, so this settles in one extra evaluation.
            return .advanceStep(nextStep: Step.acquire)
        }
        guard let source = world.device(code) else {
            return .refreshDevices(deviceCodes: [code], thenStall: .unreachableDevice)
        }
        guard let point = source.location else {
            logger.notice("relay run \(directive.id, privacy: .public): cannot fetch — \(Self.reclaimDiagnosis(code, world), privacy: .public)")
            return .stall(.unreachableDevice)
        }
        if carrier.location == point { return .advanceStep(nextStep: Step.deactivating) }
        // An open op means the trip is under way — the guard that stops a second
        // travel landing on top of the first. Travel is a TRACKED kind, which is
        // what makes re-dispatching into this same step safe (`trackedKinds`).
        if world.openOperation(for: carrier.deviceCode) != nil { return .wait }
        // …and the guard for the gap between that op closing and the arrival's
        // location write landing, in which the check above says "not there yet"
        // about a carrier that already is.
        if let unconfirmed = SalvageRun.travelPositionUnconfirmed(carrier, world) { return unconfirmed }
        return .dispatch(
            kind: .travel, deviceCode: carrier.deviceCode,
            params: CommandParams(destination: point), nextStep: Step.fetching
        )
    }

    /// Issue `deactivate` once at `directive`'s source relay, with `carrier`
    /// standing alongside it in `world`. Dispatch-only, deliberately.
    ///
    /// `deactivate` is a `.simple` verb, so the dispatch returns
    /// `.accepted(operationID: nil)` with NO `Operation` row and gets the same
    /// split every other `.simple` verb here gets: this step dispatches,
    /// `confirmingIdle` polls. Handing `nextStep` back to this step would
    /// re-issue `deactivate` at the live API every tick forever, against a
    /// deadline that could never accumulate.
    private func deactivateSource(
        _ directive: Directive, _ carrier: Device, _ world: WorldSnapshot
    ) -> MissionAction {
        guard let code = directive.sourceRelayCode else { return .advanceStep(nextStep: Step.acquire) }
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
            return .advanceStep(nextStep: Step.fetching)
        }
        return .dispatch(
            kind: OperationKind.simple("deactivate"), deviceCode: source.deviceCode,
            params: CommandParams(), nextStep: Step.confirmingIdle
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
        guard let code = directive.sourceRelayCode else { return .advanceStep(nextStep: Step.acquire) }
        guard let source = world.device(code) else { return .stall(.unreachableDevice) }
        // The stow already took (a lost step move, a relaunch). Nothing left to
        // confirm about a relay that is cargo.
        if source.stowedInDeviceCode == carrier.deviceCode {
            return .advanceStep(nextStep: Step.travelling)
        }
        // The success condition, stated as the inverse of the ONE mesh authority
        // this file recognises (`Device.isActiveRelay` and
        // `SalvageTargetPlanner.meshSystems`, both keyed on exactly `relaying`)
        // rather than as a fresh status string of its own. The deactivate having
        // taken means this system is now OFF the mesh, so the very next command
        // must clear the authority gate first — `carrierRetainsAuthority`.
        if source.statusBase != "relaying" { return carrierRetainsAuthority(directive, carrier, world) }
        // Deadline BEFORE the read (`confirm-steps-need-fresh-evidence`): the
        // read below only advances on success, so a staleness-first ordering
        // would never reach the backstop while reads keep failing.
        if world.now.timeIntervalSince(directive.stepStartedAt) > Self.reclaimDeadline {
            logger.notice("relay run \(directive.id, privacy: .public): \(code, privacy: .public) never stopped relaying after deactivate")
            return .stall(.unreachableDevice)
        }
        // Nothing else moves this row: `deactivate` emits no operation, and the
        // `relay.*` SSE route only invalidates FTL-mesh freshness. A bare wait
        // would sit on a stale row for the whole deadline and then stall on a
        // relay that is actually down.
        if world.now.timeIntervalSince(source.updatedAt) > Self.pollInterval {
            return .refreshDevices(deviceCodes: [code], thenStall: nil)
        }
        return .wait
    }

    /// The gate between the deactivate and the `stow` that follows it: can
    /// `carrier` still command anything at this system at all, per `world`?
    ///
    /// **This is the check the reclaim path's safety rests on.** Deactivating
    /// the source relay takes its system `S` off the mesh, so per the
    /// `ftl-authority-rule` note authority at `S` then comes only from rule (1),
    /// a replicant PHYSICALLY PRESENT — rule (2) being exactly what the
    /// deactivate destroyed. **The carrier must therefore HOST A REPLICANT**, a
    /// precondition nowhere in the types: `Directive` has no such field, and
    /// neither `WorldSnapshot` nor `WorldView` carries replicants at all. A run
    /// handed a carrier without one would issue `deactivate`, lose authority at
    /// `S`, and never issue the `stow`: relay and carrier stranded, permanently.
    ///
    /// So the gate asks the SERVER instead. `in_control_range` is the server's
    /// own authoritative answer to "can this be commanded", to be preferred over
    /// any geometry the app computes, and is what `brain-primitive-contracts`
    /// mandates for `deliver`'s tail. Permissive on a MISSING field, though:
    /// `Device.isOutOfControlRange` is `inControlRange == false`, so a device
    /// type that never reports it is not read as stranded — the gate catches
    /// only what the server affirmatively reports, and the file header states
    /// the precondition for the case it cannot see.
    ///
    /// **Keyed on a WATERMARK, not on age — young is not the same as AFTER.** An
    /// age bound alone reads the wrong row on the NORMAL timeline: `fetching`
    /// writes the carrier's row on arrival while the mesh is still up, so it
    /// reports `in_control_range: true` even for a carrier about to lose
    /// authority; `deactivating` then dispatches at the RELAY, and
    /// `CommandClient`'s `.immediate` path confirm-reads only the commanded
    /// device. `confirmingIdle` therefore normally sees a carrier row seconds
    /// old, far inside `reclaimFreshness`, and entirely PRE-deactivate.
    ///
    /// The row must post-date the command whose effect it is asked about:
    /// `carrier.updatedAt >= directive.stepStartedAt`, the rule
    /// `confirm-steps-need-fresh-evidence` states, and free because
    /// `DirectiveExecutor` re-stamps `stepStartedAt` on every accepted dispatch.
    /// The age bound stays alongside as the backstop for a row that post-dates
    /// the dispatch but has since gone unread for minutes. `thenStall` bounds
    /// the read to exactly one round.
    private func carrierRetainsAuthority(
        _ directive: Directive, _ carrier: Device, _ world: WorldSnapshot
    ) -> MissionAction {
        if carrier.updatedAt < directive.stepStartedAt
            || world.now.timeIntervalSince(carrier.updatedAt) > Self.reclaimFreshness {
            return .refreshDevices(deviceCodes: [carrier.deviceCode], thenStall: .unreachableDevice)
        }
        guard !carrier.isOutOfControlRange else {
            logger.notice("relay run \(directive.id, privacy: .public): \(carrier.deviceCode, privacy: .public) reports out of control range at \(carrier.location ?? "nowhere", privacy: .public) — the deactivate took this system off the mesh and nothing here can be commanded, so the stow is not dispatched")
            return .stall(.unreachableDevice)
        }
        return .advanceStep(nextStep: Step.stowing)
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
            return .advanceStep(nextStep: Step.travelling)
        }
        if world.now.timeIntervalSince(directive.stepStartedAt) > Self.stowDeadline {
            return .stall(.noRelayCoLocated)
        }
        // Nothing else moves this row: `stow` emits no operation and the stow
        // event's field application lands only if the event arrives at all. A
        // bare wait would sit on a stale row for the whole deadline and then
        // stall on a relay that is actually aboard.
        if world.now.timeIntervalSince(relay.updatedAt) > Self.pollInterval {
            return .refreshDevices(deviceCodes: [relay.deviceCode], thenStall: nil)
        }
        return .wait
    }

    // MARK: - Travel

    /// Fly `carrier` to `directive`'s target system, per `world`.
    private func travel(_ directive: Directive, _ carrier: Device, _ world: WorldSnapshot) -> MissionAction {
        guard let target = directive.currentTarget else { return .done }
        if SalvageRun.system(of: carrier) == target {
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
            return .advanceStep(nextStep: meshed ? Step.settling : Step.emplacing)
        }
        // An open op means the trip is under way — the guard that stops a second
        // travel landing on top of the first, which is exactly what a `.simple`
        // verb cannot have.
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

    /// What `directive` does about `target`, a system whose catalogue blob is
    /// not cached in `world`: wait, buy a bounded number of refreshes, then
    /// stall.
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

    /// Fly `carrier` the last hop to `directive`'s target Lagrange point in
    /// `world`, then deploy the relay there.
    ///
    /// A relay needs a gravitationally stable point (an L4/L5) to mesh its
    /// system, and every system's entry point is itself an L4 — where a
    /// bare-designation travel already landed the carrier, so the hop is usually
    /// free. `SalvageRun.lagrangePoint(in:)` is shared rather than re-derived: it
    /// is a fact about the game, not about salvage, and it encodes that the
    /// system-level locations endpoint returns no per-planet Lagrange sites.
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
            // catalogue cannot tell us where to plant.
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
        // Code-first resolution can hand back a relay ALREADY deployed here, if
        // this step is re-entered after a `deploy` whose step move was lost.
        // Re-issuing `deploy` at a deployed relay must be rejected — hand off to
        // activation instead. The mirror of `activate`'s own already-up guard.
        if relay.stowedInDeviceCode == nil, relay.location == point {
            return .advanceStep(nextStep: Step.activating)
        }
        // No `openOperation` guard: `deploy` is untracked, so the lookup is
        // always nil. The safety is that this hands off to a DIFFERENT step.
        return .dispatch(
            kind: OperationKind.simple("deploy"), deviceCode: relay.deviceCode,
            params: CommandParams(), nextStep: Step.activating
        )
    }

    /// Issue `activate` once at `directive`'s relay, in-situ and with `carrier`
    /// present, judged off `world`. Dispatch-only, deliberately.
    ///
    /// In-situ is not a preference: pre-activating a relay and then moving it
    /// does NOT mesh (`brain-primitive-contracts`). The relay comes up where it
    /// is going to stay.
    private func activate(_ directive: Directive, _ carrier: Device, _ world: WorldSnapshot) -> MissionAction {
        // `deploy` cleared the relay's `stowedInDeviceCode` the moment it
        // landed, so the aboard-query stops finding it at exactly the point this
        // step needs it — which is why `relay(for:carrier:in:)` resolves by code
        // first.
        guard let relay = Self.relay(for: directive, carrier: carrier, in: world) else {
            return .stall(.relayActivationFailed)
        }
        // Code-first resolution happily returns a STILL-STOWED relay, where a
        // location-based lookup could not (a stowed device has no location), so
        // the property that a failed `deploy` cannot reach the dispatch has to
        // be restored explicitly: activating cargo is not a thing this run may
        // do.
        guard relay.stowedInDeviceCode == nil else {
            logger.notice("relay run \(directive.id, privacy: .public): \(relay.deviceCode, privacy: .public) is still aboard \(carrier.deviceCode, privacy: .public) — deploy never took")
            return .stall(.relayActivationFailed)
        }
        // **Already up? Then hand off rather than command it again.** Without
        // this, an `activate` that reached the server but whose answer never
        // came back is retried into a correct "already active" rejection, which
        // the executor can only read as `commandRejected`: retry → dispatch →
        // reject → stall → retry, permanently, beside a relay that is `relaying`
        // the whole time. A rejection meaning "what you asked for is already
        // true" is this run's own work reported back to it, so the STATE is what
        // to read — not the command's answer, and not the server's prose, which
        // would make this a string match on a message the backend may reword.
        //
        // `statusBase`, not `status`: the backend appends a parenthetical
        // parameter to some statuses.
        if relay.statusBase == Self.relayingStatus {
            logger.info("relay run \(directive.id, privacy: .public): \(relay.deviceCode, privacy: .public) is already relaying — confirming rather than re-activating")
            return .advanceStep(nextStep: Step.confirmingRelay)
        }
        // The check above is only as good as the row it reads, and the window it
        // exists for is exactly the one where that row is WRONG: the command
        // landed, the client never learned, nothing has re-read the relay since.
        // So a row too old to trust buys a read before it buys a command — a
        // stale read is free to be wrong, a duplicate `activate` is not.
        // Bounded to one devices-refresh round per evaluation by `reAsk`'s
        // `paid` set.
        if world.now.timeIntervalSince(relay.updatedAt) > Self.pollInterval {
            return .refreshDevices(deviceCodes: [relay.deviceCode], thenStall: nil)
        }
        return .dispatch(
            kind: OperationKind.simple("activate"), deviceCode: relay.deviceCode,
            params: CommandParams(), nextStep: Step.confirmingRelay
        )
    }

    /// Poll `world` for the `activate` dispatched at `directive`'s relay,
    /// resolved through `carrier`, to take.
    ///
    /// Never dispatches. `activate` carries no operation row, so an
    /// `openOperation` check here could never be non-nil and could not stop a
    /// same-step redispatch — and a redispatching poll step would reset the very
    /// clock `activationDeadline` measures from, leaving a relay that never came
    /// up being `activate`d forever.
    private func confirmRelay(_ directive: Directive, _ carrier: Device, _ world: WorldSnapshot) -> MissionAction {
        guard let relay = Self.relay(for: directive, carrier: carrier, in: world) else {
            return .stall(.relayActivationFailed)
        }
        // `statusBase`, not `status`: the backend appends a parenthetical
        // parameter to some statuses, and a raw comparison would read a live
        // relay as dead.
        if relay.statusBase == Self.relayingStatus { return .advanceStep(nextStep: Step.settling) }
        if world.now.timeIntervalSince(directive.stepStartedAt) > SalvageRun.activationDeadline {
            return .stall(.relayActivationFailed)
        }
        // Nothing else moves this row — the `relay.*` SSE route only invalidates
        // FTL-mesh freshness — so a bare wait can sit on a stale row for the
        // whole deadline and then stall on a relay that came up fine.
        if world.now.timeIntervalSince(relay.updatedAt) > Self.pollInterval {
            return .refreshDevices(deviceCodes: [relay.deviceCode], thenStall: nil)
        }
        return .wait
    }

    /// Confirm `directive`'s actual deliverable in `world`: the TARGET SYSTEM is
    /// meshed.
    ///
    /// A different claim from `confirmingRelay`'s: a relay can report `relaying`
    /// at a location in the wrong system and grow nobody's frontier where this
    /// run was sent.
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
        guard directive.returnToOrigin else { return .done }
        return .advanceStep(nextStep: Step.returning)
    }

    /// Fly `carrier` back to the hub in `world`, so the next run can use it
    /// without a human ferrying it home.
    ///
    /// **The destination is the hub LOCATION, re-derived here — deliberately not
    /// `directive.originDesignation`.** That field is `SiteAssay.system(of: hub)`
    /// (see `Brain.launch`), a lossy projection to a bare SYSTEM designation,
    /// and a bare designation travels to the system's ENTRY POINT, an L4 — so
    /// returning to it lands the carrier in the right system but not co-located
    /// with the printer, while `Brain.freeCarrier` demands an exact match.
    /// Re-deriving through `WorldView.hubLocation` uses the SAME recognition
    /// rule the brain launches on, so the place this run flies to and the place
    /// the next run launches from cannot disagree.
    ///
    /// No hub to fly to is `.done`, not a stall: the relay is planted and the
    /// run's deliverable is met.
    private func returnHome(_ directive: Directive, _ carrier: Device, _ world: WorldSnapshot) -> MissionAction {
        guard let hub = Self.hubLocation(in: world) else {
            logger.notice("relay run \(directive.id, privacy: .public): no hub to return to — leaving the carrier where it stands")
            return .done
        }
        if carrier.location == hub { return .done }
        // The outbound leg's shape: an open op means the trip is under way and
        // guards against a second travel landing on top of the first, and
        // `travelPositionUnconfirmed` covers the gap between that op closing and
        // the arrival's location write landing.
        if world.openOperation(for: carrier.deviceCode) != nil { return .wait }
        if let unconfirmed = SalvageRun.travelPositionUnconfirmed(carrier, world) { return unconfirmed }
        return .dispatch(
            kind: .travel, deviceCode: carrier.deviceCode,
            params: CommandParams(destination: hub), nextStep: Step.returning
        )
    }

    /// The hub as the BRAIN recognises it, read off `world`, a mission's own
    /// snapshot.
    ///
    /// One rule, two callers: `WorldView.hubLocation` is the definition (a
    /// print-capable device at a meshed location the census shows holding
    /// resources), and this adapts a `WorldSnapshot` to it. A second copy of the
    /// rule here is exactly how the return leg would drift from the launch site.
    static func hubLocation(in world: WorldSnapshot) -> String? {
        let devices = Array(world.devices.values)
        return WorldView.hubLocation(
            in: devices,
            meshSystems: SalvageTargetPlanner.meshSystems(in: devices),
            stockByLocation: world.footprints.mapValues(\.resources)
        )
    }
}
