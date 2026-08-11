//
//  SalvageRun.swift
//  Replicould — DirectiveEngine
//
//  Fly a vessel from meshed salvage system to meshed salvage system, mining each
//  down. Continuous, with no coordination with the Haul Run that drains the piles
//  behind it. **Staging is the player's job** — the run uses an AMI controller
//  and drones ALREADY aboard, never stowing and never adopting, and stalls naming
//  whatever is absent. Pure: time comes from `world.now`, every effect is the
//  returned `MissionAction`.
//

import Foundation
import GameModels
import GameServices
import OSLog
import UniverseModels
import Utils

private let logger = Logger(subsystem: "name.pennig.replicould", category: "DirectiveEngine")

public struct SalvageRun: MissionStepMachine {
    public let kind: DirectiveKind = .salvageRun
    public var firstStep: String { Step.preflight }

    public init() {}

    /// This mission's step vocabulary, as the bare strings `Directive.step` holds.
    public enum Step {
        public static let preflight = "preflight"
        public static let travelling = "travelling"
        /// Put the service bots into the system so they repair the drones while the
        /// vessel tours its bodies. Deployed once per SYSTEM, not once per body:
        /// `service` is system-scoped and the bot cruises to each damaged device.
        public static let deployingBots = "deployingBots"
        /// Read whether the ordered deploy landed before ordering the next.
        public static let confirmingBotDeploy = "confirmingBotDeploy"
        /// Ensure each deployed bot carries an ACTIVE `service` directive.
        public static let armingBots = "armingBots"
        /// Read whether an ordered arm landed before ordering the next.
        public static let confirmingBotArm = "confirmingBotArm"
        /// Fly the VESSEL to the body it is about to work, so drones deploy locally
        /// rather than ferrying from a parked vessel. Runs BEFORE `configuring`.
        public static let positioning = "positioning"
        public static let configuring = "configuring"
        public static let launching = "launching"
        public static let awaiting = "awaiting"
        public static let verifying = "verifying"
        /// Hold the vessel while the service bots finish what they are repairing.
        public static let repairing = "repairing"
        /// Recall the deployed service bots before the vessel leaves the system.
        public static let stowingBots = "stowingBots"
        /// Read whether the ordered recall landed before ordering the next.
        public static let confirmingBotStow = "confirmingBotStow"
    }

    /// Step names outside this machine's vocabulary that must ADVANCE rather
    /// than wait. A row carrying one holds a fleet, and `default:` would park it.
    /// They re-enter at `preflight`, the only funnel that re-derives where the
    /// vessel is: one of them parks it at the hub, and every later step assumes
    /// the target system.
    static let retiredSteps: Set<String> = ["emplacing", "activating", "confirmingRelay", "restocking"]

    /// The tag a row falls back to when it carries none of its own.
    public static let defaultFleetTag = "auto:salvage"

    /// Anchors `.extendQueue`'s census read when a row carries no `roamCentre`, so
    /// a continuous run missing that optional field can still plan a target.
    public static let baseSystem = "AINALRAM"

    /// How old a row backing a POSITIVE staging finding may be and still be
    /// believed. Mining drones are AMI-adopted and so event-silent: one abandoned
    /// in another system keeps claiming it is aboard until something reads it.
    public static let stagingFreshness: TimeInterval = 5 * 60

    public static let activationDeadline: TimeInterval = 10 * 60

    /// How long a vessel row may lag the arrival it reflects, measured from the
    /// ARRIVAL and never `stepStartedAt`. Does NOT cover every route to the stall
    /// it guards — the reconciler drops an arrival's location write when a
    /// confirm-read stamps `updatedAt` later in the same wall-clock second, leaving
    /// a row fresh-but-wrong that passes every watermark computable here.
    public static let arrivalConfirmDeadline: TimeInterval = 5 * 60

    /// Floor between confirm-reads of the vessel row while waiting for its position
    /// to catch up. Without it the read fires on every 5s tick.
    public static let arrivalReadInterval: TimeInterval = 30

    /// How long to let an ordered bot deploy, arm or recall settle before the
    /// first read.
    public static let botProbeDelay: TimeInterval = 10

    /// Floor between bot-state probes, so an unmoving row is not re-read each tick.
    public static let botProbeInterval: TimeInterval = 30

    /// The cap on holding a vessel for repair before surfacing `repairUnfinished`.
    public static let repairDeadline: TimeInterval = 20 * 60

    /// The cap on a bot recall before the run surfaces `serviceBotNotRecovered`.
    public static let botRecallDeadline: TimeInterval = 20 * 60

    /// The cap on the controller's own flight back to the vessel before the run
    /// surfaces `miningControllerNotRecovered`. Its leg is a cross-system cruise
    /// from whichever body it was deployed at, so it is scaled like a bot recall.
    public static let controllerRecallDeadline: TimeInterval = 20 * 60

    /// The cap on a deploy or arm confirmation. Generous, but finite: without it
    /// a row that never refreshes buys one `.high` read every tick forever.
    public static let botConfirmDeadline: TimeInterval = 10 * 60

    /// The cap on dispatch rounds inside a bot deploy, arm or recall loop. A fleet
    /// of two bots needs two; the rest is slack for a command re-issued once.
    public static let botDispatchRounds = 6

    /// The salvage configuration this mission insists on: deplete `body`, then
    /// recall the drones so the vessel can move on. `recall` is load-bearing —
    /// the server holds `directive.completed` until the recall lands, which is
    /// what lets `verifying` be one confirming read rather than a timed wait.
    public static func salvageConfig(body: String) -> [String: JSONValue] {
        ["location": .string(body), "recall": .bool(true)]
    }

