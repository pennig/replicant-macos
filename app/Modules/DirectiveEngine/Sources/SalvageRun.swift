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
    public var firstStep: String { Step.preflight.rawValue }

    public init() {}

    /// This mission's step vocabulary, as `Directive.step` holds it (D6).
    public enum Step: String, CaseIterable, Sendable {
        case preflight
        case travelling
        /// Put the service bots into the system so they repair the drones while the
        /// vessel tours its bodies. Deployed once per SYSTEM, not once per body:
        /// `service` is system-scoped and the bot cruises to each damaged device.
        case deployingBots
        /// Read whether the ordered deploy landed before ordering the next.
        case confirmingBotDeploy
        /// Ensure each deployed bot carries an ACTIVE `service` directive.
        case armingBots
        /// Read whether an ordered arm landed before ordering the next.
        case confirmingBotArm
        /// Fly the VESSEL to the body it is about to work, so drones deploy locally
        /// rather than ferrying from a parked vessel. Runs BEFORE `configuring`.
        case positioning
        case configuring
        case launching
        case awaiting
        case verifying
        /// Hold the vessel while the service bots finish what they are repairing.
        case repairing
        /// Recall the deployed service bots before the vessel leaves the system.
        case stowingBots
        /// Read whether the ordered recall landed before ordering the next.
        case confirmingBotStow
    }

    /// The tag a row falls back to when it carries none of its own.
    public static let defaultFleetTag = FleetTag(goal: .salvage)

    /// Anchors `.extendQueue`'s census read when a row carries no `roamCentre`, so
    /// a continuous run missing that optional field can still plan a target.
    public static let baseSystem = "AINALRAM"

    /// How old a row backing a POSITIVE staging finding may be and still be
    /// believed. Mining drones are AMI-adopted and so event-silent: one abandoned
    /// in another system keeps claiming it is aboard until something reads it.
    public static let stagingFreshness: TimeInterval = 5 * 60

    public static let activationDeadline: TimeInterval = 10 * 60

    public static let arrivalConfirmDeadline = TravelTo.arrivalConfirmDeadline

    public static let arrivalReadInterval = TravelTo.arrivalReadInterval

    /// The cap on the controller's own flight back to the vessel before the run
    /// surfaces `miningControllerNotRecovered`. Its leg is a cross-system cruise
    /// from whichever body it was deployed at, so it is scaled like a bot recall.
    public static let controllerRecallDeadline: TimeInterval = 20 * 60

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
        guard let step = Step(rawValue: directive.step) else {
            // Waiting is inert and recoverable; guessing would command the fleet.
            logger.notice("\(kind.rawValue, privacy: .public) \(directive.id, privacy: .public): unknown step \(directive.step, privacy: .public) — waiting")
            return .wait
        }
        let ctx = StepContext(directive: directive, world: world, step: directive.step)
        switch step {
        case .preflight: return preflight(directive, vessel, world)
        case .travelling: return travel(directive, vessel, world)
        case .deployingBots:
            return switch botPhase(.deploy, directive).next(ctx) {
            case let .action(action): action
            case .finished: .advanceStep(nextStep: Step.armingBots.rawValue)
            case .more: .advanceStep(nextStep: Step.deployingBots.rawValue)
            case .noSubject: .stall(.unreachableDevice)
            }
        case .confirmingBotDeploy:
            return switch botPhase(.confirmDeploy, directive).next(ctx) {
            case let .action(action): action
            case .finished: .advanceStep(nextStep: Step.armingBots.rawValue)
            case .more: .advanceStep(nextStep: Step.deployingBots.rawValue)
            case .noSubject: .stall(.unreachableDevice)
            }
        case .armingBots:
            return switch botPhase(.arm, directive).next(ctx) {
            case let .action(action): action
            case .finished: .advanceStep(nextStep: Step.positioning.rawValue)
            case .more: .advanceStep(nextStep: Step.armingBots.rawValue)
            case .noSubject: .stall(.unreachableDevice)
            }
        case .confirmingBotArm:
            return switch botPhase(.confirmArm, directive).next(ctx) {
            case let .action(action): action
            case .finished: .advanceStep(nextStep: Step.positioning.rawValue)
            case .more: .advanceStep(nextStep: Step.armingBots.rawValue)
            case .noSubject: .stall(.unreachableDevice)
            }
        case .positioning: return position(directive, vessel, world)
        case .configuring: return configure(directive, vessel, world)
        case .launching: return launch(directive, vessel, world)
        case .awaiting: return awaitCompletion(directive, vessel, world)
        case .verifying: return verify(directive, vessel, world)
        case .repairing:
            return switch botPhase(.awaitRepair, directive).next(ctx) {
            case let .action(action): action
            case .finished, .more: .advanceStep(nextStep: Step.stowingBots.rawValue)
            case .noSubject: .stall(.unreachableDevice)
            }
        case .stowingBots:
            return switch botPhase(.recall, directive).next(ctx) {
            case let .action(action): action
            case .finished: .advanceTarget
            case .more: .advanceStep(nextStep: Step.stowingBots.rawValue)
            case .noSubject: .stall(.unreachableDevice)
            }
        case .confirmingBotStow:
            return switch botPhase(.confirmRecall, directive).next(ctx) {
            case let .action(action): action
            case .finished: .advanceTarget
            case .more: .advanceStep(nextStep: Step.stowingBots.rawValue)
            case .noSubject: .stall(.unreachableDevice)
            }
        }
    }

    /// The bot phase this step runs, and where the mission goes when it ends.
    private func botPhase(_ phase: BotPhase.Phase, _ directive: Directive) -> BotPhase {
        let (dispatch, confirm): (Step, Step) = switch phase {
        case .deploy, .confirmDeploy: (.deployingBots, .confirmingBotDeploy)
        case .arm, .confirmArm: (.armingBots, .confirmingBotArm)
        case .awaitRepair: (.repairing, .repairing)
        case .recall, .confirmRecall: (.stowingBots, .confirmingBotStow)
        }
        return BotPhase(
            vesselCode: directive.deviceCode, owner: Self.fleetTag(directive),
            system: directive.currentTarget, phase: phase,
            dispatchStep: dispatch.rawValue, confirmStep: confirm.rawValue,
            runNoun: "salvage run", unrepairedStep: Step.armingBots.rawValue
        )
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
            if let centre = directive.roamCentre ?? Self.system(of: vessel) ?? Self.hubSystem(in: world, for: directive) {
                return .extendQueue(centre: centre)
            }
            // A claimed theatre with another operational elsewhere must not
            // fall back to the constant; a genuinely hub-less world still may.
            guard world.theatreWentClaimed(for: directive) else {
                return .extendQueue(centre: Self.baseSystem)
            }
            return .wait
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
        return .assignController(deviceCode: controller.deviceCode, nextStep: Step.travelling.rawValue)
    }

    /// Fly `vessel` to `directive`'s current target system, then put the service
    /// bots out. The target is already meshed — the planner offers no other kind.
    private func travel(_ directive: Directive, _ vessel: Device, _ world: WorldSnapshot) -> MissionAction {
        guard let target = directive.currentTarget else {
            return .advanceStep(nextStep: Step.preflight.rawValue)
        }
        let ctx = StepContext(directive: directive, world: world, step: directive.step)
        let leg = TravelTo(
            deviceCode: vessel.deviceCode, destination: target,
            arrivalTest: .system, confirmStep: nil
        )
        return switch leg.next(ctx) {
        case let .action(action): action
        case .finished: .advanceStep(nextStep: Step.deployingBots.rawValue)
        case .more, .noSubject: .stall(.unreachableDevice)
        }
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

    /// How long past its deadline an unresolved-system/body backstop still
    /// waits before surfacing — the read fires inside `unresolvedReadBand`,
    /// never on every tick across this whole span.
    public static let systemUnresolvedRetryWindow: TimeInterval = 60

    /// The width, right past a backstop's deadline, in which its authoritative
    /// read fires — three nominal ticks, because an engine tick really lasts
    /// `5s + evaluation` and a narrower band is one two ticks can straddle.
    public static let unresolvedReadBand: TimeInterval = 15

    /// What `emplace`, `configure` and `verify` all do about an uncached `target`:
    /// wait out `systemResolutionDeadline`, spend `.refreshSystem` in the
    /// following `unresolvedReadBand`, wait out the rest, then stall.
    private func unresolvedSystem(
        _ directive: Directive, _ world: WorldSnapshot, target: String
    ) -> MissionAction {
        let sinceDeadline = world.now.timeIntervalSince(directive.stepStartedAt)
            - Self.systemResolutionDeadline
        if sinceDeadline <= 0 {
            return .wait
        }
        if sinceDeadline <= Self.unresolvedReadBand {
            return .refreshSystem(designation: target, nextStep: directive.step)
        }
        if sinceDeadline <= Self.systemUnresolvedRetryWindow {
            return .wait
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
            return .advanceStep(nextStep: Step.repairing.rawValue)
        case .unresolved:
            guard let target = directive.currentTarget else {
                return .advanceStep(nextStep: Step.repairing.rawValue)
            }
            return unresolvedSystem(directive, world, target: target)
        case let .body(body):
            let ctx = StepContext(directive: directive, world: world, step: directive.step)
            let leg = TravelTo(
                deviceCode: vessel.deviceCode, destination: body,
                arrivalTest: .exactLocation, confirmStep: nil
            )
            return switch leg.next(ctx) {
            case let .action(action): action
            case .finished: .advanceStep(nextStep: Step.configuring.rawValue)
            case .more, .noSubject: .stall(.unreachableDevice)
            }
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
            return .advanceStep(nextStep: Step.repairing.rawValue)

        case .unresolved:
            // The catalogue blob hasn't landed, which must NEVER read as
            // "finished" (see `NextBodyResolution`). The vessel's arrival already
            // triggers a passive rescan, so waiting is the expected path.
            guard let target = directive.currentTarget else {
                return .advanceStep(nextStep: Step.repairing.rawValue)
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
                    nextStep: Step.launching.rawValue
                )
            }
            // Right directive, right body, but not running: `activate` is what
            // starts it. Re-sending the name would never touch the status.
            guard Self.isMining(controller) else {
                return .dispatch(
                    kind: OperationKind.simple("activate"), deviceCode: controller.deviceCode,
                    params: CommandParams(), nextStep: Step.launching.rawValue
                )
            }
            return .advanceStep(nextStep: Step.launching.rawValue)
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
            params: CommandParams(), nextStep: Step.awaiting.rawValue
        )
    }

    /// Floor between reconciling reads while `awaiting` waits out a mining cycle.
    /// The throttle is also what stops a persistently failing read from looping on
    /// every tick.
    public static let reconcileInterval: TimeInterval = 2 * 60

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
            return .advanceStep(nextStep: Step.verifying.rawValue)
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
        let wireTag = Self.fleetTag(directive)

        // Never believe a row read BEFORE this step began: a pre-launch drone row
        // still shows it stowed aboard and reads as "recovered" the instant the
        // step starts. Force a post-launch read of EVERY drone first, throttled so
        // a failing one cannot loop every tick.
        guard lastLook >= directive.stepStartedAt else {
            return canRead ? .refreshFleet(tag: wireTag, thenStall: nil) : .wait
        }

        let stranded = drones.filter { $0.stowedInDeviceCode != vessel.deviceCode }
        // A dropped completion frame: the drones are already home, nothing said so.
        if stranded.isEmpty { return .advanceStep(nextStep: Step.verifying.rawValue) }
        // Still mining — the drones are out by design. Reconcile on a cadence to
        // catch completion (or the controller going idle); never stall, however
        // long the cycle runs.
        if Self.isMining(controller) {
            return canRead ? .refreshFleet(tag: wireTag, thenStall: nil) : .wait
        }
        // Set but not running, drones out: no completion is ever coming, so the
        // reconcile above would wait forever. Prove it on a fresh read, then name it.
        if Self.isPaused(controller) {
            return canRead
                ? .refreshFleet(tag: wireTag, thenStall: .miningDirectivePaused)
                : .wait
        }
        // Mining done, drones still out: a post-mining recall (near-instant now
        // the vessel sits at the body). Wait out any traveller's own ETA; re-read
        // the stragglers on the cadence otherwise.
        if stranded.contains(where: { $0.activityDeadline != nil }) {
            if let arrival = BotPhase.recallArrival(stranded), arrival > world.now { return .wait }
            return canRead
                ? .refreshDevices(deviceCodes: stranded.map(\.deviceCode), thenStall: nil)
                : .wait
        }
        // None travelling, none aboard, mining finished — they aren't coming on
        // their own. Hand to `verify`, which refreshes once and raises
        // `dronesNotRecovered` if the fresh rows agree.
        return .advanceStep(nextStep: Step.verifying.rawValue)
    }

    // MARK: - Verify & restock

    /// The fleet tag `directive` resolves against, falling back to
    /// `defaultFleetTag` for a row that carries none of its own. Every step naming
    /// a tag for `.refreshFleet` goes through this, so the fallback lives once.
    static func fleetTag(_ directive: Directive) -> FleetTag {
        directive.fleetTag.flatMap(FleetTag.init(parsing:)) ?? Self.defaultFleetTag
    }

    /// The tag `Brain.ensureSalvage` stamps for a theatre at `depot` — the mine
    /// ferry tag's sibling, per theatre rather than per belt.
    public static func fleetTag(forTheatre depot: String) -> FleetTag {
        FleetTag(goal: .salvage, scope: .theatre(depot: depot))
    }

    /// Whether `device` wears `depot`'s salvage tag, its own or the bare one it
    /// falls back from — the operator's opt-in, wherever the device stands.
    /// Fleet MEMBERSHIP is `isFleetTagged`.
    static func wearsFleetTag(_ device: Device, at depot: String) -> Bool {
        device.carries(fleetTag(forTheatre: depot), policy: .exactOrUnscoped)
    }

    /// Whether `depot` may spend `device` — `FleetMembership.isDeployable`:
    /// its salvage fleet by tag or location, and placeable by the census.
    static func isFleetTagged(_ device: Device, at depot: String, resolver: TheatreResolver) -> Bool {
        FleetMembership.isDeployable(device, toDepot: depot, goal: .salvage, resolver: resolver)
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
            return .advanceStep(nextStep: Step.repairing.rawValue)
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
            return .advanceStep(nextStep: Step.repairing.rawValue)
        }
        switch Self.nextBody(in: directive, world: world) {
        case .finished:
            return .advanceStep(nextStep: Step.repairing.rawValue)
        case let .body(body):
            // More bodies here — unless the next one is what the cycle that just
            // ended was already working.
            guard body != Self.workedBody(controller) else {
                return sameBodyAgain(directive, world, target: target, body: body)
            }
            return .advanceStep(nextStep: Step.positioning.rawValue)
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

    /// How long past `depletionPropagationGrace` the loop still waits on a
    /// still-on-offer worked body before surfacing it — the read fires inside
    /// `unresolvedReadBand`, never on every tick across this whole span.
    public static let bodyUnresolvedRetryWindow: TimeInterval = 60

    /// How long `verify` waits before treating a still-on-offer worked body as
    /// evidence: the `salvage.depleted` frame and the roster both lag the drones'
    /// real finish, so a read spent sooner asks a server not yet caught up.
    public static let depletionPropagationGrace: TimeInterval = 5 * 60

    /// The mining loop's terminator, ordered grace → `.refreshBody` → wait out
    /// the rest → stall. The per-body read, never `.refreshSystem`: the
    /// server DELISTS a depleted site, only the per-body roster sees it.
    private func sameBodyAgain(
        _ directive: Directive, _ world: WorldSnapshot, target: String, body: String
    ) -> MissionAction {
        let sinceGrace = world.now.timeIntervalSince(directive.stepStartedAt)
            - Self.depletionPropagationGrace
        if sinceGrace <= 0 {
            return .wait
        }
        if sinceGrace <= Self.unresolvedReadBand {
            return .refreshBody(system: target, body: body, nextStep: Step.verifying.rawValue)
        }
        if sinceGrace <= Self.bodyUnresolvedRetryWindow {
            return .wait
        }
        return .stall(.salvageBodyNotDepleted, detail: body)
    }

}
