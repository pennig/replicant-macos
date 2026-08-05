//
//  SalvageRun.swift
//  Replicould — DirectiveEngine
//
//  Fly a vessel from salvage system to salvage system, mining each one down and
//  planting FTL relays as it goes so the mesh's frontier expands. Continuous:
//  there is no finish line, and no coordination with the Haul Run that drains
//  the piles left behind.
//
//  **Staging is the player's job**, same contract as `SurveyRun`. The run uses
//  an AMI mining controller ALREADY stowed aboard the vessel, mining drones that
//  controller has ALREADY adopted, and FTL relays ALREADY stowed aboard. It
//  never stows and never adopts; missing any of it stalls with a reason naming
//  what is absent.
//
//  Pure by contract: no I/O, no clock reads (time comes from `world.now`), no
//  randomness. Every effect is the returned `MissionAction`.
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
        public static let emplacing = "emplacing"
        public static let activating = "activating"
        /// Polls for the dispatched `activate` to take, backstopped by
        /// `activationDeadline`. Never dispatches: an accepted dispatch re-stamps
        /// `stepStartedAt`, so a step that dispatched on re-entry would reset the
        /// clock its own deadline measures from and could never surface.
        public static let confirmingRelay = "confirmingRelay"
        /// Fly the VESSEL to the salvage body it is about to work, so the drones
        /// deploy locally rather than ferrying from a parked vessel. Runs BEFORE
        /// `configuring`, keyed off `nextBody` — see `position(_:_:_:)`.
        public static let positioning = "positioning"
        public static let configuring = "configuring"
        public static let launching = "launching"
        public static let awaiting = "awaiting"
        public static let verifying = "verifying"
        public static let restocking = "restocking"
    }

    /// The fleet tag a row falls back to when it carries none of its own — a
    /// row written before `fleetTag` existed, or created some other way, still
    /// resolves its fleet.
    public static let defaultFleetTag = "auto:salvage"

    /// The system `.extendQueue` anchors its census read on when a row carries no
    /// `roamCentre` of its own. A Salvage Run is always continuous, so a row
    /// missing that optional field must still be able to plan a target rather
    /// than finish or crash.
    public static let baseSystem = "AINALRAM"

    /// How old a row backing a POSITIVE staging finding may be and still be
    /// believed without an authoritative re-read. Same value as
    /// `SurveyRun.stagingFreshness`.
    ///
    /// Staging is judged from `stowedInDeviceCode` columns and mining drones are
    /// AMI-adopted, so they are event-silent: a drone abandoned in another system
    /// keeps claiming it is aboard until something reads it, and believing that
    /// claim departs without the fleet.
    public static let stagingFreshness: TimeInterval = 5 * 60

    /// How long to let an `activate` take before surfacing
    /// `relayActivationFailed`.
    public static let activationDeadline: TimeInterval = 10 * 60

    /// How long a vessel row may lag the arrival it is supposed to reflect
    /// before the run gives up and surfaces `vesselPositionUnconfirmed`,
    /// measured from the ARRIVAL and never from `stepStartedAt`.
    ///
    /// This deadline does NOT cover every route to the stall it guards:
    /// `Reconciler.applyEventFields` drops an arrival's location write outright
    /// when a confirm-read stamps `device.updatedAt` later within the same
    /// wall-clock second, leaving a row that is fresh-but-wrong and passes every
    /// watermark this file can compute. Fixing that belongs in the reconciler —
    /// see the confirm-steps-need-fresh-evidence note.
    public static let arrivalConfirmDeadline: TimeInterval = 5 * 60

    /// Floor between confirm-reads of the vessel row while waiting for its
    /// position to catch up with a completed arrival. The steps that wait here
    /// are evaluated every 5 s, so without a floor the read fires on every tick.
    public static let arrivalReadInterval: TimeInterval = 30

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
        case Step.emplacing: return emplace(directive, vessel, world)
        case Step.activating: return activate(vessel, world)
        case Step.confirmingRelay: return confirmRelay(directive, vessel, world)
        case Step.positioning: return position(directive, vessel, world)
        case Step.configuring: return configure(directive, vessel, world)
        case Step.launching: return launch(directive, vessel, world)
        case Step.awaiting: return awaitCompletion(directive, vessel, world)
        case Step.verifying: return verify(directive, vessel, world)
        case Step.restocking: return restock(directive, vessel, world)
        default:
            // An unrecognised (or not-yet-handled) step must never dispatch. Waiting
            // is inert and recoverable — the user can cancel, or the step ships.
            logger.notice("salvage run \(directive.id, privacy: .public): unknown step \(directive.step, privacy: .public) — waiting")
            return .wait
        }
    }

    // MARK: - Fleet queries

    /// The AMI mining controller stowed aboard `vessel` per `world`, if any.
    /// Forwards to `AMIFleet.stowed(aboard:in:offering:)`, which holds the
    /// stowed-not-co-located and capability-not-type rules.
    public static func controller(aboard vessel: Device, in world: WorldSnapshot) -> Device? {
        AMIFleet.stowed(aboard: vessel, in: world, offering: "gather_salvage")
    }

    /// The drones `controller` has adopted per `world` that are also stowed aboard
    /// `vessel`. Forwards to `AMIFleet.adoptedDrones(of:aboard:in:)`, which holds
    /// the two-ended adoption rule.
    public static func adoptedDrones(
        of controller: Device, aboard vessel: Device, in world: WorldSnapshot
    ) -> [Device] {
        AMIFleet.adoptedDrones(of: controller, aboard: vessel, in: world)
    }

    /// The device type this run plants, and the match every DISPATCH query below
    /// uses. Never widen one of those to the `relay` FEATURE: a `system_hub`
    /// carries that feature too, and a dispatch query gets `deploy` issued at
    /// whatever it returns. (`SalvageTargetPlanner.meshSystems` asks a different
    /// question and is right to match the feature.)
    public static let relayDeviceType = "ftl_relay"

    /// The lowest-coded FTL relay stowed aboard `vessel` per `world`, if any. Not
    /// an `AMIFleet` query: a relay is never adopted by a controller, so this is
    /// a plain stow lookup rather than the two-ended adoption read.
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

    /// The Lagrange point to emplace a relay at in `system` — its entry point when
    /// that is an L4, else an L4 synthesised from the lowest planet designation —
    /// or nil for a nil or planet-less system.
    ///
    /// Never resolve this from `system.planets.flatMap(\.lagrange)`: the
    /// system-level locations endpoint returns no per-planet Lagrange sites, so
    /// that reads empty for every normally-fetched system and silently forfeits
    /// relay emplacement on every target. Every planet has an L4 by construction,
    /// so synthesising one is sound; the lowest designation just makes the pick
    /// reproducible.
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

    // MARK: - Re-entry budget

    /// How many times `directive` has entered its CURRENT step without leaving it
    /// in between, walked backwards over `world.log` — the durable attempt counter
    /// a step needs when its only way forward is a read it must pay for again.
    ///
    /// The walk stops at an operator resolution (Retry and Skip write `.resolved`)
    /// and COUNTS it, so an operator's Retry buys a genuinely new read instead of
    /// replaying the stall it just resolved.
    ///
    /// A step that re-enters itself via a TRACKED dispatch also writes a
    /// `.stepStarted`, so it arrives at its own read budget already partly spent —
    /// know that before reusing this on a step with a self-dispatch.
    static func stepEntryCount(_ directive: Directive, _ world: WorldSnapshot) -> Int {
        var count = 0
        for entry in world.log.reversed() {
            if entry.kind == .resolved {
                count += 1
                break
            }
            guard entry.kind == .stepStarted else { continue }
            // A `.stepStarted` naming a different step ends this run of the
            // current one — everything before it belongs to an earlier visit.
            guard entry.step == directive.step else { break }
            count += 1
        }
        // A step reached before anything was ever logged (the first evaluation
        // of a fresh row) still counts as one visit.
        return max(count, 1)
    }

    // MARK: - Target planning

    /// Where the run goes next, ranking `context`'s assays, stars, devices,
    /// already-attempted targets and vessel through `SalvageTargetPlanner`:
    /// already meshed, then one relay-hop from the mesh, then richest, then
    /// nearest.
    ///
    /// An empty answer is `.idle`, never `.exhausted`. A salvage frontier is a
    /// snapshot rather than a limit — the survey roam keeps uncovering salvage and
    /// every relay this run plants widens reach — so finishing here would end a
    /// run the launcher and the list row both promise is continuous.
    ///
    /// Salvage is only ever known in systems the survey has already FINISHED, so
    /// this must never be resolved through `SurveyRoamPlanner`: its candidate
    /// filter is the exact inverse, and a run planned that way walks to the
    /// nearest unscanned star and plants a relay somewhere with no salvage at all.
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
        guard let target = directive.currentTarget else {
            let centre = directive.roamCentre ?? Self.system(of: vessel) ?? Self.baseSystem
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
        // Without a relay aboard, a vessel reaching an UNMESHED target would have
        // to park there for the whole haul to stay commandable — so detour to
        // restock rather than depart. A meshed target needs no relay.
        let meshed = SalvageTargetPlanner.meshSystems(in: Array(world.devices.values)).contains(target)
        let relay = Self.relay(aboard: vessel, in: world)
        if !meshed, relay == nil {
            return .advanceStep(nextStep: Step.restocking)
        }
        // The staging answer is positive, and only a read can correct a stale
        // positive. Kept AFTER the restocking check: a target the vessel is not
        // departing for this tick must not pay for a freshness read.
        // `.refreshFleet` rather than `.refreshDevices` — one tag read covers
        // vessel, controller and every drone, and is the only scope that can see
        // a stowed device at all.
        //
        // The relay row belongs in this set: `emplace` re-derives
        // `relay(aboard:in:)` but only over these same cached rows, so it forces
        // no live read and cannot catch a claim already stale before departure.
        // This is the one place that can, before the vessel commits to the trip.
        var stagingRows = [vessel, controller] + drones
        if let relay { stagingRows.append(relay) }
        if Self.stagingIsStale(stagingRows, world) {
            return .refreshFleet(tag: tag, thenStall: .unreachableDevice)
        }
        return .assignController(deviceCode: controller.deviceCode, nextStep: Step.travelling)
    }

    // MARK: - Arrival freshness

    /// When the last travel THIS directive dispatched for `vessel` finished, read
    /// off `world.dispatchedOperations` (which keeps closed ops, unlike
    /// `openOperations`), or nil if it has never completed one.
    ///
    /// Filter on `.completed` exactly, never `OperationStatus.isTerminal`:
    /// `.superseded` and `.unknown` also stamp `lastConfirmedAt` on travels that
    /// never arrived, and either would install a non-arrival as the watermark and
    /// gate a real dispatch behind an arrival that never happened.
    ///
    /// The instant is `lastConfirmedAt`, not `completesAt` — the latter is the
    /// PREDICTED deadline and is nil for ops that never carried one, while the
    /// former is stamped by whichever writer closed the row.
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

    /// What a travel dispatch site should do when `vessel`'s row in `world` cannot
    /// yet be trusted to say where the vessel is — nil when it can, and the
    /// dispatch may proceed.
    ///
    /// One `travel.arrived` event is settled in two separate transactions: the
    /// travel op closes first, `device.location` is written second. A tick landing
    /// in that gap sees an op that is finished and a location that still names the
    /// origin, so an unguarded site re-commands travel at a vessel already parked
    /// on the destination and the server rejects it `Already at destination`.
    ///
    /// The watermark is the ARRIVAL, never `stepStartedAt`: these are dispatch
    /// steps, so on first entry the row is legitimately older than the step, and a
    /// same-step `.travel` re-stamps `stepStartedAt` while the trip is still under
    /// way — a deadline measured from it is already blown on arrival.
    ///
    /// **The order of the three answers is mandated:** deadline, then the
    /// throttled read, then `.wait`. The throttle is measured against
    /// `vessel.updatedAt`, which only advances when a read SUCCEEDS, so a
    /// staleness-first ordering never reaches the deadline, never stalls, and
    /// issues a `.high` read every tick under the very rate-limit exhaustion that
    /// caused it. `thenStall: nil` on the mid-flight read is what bounds it —
    /// `DirectiveEngine.reAsk` collapses a repeated refresh request into `.wait`.
    ///
    /// **Gates the dispatch path only.** Place this after the `openOperation`
    /// guard and immediately before the `.dispatch`, never ahead of the
    /// location-equality check: a stale row that happens to name the destination
    /// is the benign direction, and hoisting the gate above it delays every
    /// legitimate advance.
    static func travelPositionUnconfirmed(_ vessel: Device, _ world: WorldSnapshot) -> MissionAction? {
        // Nothing for the row to post-date, so it cannot be lagging an arrival:
        // cold runs and first entries dispatch immediately.
        guard let completion = Self.lastTravelCompletion(for: vessel, world) else { return nil }
        // The row was written at or after the arrival closed, so it reflects it.
        guard vessel.updatedAt < completion else { return nil }
        if world.now.timeIntervalSince(completion) >= Self.arrivalConfirmDeadline {
            return .refreshDevices(deviceCodes: [vessel.deviceCode], thenStall: .vesselPositionUnconfirmed)
        }
        if world.now.timeIntervalSince(vessel.updatedAt) > Self.arrivalReadInterval {
            return .refreshDevices(deviceCodes: [vessel.deviceCode], thenStall: nil)
        }
        return .wait
    }

    /// Fly `vessel` to `directive`'s current target system, then route it in
    /// `world` to `emplacing` or, when the system is already meshed, straight to
    /// `positioning`.
    private func travel(_ directive: Directive, _ vessel: Device, _ world: WorldSnapshot) -> MissionAction {
        guard let target = directive.currentTarget else {
            return .advanceStep(nextStep: Step.preflight)
        }
        if Self.system(of: vessel) == target {
            // Arrived. Skip straight past the emplace step when a relay is
            // already relaying here — there is nothing to plant.
            let meshed = SalvageTargetPlanner.meshSystems(in: Array(world.devices.values)).contains(target)
            return .advanceStep(nextStep: meshed ? Step.positioning : Step.emplacing)
        }
        // An open op means the trip is under way; waiting is what stops a second
        // travel landing on top of the first.
        if world.openOperation(for: vessel.deviceCode) != nil { return .wait }
        // The equality check above is what misreads a row still lagging the
        // previous arrival, so prove the row post-dates that arrival first.
        if let unconfirmed = Self.travelPositionUnconfirmed(vessel, world) { return unconfirmed }
        return .dispatch(
            kind: .travel, deviceCode: vessel.deviceCode,
            params: CommandParams(destination: target), nextStep: Step.travelling
        )
    }

    /// Fly `vessel` to `directive`'s target Lagrange point in `world`, then deploy
    /// the stowed relay once there. `deploy` does not activate the relay, so this
    /// step always hands off to `Step.activating` rather than declaring the mesh
    /// work done.
    ///
    /// The two causes of `lagrangePoint(in:)` naming no point must stay split. An
    /// uncached `SystemDetail` blob is NOT evidence the system lacks a Lagrange
    /// point; collapsing it into the same branch silently and permanently forfeits
    /// emplacement for the target, since nothing routes `configuring` back here.
    /// A CACHED system that genuinely has none skips to mining unmeshed — the
    /// salvage is still worth taking, the frontier just cannot extend through it.
    ///
    /// The relay-aboard check is re-run here as a backstop for a relay that was
    /// never aboard, and reroutes to `Step.restocking` rather than dispatching
    /// `deploy` at a device that is not there. It is NOT staleness protection:
    /// `relay(aboard:in:)` re-queries the same cached rows `preflight` read, so
    /// only `preflight`'s freshness recheck can catch an already-stale claim.
    private func emplace(_ directive: Directive, _ vessel: Device, _ world: WorldSnapshot) -> MissionAction {
        guard let target = directive.currentTarget else {
            return .advanceStep(nextStep: Step.positioning)
        }
        guard let system = world.system(target) else {
            // Blob not cached yet — bounded wait, then one authoritative read,
            // then surface. Same handling as `configure` and `verify`.
            return unresolvedSystem(directive, world, target: target)
        }
        guard let point = Self.lagrangePoint(in: system) else {
            return .advanceStep(nextStep: Step.positioning)
        }
        guard let relay = Self.relay(aboard: vessel, in: world) else {
            return .advanceStep(nextStep: Step.restocking)
        }
        if vessel.location != point {
            if world.openOperation(for: vessel.deviceCode) != nil { return .wait }
            // The `!=` above is the check that misreads a row still lagging the
            // previous arrival; prove the row post-dates that arrival first.
            if let unconfirmed = Self.travelPositionUnconfirmed(vessel, world) { return unconfirmed }
            return .dispatch(
                kind: .travel, deviceCode: vessel.deviceCode,
                params: CommandParams(destination: point), nextStep: Step.emplacing
            )
        }
        // No `openOperation` guard: `deploy` is `OperationKind.simple` and creates
        // no `Operation` row, so the lookup is structurally always nil and the
        // guard would only make the dispatch look protected.
        return .dispatch(
            kind: OperationKind.simple("deploy"), deviceCode: relay.deviceCode,
            params: CommandParams(), nextStep: Step.activating
        )
    }

    /// Issue `activate` once at the relay `vessel` just deployed, resolved through
    /// `world`, then hand to `confirmingRelay`. Dispatch-only: all polling belongs
    /// to that step, which is what lets its deadline accumulate.
    private func activate(_ vessel: Device, _ world: WorldSnapshot) -> MissionAction {
        // Resolve the relay by where it now IS, not by what is stowed: `deploy`
        // clears its `stowedInDeviceCode`, so the aboard-query cannot find it.
        guard let relay = Self.deployedRelay(near: vessel, in: world) else {
            return .stall(.relayActivationFailed)
        }
        return .dispatch(
            kind: OperationKind.simple("activate"), deviceCode: relay.deviceCode,
            params: CommandParams(), nextStep: Step.confirmingRelay
        )
    }

    /// Floor between confirm-reads of the relay row while this step polls. The
    /// step is entered once and evaluated every 5 s, so without a floor the read
    /// below fires on every tick.
    public static let relayPollInterval: TimeInterval = 60

    /// Poll the relay `vessel` deployed, per `world`, and hand `directive` on to
    /// mining once it reports `relaying`. Backstopped by `activationDeadline`: a
    /// relay that deployed but never came up is a dead run, since the mesh
    /// membership `relaying` alone confers was the whole point of the trip.
    ///
    /// Must never dispatch. `activate` is `OperationKind.simple` and creates no
    /// `Operation` row, so an `openOperation` guard here could not stop a
    /// same-step redispatch, and every accepted dispatch re-stamps
    /// `stepStartedAt` — a polling step that dispatched would reset the clock
    /// `activationDeadline` measures from and re-issue `activate` at the live API
    /// forever.
    private func confirmRelay(_ directive: Directive, _ vessel: Device, _ world: WorldSnapshot) -> MissionAction {
        guard let relay = Self.deployedRelay(near: vessel, in: world) else {
            return .stall(.relayActivationFailed)
        }
        // `statusBase`, not `status`: the backend appends a parenthetical
        // parameter to some statuses, and a raw comparison reads a live relay as
        // dead — a false `relayActivationFailed` on a relay that is up and meshing.
        if relay.statusBase == "relaying" { return settle(directive, relay) }
        if world.now.timeIntervalSince(directive.stepStartedAt) > Self.activationDeadline {
            return .stall(.relayActivationFailed)
        }
        // Nothing else moves this row: the `relay.*` SSE route only invalidates
        // FTL-mesh freshness and never re-reads the device, so a bare `.wait` sits
        // on a stale row for the full deadline and then stalls on a relay that
        // came up fine. The read is safe against the clock-reset rule because the
        // engine resolves `.refreshDevices` and re-asks this method, so the
        // executor only ever sees `settle` (a different step) or, with `thenStall`
        // nil, the `.wait` `reAsk` collapses a repeat request into.
        //
        // Throttled on the row's OWN `updatedAt`, not `stepStartedAt`, which never
        // moves while this step polls.
        if world.now.timeIntervalSince(relay.updatedAt) > Self.relayPollInterval {
            return .refreshDevices(deviceCodes: [relay.deviceCode], thenStall: nil)
        }
        return .wait
    }

    /// Drop `directive`'s fleet tag from `relay` now that it has confirmed
    /// `relaying`, then move to `Step.positioning`. A planted relay is permanent
    /// infrastructure rather than cargo, so keeping it tagged makes every later
    /// `.refreshFleet` drag back a tail that grows by one relay per target.
    ///
    /// Untag only from THIS confirmation, never from `activate` or `emplace`: a
    /// relay that deployed but never came up is still the run's problem, and
    /// untagging drops it out of every future `.refreshFleet` while it is still
    /// cargo.
    ///
    /// The remaining set is computed here rather than sent as `[]` because
    /// `DevicesClient.updateTags` is DECLARATIVE and would otherwise wipe any
    /// other tag the operator put on the relay; skipping a relay that does not
    /// carry the tag keeps a re-entered step from re-issuing a redundant PATCH.
    private func settle(_ directive: Directive, _ relay: Device) -> MissionAction {
        let tag = Self.fleetTag(directive)
        guard relay.hasTag(tag) else {
            return .advanceStep(nextStep: Step.positioning)
        }
        return .setDeviceTags(
            deviceCode: relay.deviceCode,
            tags: relay.tags.filter { $0 != tag },
            nextStep: Step.positioning
        )
    }

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

    /// What `emplace`, `configure` and `verify` all do about `target`, whose
    /// catalogue blob still isn't cached in `world`, on behalf of `directive`:
    /// wait out `systemResolutionDeadline`, then spend one `.refreshSystem`, then
    /// stall. All three must handle `.unresolved` identically.
    ///
    /// The order is the whole point. `.wait` is the only `MissionAction` that
    /// leaves `stepStartedAt` alone — `.refreshSystem` included, everything else
    /// commits through `move()` — so the deadline accumulates only while the step
    /// waits, and requesting a refresh on every pass resets the clock the backstop
    /// measures from.
    ///
    /// The read sits on the TERMINAL branch, past the deadline, because a bare
    /// stall there is unrecoverable: no step on this path issues `.refreshSystem`
    /// on its own and `DirectiveResolutionClient.retry` fetches nothing, so Retry
    /// would re-run a pure function over the identical stale snapshot forever and
    /// only `skipTarget` — which permanently forfeits the system — would exit.
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

    /// Fly `vessel` to the salvage body `directive` is about to work in `world`,
    /// so the drones deploy locally instead of ferrying from a parked vessel.
    ///
    /// Keyed off `nextBody` — the same deterministic ranking `configure` uses —
    /// NOT the controller's in-force `gather_salvage` config: nothing writes
    /// `currentDirectiveConfig` optimistically, so the controller row still names
    /// the PREVIOUS body until a re-issued `set_directive` lands, and a
    /// config-keyed position mis-targets on every transition. Running BEFORE
    /// `configure` and off `nextBody` also makes a body draining mid-flight simply
    /// re-target the vessel to the next-richest one, which is correct precisely
    /// because `configure` has not issued anything yet.
    ///
    /// Owns the first look at the target system, so it inherits `configure`'s
    /// `.finished` / `.unresolved` handling verbatim.
    private func position(_ directive: Directive, _ vessel: Device, _ world: WorldSnapshot) -> MissionAction {
        switch Self.nextBody(in: directive, world: world) {
        case .finished:
            return .advanceTarget
        case .unresolved:
            guard let target = directive.currentTarget else { return .advanceTarget }
            return unresolvedSystem(directive, world, target: target)
        case let .body(body):
            if vessel.location == body { return .advanceStep(nextStep: Step.configuring) }
            // `.travel` is a tracked op kind (it creates an `Operation` row), so
            // this guard actually fires and the same-step re-dispatch is safe.
            if world.openOperation(for: vessel.deviceCode) != nil { return .wait }
            // The hop from the entry point to the first body is short, so a tick
            // right after the arrival op closes lands well inside the window in
            // which `vessel.location` still names where the vessel came from.
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
            return .advanceTarget

        case .unresolved:
            // The catalogue blob hasn't landed, which must NEVER read as
            // "finished" (see `NextBodyResolution`). The vessel's arrival already
            // triggers a passive rescan, so waiting is the expected path.
            guard let target = directive.currentTarget else { return .advanceTarget }
            return unresolvedSystem(directive, world, target: target)

        case let .body(body):
            guard let controller = claimedController(directive, vessel, world) else {
                return .stall(.noMiningControllerAboard)
            }
            if controller.currentDirective == "gather_salvage",
               Self.configMatches(controller.currentDirectiveConfig, body: body) {
                return .advanceStep(nextStep: Step.launching)
            }
            return .dispatch(
                kind: .setDirective, deviceCode: controller.deviceCode,
                params: CommandParams(directive: "gather_salvage", configuration: Self.salvageConfig(body: body)),
                nextStep: Step.launching
            )
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

    /// Wait until `directive`'s mining cycle on `vessel` is actually done in
    /// `world`, THEN hand to `verify`. Never stalls here: `directive.completed` is
    /// authoritative (held until the recall lands, so it means "drones home") and
    /// the only real failure is a dropped frame, so every fallback is a
    /// reconciling read rather than a blind timer.
    ///
    /// Never bound the wait with a fixed timer. Mine cycles routinely run past ten
    /// minutes, so a timed advance dumps into `verify` mid-mining, where the drones
    /// are legitimately still out and `verify` false-stalls `dronesNotRecovered`
    /// every cycle. While the controller reports `gather_salvage` this waits
    /// however long the cycle takes.
    ///
    /// `verify` remains the ONE place that raises `dronesNotRecovered`, so advance
    /// there only once the drones aren't travelling — all aboard, or mining
    /// finished with none en route — or its single refresh false-stalls a
    /// straggler mid-hop.
    ///
    /// The freshness gate below is keyed off the DRONE rows alone (`min`), never
    /// the controller. AMI drones are event-silent — their activity rolls into the
    /// controller's own `ami.*.digest` — so the controller's row is very likely
    /// fresh moments after `launch` while the drones it commands are still the
    /// stale, pre-launch "stowed aboard" rows. A `max` across
    /// controller-and-drones lets that fresh controller row vouch for stale drone
    /// evidence, reading a still-deployed fleet as recovered.
    private func awaitCompletion(_ directive: Directive, _ vessel: Device, _ world: WorldSnapshot) -> MissionAction {
        if Self.completionSeen(directive, world) {
            return .advanceStep(nextStep: Step.verifying)
        }
        // The controller told us this launch deployed nothing — no completion is
        // ever coming, so surface it now rather than reconciling forever.
        if Self.emptyLaunchSeen(directive, world) { return .stall(.launchDeployedNothing) }

        guard let controller = claimedController(directive, vessel, world) else { return .wait }
        // An empty adoption drops `lastLook` to `.distantPast`, so the guard below
        // never clears and this polls a bounded `.refreshFleet` instead of
        // advancing — asymmetric with `verify`, which treats empty-stranded as
        // recovered. The genuine no-drones-deployed case is already caught by
        // `emptyLaunchSeen`, so an empty adoption here means the adoption vanished
        // mid-cycle, which must not read as "recovered".
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
        if controller.currentDirective == "gather_salvage" {
            return canRead ? .refreshFleet(tag: Self.fleetTag(directive), thenStall: nil) : .wait
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

    // MARK: - Verify & restock

    /// The fleet tag `directive` resolves against, falling back to
    /// `defaultFleetTag` for a row that carries none of its own. Every step naming
    /// a tag for `.refreshFleet` goes through this, so the fallback lives once.
    static func fleetTag(_ directive: Directive) -> String {
        directive.fleetTag ?? Self.defaultFleetTag
    }

    /// Confirm `directive`'s recall actually landed on `vessel`, per `world`,
    /// before letting the run go anywhere — then decide the next body. The run
    /// stalls rather than departing without a drone.
    ///
    /// ONE confirming read, never `SurveyRun.recover`'s ETA-driven polling: a
    /// directive configured with `recall` (see `salvageConfig(body:)`) holds
    /// `directive.completed` until the drones have finished travelling, so a
    /// stranded-looking drone here is far more likely a stale local row than a
    /// real loss. Only if the FRESH rows still say a drone is out is it one.
    ///
    /// `nextBody`'s `.unresolved` must be handled exactly as `configure` and
    /// `emplace` handle it — a bounded wait, never silently read as `.finished`.
    private func verify(_ directive: Directive, _ vessel: Device, _ world: WorldSnapshot) -> MissionAction {
        guard let controller = claimedController(directive, vessel, world) else {
            // Nothing to verify against, and a vanished controller is preflight's
            // diagnosis to make — stalling here names the wrong problem.
            return .advanceTarget
        }
        // The WIDE `AMIFleet` query, not the aboard-vessel one: recovery is judged
        // over every drone this controller has adopted, wherever it now is, since
        // "some drones are home" is precisely the state that loses the others.
        let stranded = AMIFleet.adoptedDrones(of: controller, in: world)
            .filter { $0.stowedInDeviceCode != vessel.deviceCode }
        if !stranded.isEmpty {
            return .refreshFleet(tag: Self.fleetTag(directive), thenStall: .dronesNotRecovered)
        }
        guard let target = directive.currentTarget else { return .advanceTarget }
        switch Self.nextBody(in: directive, world: world) {
        case .finished:
            // Recovered, and nothing live left in this system: this target is
            // done.
            return .advanceTarget
        case let .body(body):
            // Recovered, and more bodies here — work the next one, UNLESS the
            // next one is the one the cycle that just ended was already working.
            guard body != Self.workedBody(controller) else {
                return sameBodyAgain(directive, world, target: target)
            }
            return .advanceStep(nextStep: Step.positioning)
        case .unresolved:
            // The catalogue blob went missing between `configure` and here — must
            // NEVER read as `.finished`. Same backstop as `emplace`.
            return unresolvedSystem(directive, world, target: target)
        }
    }

    /// The body `controller`'s in-force `gather_salvage` config names — the one
    /// the cycle that just completed was working — or nil when it is running
    /// something else, or nothing, in which case there is no "same body" to
    /// compare against and the loop proceeds normally.
    ///
    /// Read from the CONTROLLER rather than carried on the directive row: it is
    /// the server's own record of what this run asked for, so it survives a
    /// relaunch with no column and no migration.
    static func workedBody(_ controller: Device) -> String? {
        guard controller.currentDirective == "gather_salvage" else { return nil }
        return controller.currentDirectiveConfig?["location"]?.stringValue
    }

    /// How many `locations/{star}` reads the loop may spend on a body that came
    /// back unchanged before surfacing it. One: the read is authoritative.
    public static let bodyProgressAttempts = 1

    /// The mining loop's terminator: `directive`'s completed cycle left `target`'s
    /// same body still on offer in `world`, so spend one `.refreshSystem` and then
    /// stall `salvageBodyNotDepleted`.
    ///
    /// The loop re-derives `nextBody` on every pass and a body leaves the
    /// candidate set only when the `salvage.depleted` SSE route flips its site's
    /// flag, so without this bound a single dropped frame re-offers the same body
    /// forever — a real `launch` POST every cycle, unbounded, with no deadline and
    /// no stall.
    ///
    /// One read tells the two causes apart: a stale catalogue row, which the
    /// refresh repairs so the loop carries on, or a body that genuinely did not
    /// deplete. Past the read, stop — `gather_salvage` depletes the location it is
    /// pointed at, so a body that survives its own cycle must surface as a stall
    /// the operator can Skip rather than as an invisible command loop.
    private func sameBodyAgain(
        _ directive: Directive, _ world: WorldSnapshot, target: String
    ) -> MissionAction {
        if Self.stepEntryCount(directive, world) <= Self.bodyProgressAttempts {
            return .refreshSystem(designation: target, nextStep: Step.verifying)
        }
        return .stall(.salvageBodyNotDepleted)
    }

    /// The base a run restocks at.
    public static let baseDesignation = "AINALRAM-BELT-1"

    /// Fly `vessel` home for `directive` once it is out of relays, per `world`,
    /// then stall for the operator on arrival. This step parks and asks rather
    /// than loading relays itself, because the engine never stows and never
    /// adopts. A relay found aboard short-circuits the detour immediately, reached
    /// base or not, so staging one mid-flight need not wait for a now-pointless
    /// arrival.
    private func restock(_ directive: Directive, _ vessel: Device, _ world: WorldSnapshot) -> MissionAction {
        if Self.relay(aboard: vessel, in: world) != nil {
            return .advanceStep(nextStep: Step.preflight)
        }
        if vessel.location == Self.baseDesignation {
            // A tag read before the stall, never a bare stall. This is the one
            // step whose whole purpose is waiting on an operator changing a stow
            // column, and it decides from local rows that nothing refreshes while
            // the run sits here — without the read the operator stows relays, hits
            // Retry, and the same stale rows re-stall immediately, making Retry a
            // structural no-op. A tag query is also the only scope that can see a
            // freshly-stowed device at all: stowing clears `location`.
            return .refreshFleet(tag: Self.fleetTag(directive), thenStall: .awaitingRelayRestock)
        }
        // `.travel` is a TRACKED op kind (it creates an `Operation` row), so this
        // guard actually fires — unlike the `.simple` verbs elsewhere in this file
        // — and this same-step dispatch is the safe shape.
        if world.openOperation(for: vessel.deviceCode) != nil { return .wait }
        // Same arrival race as the other three travel sites: the equality check
        // against `baseDesignation` above is decided from a row the arrival's
        // second transaction may not have reached yet.
        if let unconfirmed = Self.travelPositionUnconfirmed(vessel, world) { return unconfirmed }
        return .dispatch(
            kind: .travel, deviceCode: vessel.deviceCode,
            params: CommandParams(destination: Self.baseDesignation), nextStep: Step.restocking
        )
    }
}