    /// The one action `directive` calls for against `world`, routed to the handler
    /// for its current step. An unrecognised step waits rather than dispatching.
    public func nextAction(directive: Directive, world: WorldSnapshot) -> MissionAction {
        guard let vessel = world.device(directive.deviceCode) else {
            return .stall(.unreachableDevice)
        }
        switch directive.step {
        case Step.preflight: return preflight(directive, vessel, world)
        case Step.travelling: return travel(directive, vessel, world)
        case Step.deployingBots: return deployBots(directive, vessel, world)
        case Step.confirmingBotDeploy: return confirmBotDeploy(directive, vessel, world)
        case Step.armingBots: return armBots(directive, vessel, world)
        case Step.confirmingBotArm: return confirmBotArm(directive, vessel, world)
        case Step.positioning: return position(directive, vessel, world)
        case Step.configuring: return configure(directive, vessel, world)
        case Step.launching: return launch(directive, vessel, world)
        case Step.awaiting: return awaitCompletion(directive, vessel, world)
        case Step.verifying: return verify(directive, vessel, world)
        case Step.repairing: return awaitRepair(directive, vessel, world)
        case Step.stowingBots: return stowBots(directive, vessel, world)
        case Step.confirmingBotStow: return confirmBotStow(directive, vessel, world)
        case let step where Self.retiredSteps.contains(step):
            return .advanceStep(nextStep: Step.preflight)
        default:
            // Waiting is inert and recoverable; guessing would command the fleet.
            logger.notice("salvage run \(directive.id, privacy: .public): unknown step \(directive.step, privacy: .public) — waiting")
            return .wait
        }
    }

    // MARK: - Fleet queries

    /// The AMI mining controller stowed aboard `vessel`, if any.
    public static func controller(aboard vessel: Device, in world: WorldSnapshot) -> Device? {
        AMIFleet.stowed(aboard: vessel, in: world, offering: "gather_salvage")
    }

    /// The drones `controller` has adopted that are also stowed aboard `vessel`.
    public static func adoptedDrones(
        of controller: Device, aboard vessel: Device, in world: WorldSnapshot
    ) -> [Device] {
        AMIFleet.adoptedDrones(of: controller, aboard: vessel, in: world)
    }

    /// The match every DISPATCH query below uses. Never widen one to the `relay`
    /// FEATURE: a `system_hub` carries it too, and a dispatch query gets `deploy`
    /// issued at whatever it returns.
    public static let relayDeviceType = "ftl_relay"

    /// The lowest-coded FTL relay stowed aboard `vessel`. A plain stow lookup, not
    /// an `AMIFleet` query — a relay is never adopted by a controller.
    public static func relay(aboard vessel: Device, in world: WorldSnapshot) -> Device? {
        world.devices.values
            .filter { $0.stowedInDeviceCode == vessel.deviceCode }
            .filter { $0.deviceType == relayDeviceType }
            .min { $0.deviceCode < $1.deviceCode }
    }

    /// The lowest-coded relay sitting at `vessel`'s own location per `world` — the
    /// one just deployed. Past `deploy`, resolve a relay by WHERE IT NOW IS and
    /// never by what is stowed: `deploy` clears `stowedInDeviceCode` the moment it
    /// lands, so `relay(aboard:in:)` stops finding it exactly when `activate`
    /// needs it.
    static func deployedRelay(near vessel: Device, in world: WorldSnapshot) -> Device? {
        guard let location = vessel.location else { return nil }
        return world.devices.values
            .filter { $0.deviceType == relayDeviceType && $0.location == location }
            .min { $0.deviceCode < $1.deviceCode }
    }

    /// The Lagrange point to emplace a relay at: `system`'s entry point when that
    /// is an L4, else one synthesised from the lowest planet designation. Never
    /// resolve from `system.planets.flatMap(\.lagrange)` — the system-level
    /// endpoint returns no per-planet Lagrange sites, so that reads empty for every
    /// normally-fetched system and silently forfeits emplacement on every target.
    static func lagrangePoint(in system: StarSystem?) -> String? {
        guard let system else { return nil }
        if let entry = system.entryPoint, entry.hasSuffix("-L4") { return entry }
        return system.planets.map(\.designation).sorted().first.map { "\($0)-L4" }
    }

    /// Whether any of `devices` is older than `stagingFreshness` against
    /// `world.now`. One stale row is enough: "everything needed is aboard" is a
    /// conjunction, so its weakest member decides what the whole claim is worth.
    static func stagingIsStale(_ devices: [Device], _ world: WorldSnapshot) -> Bool {
        devices.contains { world.now.timeIntervalSince($0.updatedAt) > stagingFreshness }
    }

    /// The star system `device` is currently in, or nil in transit / stowed.
    static func system(of device: Device) -> String? {
        device.location.map { SiteAssay.system(of: $0) }
    }

    /// `directive`'s theatre depot's SYSTEM. `RelayRun.theatreDepot` names a
    /// LOCATION, and a location in a roam-centre slot aims the census read at
    /// a site rather than a star.
    static func hubSystem(in world: WorldSnapshot, for directive: Directive) -> String? {
        RelayRun.theatreDepot(in: world, for: directive).map { SiteAssay.system(of: $0) }
    }

    /// Whether `controller` is actually working `gather_salvage`. The name alone
    /// is not enough — a paused directive mines nothing and never completes, so
    /// reading it as "in force" waits on an event that can never arrive.
    static func isMining(_ controller: Device) -> Bool {
        controller.currentDirective == "gather_salvage"
            && controller.currentDirectiveStatus == "active"
    }

    /// Whether `controller` holds a `gather_salvage` that is set but not running.
    static func isPaused(_ controller: Device) -> Bool {
        controller.currentDirective == "gather_salvage"
            && controller.currentDirectiveStatus == "paused"
    }

    // MARK: - Re-entry budget

    /// How many times `directive` has entered its CURRENT step without leaving in
    /// between — the durable attempt counter for a step whose only way forward is a
    /// read it must pay for again. The walk stops at an operator resolution and
    /// COUNTS it, so a Retry buys a genuinely new read. A step that re-enters itself
    /// via a tracked dispatch arrives with its budget already partly spent.
    static func stepEntryCount(_ directive: Directive, _ world: WorldSnapshot) -> Int {
        var count = 0
        for entry in world.log.reversed() {
            if entry.kind == .resolved {
                count += 1
                break
            }
            guard entry.kind == .stepStarted else { continue }
            // A different step ends this run of the current one.
            guard entry.step == directive.step else { break }
            count += 1
        }
        // A step reached before anything was ever logged (the first evaluation
        // of a fresh row) still counts as one visit.
        return max(count, 1)
    }

    // MARK: - Target planning

    /// Where the run goes next, ranked by `SalvageTargetPlanner` over MESHED
    /// systems only. An empty answer is `.idle`, never `.exhausted` — the
    /// frontier is a snapshot, not a limit. Never resolve this through
    /// `SurveyRoamPlanner`: its candidate filter is the exact inverse, so a run
    /// planned that way tours systems holding no salvage at all.
    public func plan(_ context: RoamContext) -> RoamPlan {
        let stars = Dictionary(
            context.stars.map { ($0.designation, $0) }, uniquingKeysWith: { first, _ in first }
        )
        guard let target = SalvageTargetPlanner.nextTarget(
            assays: context.assays,
            stars: stars,
            meshSystems: SalvageTargetPlanner.meshSystems(in: context.devices),
            attempted: context.attempted,
            vessel: context.vessel
        ) else { return .idle }
        return .target(target.system)
    }

    // MARK: - Steps

    /// Plan a target for `directive` if its queue is empty, else prove `vessel`'s
    /// staging in `world` is present and fresh before claiming the controller and
    /// departing.
    private func preflight(_ directive: Directive, _ vessel: Device, _ world: WorldSnapshot) -> MissionAction {
        // An exhausted queue is never `.done`, only the cue to plan the next
        // target. Checked BEFORE the staging guards so a fresh run with an empty
        // queue extends it rather than stalling over staging it has not reached.
        guard directive.currentTarget != nil else {
            let centre = directive.roamCentre
                ?? Self.system(of: vessel)
                ?? Self.hubSystem(in: world, for: directive)
                ?? Self.baseSystem
            return .extendQueue(centre: centre)
        }
        let tag = Self.fleetTag(directive)
        // Both staging checks are NEGATIVE findings over local rows: silence
        // means either nothing is aboard or nobody has been allowed to look, and
        // only the first is worth stopping for. `.refreshFleet` buys one
        // authoritative tag read before either counts as absence.
        guard let controller = Self.controller(aboard: vessel, in: world) else {
            return .refreshFleet(tag: tag, thenStall: .noMiningControllerAboard)
        }
        let drones = Self.adoptedDrones(of: controller, aboard: vessel, in: world)
        guard !drones.isEmpty else {
            return .refreshFleet(tag: tag, thenStall: .noMiningDroneAboard)
        }
        // Only a read can correct a stale POSITIVE. `.refreshFleet` because one
        // tag read covers vessel, controller and every drone, and is the only
        // scope that can see a stowed device at all.
        let stagingRows = [vessel, controller] + drones
        if Self.stagingIsStale(stagingRows, world) {
            return .refreshFleet(tag: tag, thenStall: .unreachableDevice)
        }
        return .assignController(deviceCode: controller.deviceCode, nextStep: Step.travelling)
    }

    // MARK: - Arrival freshness

    /// When the last travel this directive dispatched for `vessel` finished, or nil.
    /// Filters on `.completed` EXACTLY, never `isTerminal`: `.superseded` and
    /// `.unknown` also stamp `lastConfirmedAt` on travels that never arrived, and
    /// either would gate a real dispatch behind an arrival that never happened.
    static func lastTravelCompletion(for vessel: Device, _ world: WorldSnapshot) -> Date? {
        world.dispatchedOperations.values
            .lazy
            .filter {
                $0.entityCode == vessel.deviceCode
                    && $0.kind == OperationKind.travel.rawValue
                    && $0.status == .completed
            }
            .map(\.lastConfirmedAt)
            .max()
    }

    /// What a travel dispatch site should do when `vessel`'s row cannot yet be
    /// trusted to say where it is; nil means dispatch may proceed. One
    /// `travel.arrived` settles in two transactions — the op closes first, the
    /// location is written second — so a tick in that gap re-commands travel at an
    /// already-parked vessel. The watermark is the ARRIVAL, never `stepStartedAt`.
    ///
    /// **The order of the three answers is mandated:** deadline, throttled read,
    /// `.wait`. The throttle measures `updatedAt`, which only advances on a
    /// SUCCESSFUL read, so a staleness-first ordering never stalls and issues a
    /// `.high` read every tick under the rate-limit exhaustion that caused it.
    ///
    /// **Gates the dispatch path only** — place it after the `openOperation` guard
    /// and never above the location-equality check, which delays every advance.
    static func travelPositionUnconfirmed(_ vessel: Device, _ world: WorldSnapshot) -> MissionAction? {
        // Nothing to post-date, so cold runs and first entries dispatch at once.
        guard let completion = Self.lastTravelCompletion(for: vessel, world) else { return nil }
        guard vessel.updatedAt < completion else { return nil }
        if world.now.timeIntervalSince(completion) >= Self.arrivalConfirmDeadline {
            return .refreshDevices(deviceCodes: [vessel.deviceCode], thenStall: .vesselPositionUnconfirmed)
        }
        if world.now.timeIntervalSince(vessel.updatedAt) > Self.arrivalReadInterval {
            return .refreshDevices(deviceCodes: [vessel.deviceCode], thenStall: nil)
        }
        return .wait
    }

    /// Fly `vessel` to `directive`'s current target system, then put the service
    /// bots out. The target is already meshed — the planner offers no other kind.
    private func travel(_ directive: Directive, _ vessel: Device, _ world: WorldSnapshot) -> MissionAction {
        guard let target = directive.currentTarget else {
            return .advanceStep(nextStep: Step.preflight)
        }
        if Self.system(of: vessel) == target {
            return .advanceStep(nextStep: Step.deployingBots)
        }
        // An open op means the trip is under way; waiting stops a second travel
        // landing on top of the first.
        if world.openOperation(for: vessel.deviceCode) != nil { return .wait }
        // The equality check above misreads a row still lagging the arrival.
        if let unconfirmed = Self.travelPositionUnconfirmed(vessel, world) { return unconfirmed }
        return .dispatch(
            kind: .travel, deviceCode: vessel.deviceCode,
            params: CommandParams(destination: target), nextStep: Step.travelling
        )
    }

    /// Floor between confirm-reads of a relay row while a mission polls one.
    /// Read by `RelayRun`, which owns every relay the fleet plants.
    public static let relayPollInterval: TimeInterval = 60

    // MARK: - Mining loop

    /// The controller `directive` claimed, re-resolved from `world` on every
    /// evaluation and falling back to whatever is stowed aboard `vessel` for a row
    /// that claimed none. Never cache it: a controller since released or
    /// decommissioned must surface as nil rather than be dispatched at.
    private func claimedController(_ directive: Directive, _ vessel: Device, _ world: WorldSnapshot) -> Device? {
        guard let code = directive.controllerCode else {
            return Self.controller(aboard: vessel, in: world)
        }
        return world.device(code)
    }

    /// What resolving the next salvage body found. "Nothing left to mine" and
    /// "don't know yet" must stay distinct: they collapse to the same `nil` if
    /// left unstructured, and every caller that reads the second as the first
    /// advances off a system that may still hold salvage.
    enum NextBodyResolution: Equatable {
        /// A live body to configure toward.
        case body(String)
        /// The target system is cached and holds no live salvage body — drained,
        /// or never worth mining. Also the outcome when the queue itself is
        /// exhausted, which `.advanceTarget` handles safely by resetting to
        /// `preflight` and its own queue-exhausted check.
        case finished
        /// The target system's `SystemDetail` blob isn't cached yet — the row
        /// hasn't landed, or failed to decode. NOT evidence the system is done;
        /// the caller must wait for it rather than advance.
        case unresolved
    }

    /// The next salvage body to work in `directive`'s current target system per
    /// `world`: the richest one still holding salvage, by assayed units then
    /// designation.
    ///
    /// Re-derived on every evaluation rather than stored as a cursor, because a
    /// cursor drifts the moment anything else depletes a site.
    static func nextBody(in directive: Directive, world: WorldSnapshot) -> NextBodyResolution {
        guard let target = directive.currentTarget else { return .finished }
        guard let system = world.system(target) else { return .unresolved }
        // `salvageBodies(totals:)` already excludes depleted sites, which is what
        // makes an empty result mean "system finished" now that "system absent" is
        // its own case above. The totals must be passed: without them
        // `unitsRemaining` and `discoveredTotal` are nil for every body and the
        // ranking collapses to the designation tiebreak.
        guard let body = system.salvageBodies(totals: world.siteAssays)
            .max(by: { lhs, rhs in
                // `unitsRemaining` is nil until live percentages have been
                // fetched, which is the COMMON case, so fall back to the
                // historical `discoveredTotal`; falling back to 0 instead ranks
                // every unhydrated body last and picks the least valuable target.
                let l = lhs.unitsRemaining ?? lhs.discoveredTotal ?? 0
                let r = rhs.unitsRemaining ?? rhs.discoveredTotal ?? 0
                // `max(by:)` wants "lhs strictly precedes rhs"; ties break on
                // designation so the pick is reproducible across evaluations.
                return l == r ? lhs.designation > rhs.designation : l < r
            })?.designation
        else { return .finished }
        return .body(body)
    }

    /// Whether the in-force `config` already equals `salvageConfig(body:)` for
    /// `body` on the two fields that matter. Compared field by field, never
    /// whole-object: the server may echo extra keys, and an inequality there is
    /// not a reason to re-issue. Re-issuing is the default and only an exact match
    /// on both fields skips it, so a leftover `location` from manual use cannot
    /// silently work the wrong body.
    static func configMatches(_ config: JSONValue?, body: String) -> Bool {
        guard let config else { return false }
        return config["location"]?.stringValue == body && config["recall"]?.boolValue == true
    }

    /// How long a step may wait on the target system's catalogue blob before
    /// surfacing `salvageSystemUnresolved`. The vessel's arrival already triggers
    /// `LocationsIngestion`'s passive rescan independent of this mission, so this
    /// backstops that never landing rather than the expected path.
    public static let systemResolutionDeadline: TimeInterval = 10 * 60

    /// How many `locations/{star}` reads an unresolved-system backstop may spend
    /// per visit before it surfaces. One is enough: the read is authoritative, so
    /// a blob it fails to produce will not appear by waiting longer.
    public static let systemRefreshAttempts = 1

    /// What `emplace`, `configure` and `verify` all do about an uncached `target`:
    /// wait out `systemResolutionDeadline`, spend one `.refreshSystem`, then stall.
    /// The ORDER is the point — `.wait` is the only action leaving `stepStartedAt`
    /// alone, so refreshing on every pass resets the clock the backstop measures.
    /// The read sits past the deadline because a bare stall there is unrecoverable:
    /// Retry fetches nothing, so it would re-run a pure function over the identical
    /// stale snapshot forever.
    private func unresolvedSystem(
        _ directive: Directive, _ world: WorldSnapshot, target: String
    ) -> MissionAction {
        if world.now.timeIntervalSince(directive.stepStartedAt) <= Self.systemResolutionDeadline {
            return .wait
        }
        if Self.stepEntryCount(directive, world) <= Self.systemRefreshAttempts {
            return .refreshSystem(designation: target, nextStep: directive.step)
        }
        return .stall(.salvageSystemUnresolved)
    }

    /// Fly `vessel` to the body it is about to work, so drones deploy locally. Keyed
    /// off `nextBody`, NOT the controller's in-force config: nothing writes
    /// `currentDirectiveConfig` optimistically, so that row names the PREVIOUS body
    /// until a re-issued `set_directive` lands and would mis-target every
    /// transition. Owns the first look at the target system, so it inherits
    /// `configure`'s `.finished`/`.unresolved` handling verbatim.
    private func position(_ directive: Directive, _ vessel: Device, _ world: WorldSnapshot) -> MissionAction {
        switch Self.nextBody(in: directive, world: world) {
        case .finished:
            return .advanceStep(nextStep: Step.repairing)
        case .unresolved:
            guard let target = directive.currentTarget else {
                return .advanceStep(nextStep: Step.repairing)
            }
            return unresolvedSystem(directive, world, target: target)
        case let .body(body):
            if vessel.location == body { return .advanceStep(nextStep: Step.configuring) }
            // `.travel` is tracked, so this guard actually fires and the same-step
            // re-dispatch is safe.
            if world.openOperation(for: vessel.deviceCode) != nil { return .wait }
            // The hop to the first body is short, so a tick right after the arrival
            // op closes lands inside the window where `location` still lags.
            if let unconfirmed = Self.travelPositionUnconfirmed(vessel, world) { return unconfirmed }
            return .dispatch(
                kind: .travel, deviceCode: vessel.deviceCode,
                params: CommandParams(destination: body), nextStep: Step.positioning
            )
        }
    }

    /// Point the controller `directive` claimed on `vessel` at the next salvage
    /// body in `world`, re-issuing `set_directive` unless the in-force config
    /// already names that exact body.
    private func configure(_ directive: Directive, _ vessel: Device, _ world: WorldSnapshot) -> MissionAction {
        switch Self.nextBody(in: directive, world: world) {
        case .finished:
            // Nothing live left in this system. Checked FIRST, mirroring
            // `preflight`'s queue-before-staging order: a target with nothing left
            // must advance regardless of whether the fleet is still staged for a
            // step it will never take. `verifying` routes a finished body back
            // here, so this is also what recognises "nothing left" on the return.
            return .advanceStep(nextStep: Step.repairing)

        case .unresolved:
            // The catalogue blob hasn't landed, which must NEVER read as
            // "finished" (see `NextBodyResolution`). The vessel's arrival already
            // triggers a passive rescan, so waiting is the expected path.
            guard let target = directive.currentTarget else {
                return .advanceStep(nextStep: Step.repairing)
            }
            return unresolvedSystem(directive, world, target: target)

        case let .body(body):
            guard let controller = claimedController(directive, vessel, world) else {
                return .stall(.noMiningControllerAboard)
            }
            guard Self.configMatches(controller.currentDirectiveConfig, body: body),
                  controller.currentDirective == "gather_salvage"
            else {
                return .dispatch(
                    kind: .setDirective, deviceCode: controller.deviceCode,
                    params: CommandParams(directive: "gather_salvage", configuration: Self.salvageConfig(body: body)),
                    nextStep: Step.launching
                )
            }
            // Right directive, right body, but not running: `activate` is what
            // starts it. Re-sending the name would never touch the status.
            guard Self.isMining(controller) else {
                return .dispatch(
                    kind: OperationKind.simple("activate"), deviceCode: controller.deviceCode,
                    params: CommandParams(), nextStep: Step.launching
                )
            }
            return .advanceStep(nextStep: Step.launching)
        }
    }

    /// Issue `launch` once at the controller `directive` claimed on `vessel`, per
    /// `world`, then hand to `awaiting`. Dispatch-only: `launch` is
    /// `OperationKind.simple` and creates no `Operation` row, so a same-step
    /// redispatch guard could never fire and the redispatch would reset
    /// `stepStartedAt` on every tick. All polling lives in `awaitCompletion`.
    private func launch(_ directive: Directive, _ vessel: Device, _ world: WorldSnapshot) -> MissionAction {
        guard let controller = claimedController(directive, vessel, world) else {
            return .stall(.noMiningControllerAboard)
        }
        return .dispatch(
            kind: OperationKind.simple("launch"), deviceCode: controller.deviceCode,
            params: CommandParams(), nextStep: Step.awaiting
        )
    }

    /// Floor between reconciling reads while `awaiting` waits out a mining cycle.
    /// The throttle is also what stops a persistently failing read from looping on
    /// every tick.
    public static let reconcileInterval: TimeInterval = 2 * 60

    /// When the LAST of the `stranded` drones is due back, or nil if none reports
    /// a trip. `activityDeadline` resolves the travel block's leg-vs-route pair,
    /// so a recall hop yields its real arrival rather than a leg boundary.
    static func recallArrival(_ stranded: [Device]) -> Date? {
        stranded.compactMap(\.activityDeadline).max()
    }

    /// Tolerance when comparing a completion's time against the step's start.
    /// Same value as `SurveyRun.eventTimeSkewTolerance`.
    static let eventTimeSkewTolerance: TimeInterval = 5

    /// Whether a completion for `directive`'s CURRENT step has landed in
    /// `world.log`. Issue-time relative, not wall-clock, so a completion delivered
    /// by catch-up after the app was closed still counts while a replay does not.
    public static func completionSeen(_ directive: Directive, _ world: WorldSnapshot) -> Bool {
        saw(.directiveCompleted, directive, world)
    }

    /// Whether a launch reporting zero deployed devices landed in `directive`'s
    /// current step per `world`. Such a launch can never produce the completion
    /// `awaiting` polls for, so this turns a permanent wait into a named stall.
    public static func emptyLaunchSeen(_ directive: Directive, _ world: WorldSnapshot) -> Bool {
        saw(.launchDeployedNothing, directive, world)
    }

    /// Whether an entry of `kind` in `world.log` belongs to `directive`'s current
    /// step, within `eventTimeSkewTolerance` of its start.
    private static func saw(
        _ kind: DirectiveLogKind, _ directive: Directive, _ world: WorldSnapshot
    ) -> Bool {
        world.log.contains { entry in
            entry.kind == kind
                && entry.occurredAt >= directive.stepStartedAt
                    .addingTimeInterval(-eventTimeSkewTolerance)
        }
    }

    /// Wait until `directive`'s mining cycle is actually done, THEN hand to
    /// `verify`. Never stalls here — `directive.completed` is authoritative and the
    /// only real failure is a dropped frame, so every fallback is a reconciling read
    /// rather than a blind timer. **Never bound this with a fixed timer**: cycles
    /// routinely run past ten minutes, and a timed advance dumps into `verify`
    /// mid-mining, which false-stalls `dronesNotRecovered` every cycle.
    ///
    /// The freshness gate is keyed off the DRONE rows alone (`min`). AMI drones are
    /// event-silent, so the controller's row is fresh moments after `launch` while
    /// its drones are still stale pre-launch rows — a `max` would let that fresh
    /// controller vouch for them and read a deployed fleet as recovered.
    private func awaitCompletion(_ directive: Directive, _ vessel: Device, _ world: WorldSnapshot) -> MissionAction {
        if Self.completionSeen(directive, world) {
            return .advanceStep(nextStep: Step.verifying)
        }
        // The launch deployed nothing, so no completion is ever coming.
        if Self.emptyLaunchSeen(directive, world) { return .stall(.launchDeployedNothing) }

        guard let controller = claimedController(directive, vessel, world) else { return .wait }
        // An empty adoption drops `lastLook` to `.distantPast` so this polls rather
        // than advancing — asymmetric with `verify`, which reads empty-stranded as
        // recovered. `emptyLaunchSeen` already caught the genuine no-drones case, so
        // an empty adoption here means it vanished mid-cycle.
        let drones = AMIFleet.adoptedDrones(of: controller, in: world)
        let lastLook = drones.map(\.updatedAt).min() ?? .distantPast
        let canRead = world.now.timeIntervalSince(lastLook) >= Self.reconcileInterval

        // Never believe a row read BEFORE this step began: a pre-launch drone row
        // still shows it stowed aboard and reads as "recovered" the instant the
        // step starts. Force a post-launch read of EVERY drone first, throttled so
        // a failing one cannot loop every tick.
        guard lastLook >= directive.stepStartedAt else {
            return canRead ? .refreshFleet(tag: Self.fleetTag(directive), thenStall: nil) : .wait
        }

        let stranded = drones.filter { $0.stowedInDeviceCode != vessel.deviceCode }
        // A dropped completion frame: the drones are already home, nothing said so.
        if stranded.isEmpty { return .advanceStep(nextStep: Step.verifying) }
        // Still mining — the drones are out by design. Reconcile on a cadence to
        // catch completion (or the controller going idle); never stall, however
        // long the cycle runs.
        if Self.isMining(controller) {
            return canRead ? .refreshFleet(tag: Self.fleetTag(directive), thenStall: nil) : .wait
        }
        // Set but not running, drones out: no completion is ever coming, so the
        // reconcile above would wait forever. Prove it on a fresh read, then name it.
        if Self.isPaused(controller) {
            return canRead
                ? .refreshFleet(tag: Self.fleetTag(directive), thenStall: .miningDirectivePaused)
                : .wait
        }
        // Mining done, drones still out: a post-mining recall (near-instant now
        // the vessel sits at the body). Wait out any traveller's own ETA; re-read
        // the stragglers on the cadence otherwise.
        if stranded.contains(where: { $0.activityDeadline != nil }) {
            if let arrival = Self.recallArrival(stranded), arrival > world.now { return .wait }
            return canRead
                ? .refreshDevices(deviceCodes: stranded.map(\.deviceCode), thenStall: nil)
                : .wait
        }
        // None travelling, none aboard, mining finished — they aren't coming on
        // their own. Hand to `verify`, which refreshes once and raises
        // `dronesNotRecovered` if the fresh rows agree.
        return .advanceStep(nextStep: Step.verifying)
    }

    // MARK: - Service bots

    /// Deploy the next service bot still aboard `vessel`, or move on when the
    /// system already has them all. Exhausting the round budget costs the repair
    /// and not the salvage; a REJECTED deploy still stalls the run.
    private func deployBots(_ directive: Directive, _ vessel: Device, _ world: WorldSnapshot) -> MissionAction {
        let aboard = RepairFleet.bots(aboard: vessel, in: world, owner: Self.fleetTag(directive))
        guard let next = aboard.first else { return .advanceStep(nextStep: Step.armingBots) }
        // `deploy` is untracked and the confirm step re-stamps `stepStartedAt`, so
        // the log is the only bound on this loop that re-entry cannot rewind.
        if MissionLogBudget.dispatchRounds(
            world, dispatch: Step.deployingBots, confirm: Step.confirmingBotDeploy
        ) > Self.botDispatchRounds {
            logger.notice("salvage run \(directive.id, privacy: .public): \(next.deviceCode, privacy: .public) will not deploy — mining unrepaired")
            return .advanceStep(nextStep: Step.armingBots)
        }
        return .dispatch(
            kind: .simple("deploy"), deviceCode: next.deviceCode,
            params: CommandParams(), nextStep: Step.confirmingBotDeploy
        )
    }

    /// One throttled read of `rows` when any predates the step, or nil when they
    /// are fresh enough to judge. Callers must check their deadline FIRST — a
    /// failing read never advances `updatedAt`, so a staleness-first order loops.
    private static func probe(
        _ rows: [Device], _ directive: Directive, _ world: WorldSnapshot
    ) -> MissionAction? {
        guard rows.contains(where: { $0.updatedAt < directive.stepStartedAt }) else { return nil }
        let lastLook = rows.map(\.updatedAt).min() ?? .distantPast
        if world.now.timeIntervalSince(lastLook) < Self.botProbeInterval { return .wait }
        return .refreshDevices(deviceCodes: rows.map(\.deviceCode), thenStall: nil)
    }

    /// Judge an ordered deploy, looping back for the next bot until none is aboard.
    private func confirmBotDeploy(_ directive: Directive, _ vessel: Device, _ world: WorldSnapshot) -> MissionAction {
        let owner = Self.fleetTag(directive)
        let elapsed = world.now.timeIntervalSince(directive.stepStartedAt)
        if elapsed < Self.botProbeDelay { return .wait }
        if elapsed > Self.botConfirmDeadline {
            logger.notice("salvage run \(directive.id, privacy: .public): bot deploy unconfirmed — mining unrepaired")
            return .advanceStep(nextStep: Step.armingBots)
        }
        let aboard = RepairFleet.bots(aboard: vessel, in: world, owner: owner)
        guard aboard.isEmpty else {
            // A row unread since the deploy was ordered cannot yet show it
            // landing; buy the read rather than believing a stale claim.
            return Self.probe(aboard, directive, world)
                ?? .advanceStep(nextStep: Step.deployingBots)
        }
        // `armingBots` judges the DEPLOYED rows, and nothing has read them since
        // the deploy was ordered — a stale one reads armed and skips repair.
        let deployed = RepairFleet.bots(deployedNear: vessel.location, in: world, owner: owner)
        return Self.probe(deployed, directive, world) ?? .advanceStep(nextStep: Step.armingBots)
    }

    /// Ensure the next mis-armed deployed bot carries an ACTIVE `service`
    /// directive: `set_directive` when the name is wrong, `activate` when the name
    /// is right but paused. The run SETS the directive rather than inheriting one.
    private func armBots(_ directive: Directive, _ vessel: Device, _ world: WorldSnapshot) -> MissionAction {
        let deployed = RepairFleet.bots(
            deployedNear: vessel.location, in: world, owner: Self.fleetTag(directive)
        )
        guard let next = deployed.first(where: { !RepairFleet.isArmed($0) }) else {
            return .advanceStep(nextStep: Step.positioning)
        }
        // Both dispatches below are untracked and the confirm step re-stamps
        // `stepStartedAt`, so the log is the only bound re-entry cannot rewind.
        if MissionLogBudget.dispatchRounds(
            world, dispatch: Step.armingBots, confirm: Step.confirmingBotArm
        ) > Self.botDispatchRounds {
            logger.notice("salvage run \(directive.id, privacy: .public): \(next.deviceCode, privacy: .public) will not arm")
            return .stall(.serviceBotNotArmed)
        }
        guard next.currentDirective == "service" else {
            return .dispatch(
                kind: .setDirective, deviceCode: next.deviceCode,
                params: CommandParams(directive: "service"), nextStep: Step.confirmingBotArm
            )
        }
        return .dispatch(
            kind: OperationKind.simple("activate"), deviceCode: next.deviceCode,
            params: CommandParams(), nextStep: Step.confirmingBotArm
        )
    }

    /// Judge an ordered arm, looping back for the next mis-armed bot until none is left.
    private func confirmBotArm(_ directive: Directive, _ vessel: Device, _ world: WorldSnapshot) -> MissionAction {
        let elapsed = world.now.timeIntervalSince(directive.stepStartedAt)
        if elapsed < Self.botProbeDelay { return .wait }
        if elapsed > Self.botConfirmDeadline { return .stall(.serviceBotNotArmed) }
        let deployed = RepairFleet.bots(
            deployedNear: vessel.location, in: world, owner: Self.fleetTag(directive)
        )
        // "Everything is armed" is the conclusion that skips repair entirely, so
        // it needs the same proof the mis-armed one does.
        if let probe = Self.probe(deployed, directive, world) { return probe }
        guard deployed.contains(where: { !RepairFleet.isArmed($0) }) else {
            return .advanceStep(nextStep: Step.positioning)
        }
        return .advanceStep(nextStep: Step.armingBots)
    }

    /// Hold `vessel` while any deployed service bot is still repairing. Gated on
    /// the bots falling IDLE, never a capacity threshold — `service` repairs to an
    /// unquantified level a threshold gate could wait on forever.
    private func awaitRepair(_ directive: Directive, _ vessel: Device, _ world: WorldSnapshot) -> MissionAction {
        let owner = Self.fleetTag(directive)
        // A nil location cannot answer the system-scoped query, so it is
        // uncertainty — but only where a bot is actually out there to lose.
        guard let location = vessel.location else {
            guard RepairFleet.anyBotDeployed(
                in: world, system: directive.currentTarget, owner: owner
            ) else {
                return .advanceStep(nextStep: Step.stowingBots)
            }
            let elapsed = world.now.timeIntervalSince(directive.stepStartedAt)
            if elapsed > Self.repairDeadline { return .stall(.repairUnfinished) }
            if world.now.timeIntervalSince(vessel.updatedAt) < Self.botProbeInterval { return .wait }
            return .refreshDevices(deviceCodes: [vessel.deviceCode], thenStall: nil)
        }
        let bots = RepairFleet.bots(deployedNear: location, in: world, owner: owner)
        if bots.isEmpty { return .advanceStep(nextStep: Step.stowingBots) }
        // A fleet nothing is worn enough to hold for leaves without paying the
        // probe delay or a single read.
        if !RepairFleet.needsRepair(RepairFleet.fleet(of: vessel, in: world, owner: owner)) {
            return .advanceStep(nextStep: Step.stowingBots)
        }

        let elapsed = world.now.timeIntervalSince(directive.stepStartedAt)
        if elapsed < Self.botProbeDelay { return .wait }
        if elapsed > Self.repairDeadline { return .stall(.repairUnfinished) }
        // Bots repair silently server-side; an unread row cannot be trusted to
        // report idle, so treat it as still working until a read says otherwise.
        let stale = bots.contains { $0.updatedAt < directive.stepStartedAt }
        if !stale, !bots.contains(where: RepairFleet.isRepairing) {
            return .advanceStep(nextStep: Step.stowingBots)
        }
        let lastLook = bots.map(\.updatedAt).min() ?? .distantPast
        if world.now.timeIntervalSince(lastLook) < Self.botProbeInterval { return .wait }
        return .refreshDevices(deviceCodes: bots.map(\.deviceCode), thenStall: nil)
    }

    /// Recall the next service bot still out in the system, or advance the target
    /// when none is left. `recall`, not `stow`: `stow` needs the bot beside the
    /// vessel, and a bot that cruised off to repair a drone is not.
    private func stowBots(_ directive: Directive, _ vessel: Device, _ world: WorldSnapshot) -> MissionAction {
        let owner = Self.fleetTag(directive)
        guard let location = vessel.location else {
            guard RepairFleet.anyBotOut(
                in: world, system: directive.currentTarget, owner: owner
            ) else {
                return .advanceTarget
            }
            if world.now.timeIntervalSince(directive.stepStartedAt) > Self.botRecallDeadline {
                return .stall(.serviceBotNotRecovered)
            }
            if world.now.timeIntervalSince(vessel.updatedAt) < Self.botProbeInterval { return .wait }
            return .refreshDevices(deviceCodes: [vessel.deviceCode], thenStall: nil)
        }
        let out = RepairFleet.botsOut(near: location, in: world, owner: owner)
        guard let next = out.first else { return .advanceTarget }
        if MissionLogBudget.dispatchRounds(
            world, dispatch: Step.stowingBots, confirm: Step.confirmingBotStow
        ) > Self.botDispatchRounds {
            return .stall(.serviceBotNotRecovered)
        }
        if RepairFleet.openRecall(for: next.deviceCode, in: world) != nil {
            if world.now.timeIntervalSince(directive.stepStartedAt) > Self.botRecallDeadline {
                return .stall(.serviceBotNotRecovered)
            }
            return .wait
        }
        return .dispatch(
            kind: .simple("recall"), deviceCode: next.deviceCode,
            params: CommandParams(), nextStep: Step.confirmingBotStow
        )
    }

    /// Judge an ordered recall, looping back for the next bot until none is out.
    private func confirmBotStow(_ directive: Directive, _ vessel: Device, _ world: WorldSnapshot) -> MissionAction {
        let owner = Self.fleetTag(directive)
        let elapsed = world.now.timeIntervalSince(directive.stepStartedAt)
        if elapsed < Self.botProbeDelay { return .wait }
        if elapsed > Self.botRecallDeadline { return .stall(.serviceBotNotRecovered) }
        guard let location = vessel.location else {
            guard RepairFleet.anyBotOut(
                in: world, system: directive.currentTarget, owner: owner
            ) else {
                return .advanceTarget
            }
            if world.now.timeIntervalSince(vessel.updatedAt) < Self.botProbeInterval { return .wait }
            return .refreshDevices(deviceCodes: [vessel.deviceCode], thenStall: nil)
        }
        let out = RepairFleet.botsOut(near: location, in: world, owner: owner)
        if out.isEmpty { return .advanceTarget }
        // A recall cruises the bot home, so wait out its own arrival time.
        if let arrival = Self.recallArrival(out), arrival > world.now { return .wait }
        if out.contains(where: { $0.updatedAt < directive.stepStartedAt }) {
            let lastLook = out.map(\.updatedAt).min() ?? .distantPast
            if world.now.timeIntervalSince(lastLook) < Self.botProbeInterval { return .wait }
            return .refreshDevices(deviceCodes: out.map(\.deviceCode), thenStall: nil)
        }
        return .advanceStep(nextStep: Step.stowingBots)
    }

    // MARK: - Verify & restock

    /// The fleet tag `directive` resolves against, falling back to
    /// `defaultFleetTag` for a row that carries none of its own. Every step naming
    /// a tag for `.refreshFleet` goes through this, so the fallback lives once.
    static func fleetTag(_ directive: Directive) -> String {
        directive.fleetTag ?? Self.defaultFleetTag
    }

    /// Confirm the recall landed before letting the run go anywhere, then decide the
    /// next body. Stalls rather than departing without a drone. ONE confirming read,
    /// never ETA-driven polling: a `recall` config holds `directive.completed` until
    /// the drones finish travelling, so a stranded-looking drone is far more likely
    /// a stale row than a real loss.
    private func verify(_ directive: Directive, _ vessel: Device, _ world: WorldSnapshot) -> MissionAction {
        guard let controller = claimedController(directive, vessel, world) else {
            // A vanished controller is preflight's diagnosis to make; stalling here
            // would name the wrong problem.
            return .advanceStep(nextStep: Step.repairing)
        }
        // The WIDE query, not the aboard-vessel one: "some drones are home" is
        // precisely the state that loses the others.
        let stranded = AMIFleet.adoptedDrones(of: controller, in: world)
            .filter { $0.stowedInDeviceCode != vessel.deviceCode }
        if !stranded.isEmpty {
            return .refreshFleet(tag: Self.fleetTag(directive), thenStall: .dronesNotRecovered)
        }
        // The controller flies its own recall leg, and `directive.completed`
        // tracks the DRONES, so it is routinely still airborne here. Departing
        // now leaves it chasing the vessel, and the stow ending that chase
        // pauses whatever `set_directive` landed meanwhile.
        if let waiting = controllerNotAboard(controller, vessel, directive, world) { return waiting }
        guard let target = directive.currentTarget else {
            return .advanceStep(nextStep: Step.repairing)
        }
        switch Self.nextBody(in: directive, world: world) {
        case .finished:
            return .advanceStep(nextStep: Step.repairing)
        case let .body(body):
            // More bodies here — unless the next one is what the cycle that just
            // ended was already working.
            guard body != Self.workedBody(controller) else {
                return sameBodyAgain(directive, world, target: target, body: body)
            }
            return .advanceStep(nextStep: Step.positioning)
        case .unresolved:
            // Must NEVER read as `.finished`. Same backstop as `emplace`.
            return unresolvedSystem(directive, world, target: target)
        }
    }

    /// How to wait for `controller` to get back aboard `vessel`, or nil once it
    /// is. Deadline BEFORE the staleness guard: a read that keeps failing never
    /// advances `updatedAt`, so the other order makes the escape unreachable.
    private func controllerNotAboard(
        _ controller: Device, _ vessel: Device, _ directive: Directive, _ world: WorldSnapshot
    ) -> MissionAction? {
        guard controller.stowedInDeviceCode != vessel.deviceCode else { return nil }
        if world.now.timeIntervalSince(directive.stepStartedAt) > Self.controllerRecallDeadline {
            return .stall(.miningControllerNotRecovered)
        }
        if let arrival = controller.activityDeadline, arrival > world.now { return .wait }
        if world.now.timeIntervalSince(controller.updatedAt) < Self.arrivalReadInterval { return .wait }
        return .refreshDevices(deviceCodes: [controller.deviceCode], thenStall: nil)
    }

    /// The body `controller`'s in-force `gather_salvage` config names, or nil when
    /// there is no "same body" to compare against. Read from the CONTROLLER rather
    /// than the directive row — it is the server's own record, so it survives a
    /// relaunch with no column and no migration.
    static func workedBody(_ controller: Device) -> String? {
        guard controller.currentDirective == "gather_salvage" else { return nil }
        return controller.currentDirectiveConfig?["location"]?.stringValue
    }

    /// How many per-body reads the loop may spend on a body that came back
    /// unchanged before surfacing it. One: the read is authoritative.
    public static let bodyProgressAttempts = 1

    /// How long `verify` waits before treating a still-on-offer worked body as
    /// evidence: the `salvage.depleted` frame and the roster both lag the drones'
    /// real finish, so a read spent sooner asks a server not yet caught up.
    public static let depletionPropagationGrace: TimeInterval = 5 * 60

    /// The mining loop's terminator, ordered grace → one `.refreshBody` → stall.
    /// The per-body read, never `.refreshSystem`: the server DELISTS a depleted
    /// site, and only the per-body endpoint's roster can observe the absence.
    private func sameBodyAgain(
        _ directive: Directive, _ world: WorldSnapshot, target: String, body: String
    ) -> MissionAction {
        if world.now.timeIntervalSince(directive.stepStartedAt) <= Self.depletionPropagationGrace {
            return .wait
        }
        if Self.stepEntryCount(directive, world) <= Self.bodyProgressAttempts {
            return .refreshBody(system: target, body: body, nextStep: Step.verifying)
        }
        return .stall(.salvageBodyNotDepleted, detail: body)
    }

}
