//
//  SurveyRun.swift
//  Replicould — DirectiveEngine
//
//  Fly a vessel down a queue of target systems and survey each one: set the
//  stowed AMI controller's `survey_system` directive, launch it (which deploys
//  its adopted stowed drones), wait for completion, move on.
//
//  **Staging is the player's job.** The run uses an AMI survey controller
//  ALREADY stowed aboard the vessel and drones it has ALREADY adopted; it never
//  stows and never adopts, because adoption is persistent state that outlives
//  the mission. Missing either is a stall with a reason naming it.
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

public struct SurveyRun: MissionStepMachine {
    public let kind: DirectiveKind = .surveyRun
    public var firstStep: String { Step.preflight }

    public init() {}

    /// This mission's step vocabulary, as the bare strings `Directive.step` holds.
    public enum Step {
        /// Prove the staging aboard the vessel before committing to a target.
        public static let preflight = "preflight"
        /// Fly the vessel to the current target system.
        public static let travelling = "travelling"
        /// Put the service bots into the system so they can repair as it works.
        public static let deployingBots = "deployingBots"
        /// Read whether the ordered deploy landed before ordering the next.
        public static let confirmingBotDeploy = "confirmingBotDeploy"
        /// Put `surveyConfig` in force on the stowed controller.
        public static let configuring = "configuring"
        /// Launch the controller, which deploys its adopted drones.
        public static let launching = "launching"
        /// Wait out the survey itself.
        public static let awaiting = "awaiting"
        /// Check the target's scan counts against the claimed completion.
        public static let confirming = "confirming"
        /// Hold the vessel until every recalled drone is back aboard.
        public static let recovering = "recovering"
        /// Hold the vessel while the service bots finish what they are repairing.
        public static let repairing = "repairing"
        /// Stow the deployed service bots before the vessel departs.
        public static let stowingBots = "stowingBots"
        /// Read whether the ordered stow landed before ordering the next.
        public static let confirmingBotStow = "confirmingBotStow"
        /// Fly the vessel back to the run's origin.
        public static let returning = "returning"
    }

    /// How long to let the AMI's post-survey recall get going before the first
    /// probe. Short: the point is only to avoid reading state that cannot
    /// possibly have changed yet.
    public static let recallProbeDelay: TimeInterval = 10

    /// Floor between recall probes when the drones offer no arrival time to
    /// wait on (an arrived-but-unstowed drone reports no travel block at all).
    /// Without it, a missing ETA would mean a read round on every 5s tick.
    public static let recallProbeInterval: TimeInterval = 30

    /// The hard cap on a recall before the run surfaces `dronesNotRecovered`.
    /// Generous because it is a backstop, not the primary timer: `recover`'s
    /// ETA-driven wait handles the honest cases, so reaching this means the
    /// recall really is not happening.
    public static let recallDeadline: TimeInterval = 20 * 60

    /// How long to let an ordered bot deploy or stow settle before the first read.
    public static let botProbeDelay: TimeInterval = 10

    /// Floor between bot-state probes, so an unmoving row is not re-read each tick.
    public static let botProbeInterval: TimeInterval = 30

    /// The cap on holding a vessel for repair before surfacing `repairUnfinished`.
    public static let repairDeadline: TimeInterval = 20 * 60

    /// How old a row backing a POSITIVE staging finding may be and still be
    /// believed without an authoritative re-read.
    ///
    /// Staging is judged from `stowedInDeviceCode` columns and survey drones emit
    /// no events at all, so a drone abandoned in another system keeps claiming it
    /// is aboard until something reads it. The `.refreshDevices` net guards only
    /// the NEGATIVE direction; the positive is the one that loses a fleet. Costs
    /// at most one read round per target.
    public static let stagingFreshness: TimeInterval = 5 * 60

    /// The survey configuration this mission insists on: a FULL survey with the
    /// drones recalled when done, so the vessel can move on to the next target.
    /// Deliberately different from the composer's manual default (`moons: none`)
    /// — a Survey Run means the whole system.
    public static let surveyConfig: [String: JSONValue] = [
        "planets": .string("all"),
        "moons": .string("all"),
        "recall": .bool(true),
    ]

    /// Route `directive`'s current step against `world`, stalling if the vessel
    /// `directive.deviceCode` names has left the fleet.
    ///
    /// An unrecognised step waits rather than dispatching: waiting is inert and
    /// the operator can cancel, where guessing would command the fleet.
    public func nextAction(directive: Directive, world: WorldSnapshot) -> MissionAction {
        guard let vessel = world.device(directive.deviceCode) else {
            return .stall(.unreachableDevice)
        }
        switch directive.step {
        case Step.preflight: return preflight(directive, vessel, world)
        case Step.travelling: return travel(directive, vessel, world)
        case Step.deployingBots: return deployBots(directive, vessel, world)
        case Step.confirmingBotDeploy: return confirmBotDeploy(directive, vessel, world)
        case Step.configuring: return configure(directive, vessel, world)
        case Step.launching: return launch(directive, vessel, world)
        case Step.awaiting: return awaitCompletion(directive, world)
        case Step.confirming: return confirm(directive, world)
        case Step.recovering: return recover(directive, vessel, world)
        case Step.repairing: return awaitRepair(directive, vessel, world)
        case Step.stowingBots: return stowBots(directive, vessel, world)
        case Step.confirmingBotStow: return confirmBotStow(directive, vessel, world)
        case Step.returning: return returnHome(directive, vessel, world)
        default:
            logger.notice("survey run \(directive.id, privacy: .public): unknown step \(directive.step, privacy: .public) — waiting")
            return .wait
        }
    }

    // MARK: - Fleet queries

    /// The AMI survey controller stowed aboard `vessel` in `world`, if any.
    /// Forwards to the shared `AMIFleet` query — see there for the full "why".
    public static func controller(aboard vessel: Device, in world: WorldSnapshot) -> Device? {
        AMIFleet.stowed(aboard: vessel, in: world, offering: "survey_system")
    }

    /// The drones `controller` has adopted that are also aboard `vessel` in
    /// `world`. Forwards to `AMIFleet` — see there for why adoption is read from
    /// both ends of the controller/drone link.
    public static func adoptedDrones(
        of controller: Device, aboard vessel: Device, in world: WorldSnapshot
    ) -> [Device] {
        AMIFleet.adoptedDrones(of: controller, aboard: vessel, in: world)
    }

    /// Every device `controller` has adopted anywhere in `world`, including the
    /// ones still deployed. Forwards to `AMIFleet` — see there for why the recall
    /// gate needs the whole set rather than just the ones aboard.
    public static func adoptedDrones(of controller: Device, in world: WorldSnapshot) -> [Device] {
        AMIFleet.adoptedDrones(of: controller, in: world)
    }

    /// Whether any of `devices` backs a staging finding with a row too old, by
    /// `world`'s clock, to act on.
    ///
    /// One stale row is enough: "everything needed is aboard" is a conjunction,
    /// so its weakest member decides how much the claim is worth.
    static func stagingIsStale(_ devices: [Device], _ world: WorldSnapshot) -> Bool {
        devices.contains { world.now.timeIntervalSince($0.updatedAt) > stagingFreshness }
    }

    /// Whether `system`'s scan counts say it is completely surveyed.
    ///
    /// Forwards to `StarSystem.isFullyScanned`, the one definition — shared with
    /// the persistence layer that stamps `stars.fullyScannedAt`, so the picker,
    /// the engine and the catalog can never disagree. The `nil`-tolerance stays
    /// here: a system we hold no blob for is not evidence of completeness.
    public static func isFullyScanned(_ system: StarSystem?) -> Bool {
        system?.isFullyScanned ?? false
    }

    /// The star system `device` is currently in, or nil in transit or stowed.
    static func system(of device: Device) -> String? {
        device.location.map { SiteAssay.system(of: $0) }
    }

    // MARK: - Completion detection

    /// How long to wait on the `directive.completed` fast path before polling
    /// the counts anyway. A dropped SSE frame must not strand a run forever, and
    /// ten minutes keeps the cost to a handful of reads per survey.
    public static let backstopInterval: TimeInterval = 10 * 60

    /// Tolerance when comparing a completion's time against the step's start.
    /// Same value and reasoning as `Reconciler.eventTimeSkewTolerance`.
    static let eventTimeSkewTolerance: TimeInterval = 5

    /// Whether a completion for `directive`'s CURRENT step has landed in
    /// `world`'s timeline.
    ///
    /// Issue-time relative, not wall-clock: a completion delivered by catch-up
    /// after the app was closed still counts, while one predating this step is a
    /// replay and does not.
    public static func completionSeen(_ directive: Directive, _ world: WorldSnapshot) -> Bool {
        saw(.directiveCompleted, directive, world)
    }

    /// Whether a launch reporting zero deployed devices landed in `directive`'s
    /// current step, per `world`'s timeline.
    ///
    /// A launch that deployed nothing cannot produce the completion `awaiting`
    /// waits for, so this turns a permanent wait into a named stall. Same
    /// issue-time guard as completions, for the same reason in reverse: a Retry
    /// must not re-stall on the very launch it was retrying.
    public static func emptyLaunchSeen(_ directive: Directive, _ world: WorldSnapshot) -> Bool {
        saw(.launchDeployedNothing, directive, world)
    }

    /// Whether an entry of `kind` in `world`'s log belongs to `directive`'s
    /// current step.
    private static func saw(
        _ kind: DirectiveLogKind, _ directive: Directive, _ world: WorldSnapshot
    ) -> Bool {
        world.log.contains { entry in
            entry.kind == kind
                && entry.occurredAt >= directive.stepStartedAt
                    .addingTimeInterval(-eventTimeSkewTolerance)
        }
    }

    // MARK: - Target planning

    /// Where a continuous survey goes next: the cheapest hop inside an expanding
    /// band of unsurveyed systems around `context`'s centre
    /// (`SurveyRoamPlanner`).
    ///
    /// `.exhausted` rather than `.idle` for both empty answers, and that is the
    /// honest one here: the candidate set is "stars this account has not fully
    /// scanned", which only ever shrinks as the run works, so an empty census
    /// really is a finish line — unlike a Salvage Run's frontier, which the
    /// survey itself keeps growing.
    public func plan(_ context: RoamContext) -> RoamPlan {
        // No census row for the centre means the band has no anchor to measure
        // from, and it is not a transient — the designation is stamped on the row
        // at launch.
        guard let centre = context.centre else { return .exhausted }
        guard let next = SurveyRoamPlanner.nextTarget(
            centre: centre.position,
            // A stowed or in-transit vessel reports no location at all, so
            // measure the hop from the centre instead. Only WHICH member of the
            // band is cheapest changes — the band itself is anchored on the
            // centre either way, so the coverage guarantee is unaffected.
            from: context.vessel ?? centre.position,
            stars: context.stars,
            attempted: context.attempted
        ) else { return .exhausted }
        return .target(next)
    }

    // MARK: - Steps

    /// Prove `vessel`'s staging in `world` before committing `directive` to its
    /// current target, or resolve an exhausted queue.
    ///
    /// Both staging checks are NEGATIVE findings over local rows, and a local row
    /// is silent for two different reasons: nothing is aboard, or nobody has been
    /// allowed to look lately (the confirm-read that would say so is `.low` and
    /// the read budget may have deferred it for minutes). Only the first is worth
    /// stopping a run for, so each demands an authoritative look before
    /// surfacing — the engine re-asks once against fresh rows and stalls with the
    /// carried reason if the answer holds.
    private func preflight(_ directive: Directive, _ vessel: Device, _ world: WorldSnapshot) -> MissionAction {
        guard let target = directive.currentTarget else {
            // A CONTINUOUS run never exhausts its queue — it extends it. Checked
            // before the return leg so the two stay independently expressible:
            // "roam, then come home" must remain a matter of setting both flags
            // rather than needing new code.
            if let centre = directive.roamCentre {
                return .extendQueue(centre: centre)
            }
            // Queue exhausted. The vessel stays put unless the run was created
            // with `returnToOrigin` — an unwanted return leg costs fuel and time.
            guard directive.returnToOrigin,
                  let origin = directive.originDesignation,
                  Self.system(of: vessel) != origin
            else { return .done }
            return .advanceStep(nextStep: Step.returning)
        }
        guard let controller = Self.controller(aboard: vessel, in: world) else {
            return .refreshDevices(
                deviceCodes: [vessel.deviceCode], thenStall: .noSurveyControllerAboard
            )
        }
        let drones = Self.adoptedDrones(of: controller, aboard: vessel, in: world)
        guard !drones.isEmpty else {
            // Name the controller too: `controlled_devices` is detail-only, so a
            // list-synced controller under-reports adoption and the drones' own
            // `controller_device_code` is the half that survives.
            return .refreshDevices(
                deviceCodes: [vessel.deviceCode, controller.deviceCode],
                thenStall: .noSurveyDroneAboard
            )
        }
        // Cached-only skip check: `GET locations/{star}` is presence-gated, so a
        // target we haven't reached can only be judged from what we already
        // hold. Deliberately BEFORE the freshness demand below: a target being
        // skipped is never departed for, so its staging cannot strand anything
        // and must not cost a read round.
        if Self.isFullyScanned(world.system(target)) { return .advanceTarget }
        // The staging answer is positive, and only a read can correct the rows it
        // rests on. Inert once a refresh lands; the engine stalls here only if
        // the reads could not be had, which `.unreachableDevice` names honestly.
        if Self.stagingIsStale([vessel, controller] + drones, world) {
            // Name every row the check covers, drones included. The engine's
            // carrier expansion reads the VESSEL's `stowed_devices` blob, which
            // is not a reliable inverse of the drones' own `stowedInDeviceCode`
            // columns, so naming only the vessel leaves the drone rows exactly as
            // stale as before and the check can never be satisfied.
            return .refreshDevices(
                deviceCodes: [vessel.deviceCode, controller.deviceCode] + drones.map(\.deviceCode),
                thenStall: .unreachableDevice
            )
        }
        return .assignController(deviceCode: controller.deviceCode, nextStep: Step.travelling)
    }

    /// Wait out `directive`'s survey against `world`. The controller drives its
    /// drones server-side, so there is no operation the app created to key off:
    /// the completion entry the `directive.*` route writes is the fast path, and
    /// a counts poll after `backstopInterval` is the lost-event backstop.
    private func awaitCompletion(_ directive: Directive, _ world: WorldSnapshot) -> MissionAction {
        guard let target = directive.currentTarget else {
            return .advanceStep(nextStep: Step.preflight)
        }
        if Self.completionSeen(directive, world) {
            return .refreshSystem(designation: target, nextStep: Step.confirming)
        }
        // The controller told us this launch deployed nothing. No drones are
        // out, so no completion is coming and the backstop would poll an empty
        // system every ten minutes until someone noticed. Surface it now.
        if Self.emptyLaunchSeen(directive, world) { return .stall(.launchDeployedNothing) }
        if world.now.timeIntervalSince(directive.stepStartedAt) > Self.backstopInterval {
            return .refreshSystem(designation: target, nextStep: Step.confirming)
        }
        return .wait
    }

    /// Judge `directive`'s current target against `world`'s freshly-read scan
    /// counts: done, contradicted, or still running.
    private func confirm(_ directive: Directive, _ world: WorldSnapshot) -> MissionAction {
        guard let target = directive.currentTarget else {
            return .advanceStep(nextStep: Step.preflight)
        }
        // Confirmed done, but NOT free to leave. `recall: true` means the AMI is
        // only now flying its drones home, so departing on this evidence strands
        // them (see `recover`).
        if Self.isFullyScanned(world.system(target)) {
            return .advanceStep(nextStep: Step.recovering)
        }
        // The server SAID it finished and the counts disagree — surface that
        // rather than advancing over a half-surveyed system.
        if Self.completionSeen(directive, world) { return .stall(.surveyIncomplete) }
        // A backstop poll that found it unfinished: nothing ever claimed
        // completion, so there is nothing to disbelieve. Keep waiting.
        return .advanceStep(nextStep: Step.awaiting)
    }

    /// Hold `vessel` until `world` shows the AMI's recall has landed every drone
    /// `directive`'s controller adopted back aboard.
    ///
    /// **`directive.completed` means the SURVEY finished, NOT the recall**, so a
    /// run that treats a completion as clearance dispatches the vessel while its
    /// drones are still flying to the rendezvous and strands them.
    ///
    /// Sits BEFORE the repair gate so it covers both ways a vessel leaves: the
    /// next target's travel leg, and the queue-exhausted leg home — preflight's
    /// staging checks never run on the latter.
    private func recover(_ directive: Directive, _ vessel: Device, _ world: WorldSnapshot) -> MissionAction {
        guard let controller = claimedController(directive, vessel, world) else {
            // Nothing to recall, and a vanished controller is preflight's
            // diagnosis to make — holding the run here would stall on a reason
            // that doesn't name the real problem.
            return .advanceStep(nextStep: Step.repairing)
        }
        let adopted = Self.adoptedDrones(of: controller, in: world)
        let stranded = adopted.filter { $0.stowedInDeviceCode != vessel.deviceCode }
        if stranded.isEmpty { return .advanceStep(nextStep: Step.repairing) }

        let elapsed = world.now.timeIntervalSince(directive.stepStartedAt)
        // The recall was ordered moments ago; nothing can have changed yet.
        if elapsed < Self.recallProbeDelay { return .wait }
        // The backstop, measured from the step's start — which neither `.wait`
        // nor a probe re-stamps, so it really is a cap on the whole recall.
        if elapsed > Self.recallDeadline { return .stall(.dronesNotRecovered) }
        // Wait out the FARTHEST traveller's own arrival time rather than a
        // hardcoded guess: a recall crosses whatever distances the survey
        // scattered the drones over, and those differ by an order of magnitude
        // between systems. Free — the ETA is already in rows we hold.
        if let arrival = Self.recallArrival(stranded), arrival > world.now { return .wait }
        // No usable ETA, or it has passed. Look again — but not more often than
        // `recallProbeInterval`, using the rows' own `updatedAt` as the "when
        // did we last look" clock, since a drone that arrived without stowing
        // reports no travel block and would otherwise be re-probed every tick.
        let lastLook = stranded.map(\.updatedAt).min() ?? .distantPast
        if world.now.timeIntervalSince(lastLook) < Self.recallProbeInterval { return .wait }
        // Name the drones whose own rows decide this gate, never a location
        // scope: stowing a device CLEARS its location, so a location-scoped list
        // cannot report the very state this step waits for — the success
        // condition erases the evidence, `lastLook` never advances off rows the
        // probe never writes, and the probe re-fires every tick until the
        // deadline surfaces `dronesNotRecovered` over a recovered fleet.
        //
        // `resolveRefresh` reads each named code directly, which reports a stowed
        // drone wherever it is and an in-transit one with its travel block; the
        // carrier expansion is an addition to that, not the mechanism, so naming
        // the DRONES also sidesteps the vessel's `stowed_devices` blob (see
        // `preflight`). Costs one read per drone still out, shrinking as they
        // come home.
        //
        // `thenStall: nil`: drones still flying is the expected answer, not a
        // fault, so an unresolved probe waits rather than demanding a human.
        return .refreshDevices(deviceCodes: stranded.map(\.deviceCode), thenStall: nil)
    }

    /// When the last of the drones still out is due back, if any of them is
    /// reporting a trip. `activityDeadline` resolves the travel block's
    /// leg-vs-route pair (and discards a stale route end), so a recall hop
    /// yields its real arrival.
    static func recallArrival(_ stranded: [Device]) -> Date? {
        stranded.compactMap(\.activityDeadline).max()
    }

    /// Fly `vessel` back to `directive`'s origin, finishing once `world` puts it
    /// in that system.
    ///
    /// Carries the same open-op-only dispatch guard `travel` does, and the same
    /// exposure it documents.
    private func returnHome(_ directive: Directive, _ vessel: Device, _ world: WorldSnapshot) -> MissionAction {
        guard let origin = directive.originDesignation else { return .done }
        if Self.system(of: vessel) == origin { return .done }
        if world.openOperation(for: vessel.deviceCode) != nil { return .wait }
        return .dispatch(
            kind: .travel, deviceCode: vessel.deviceCode,
            params: CommandParams(destination: origin), nextStep: Step.returning
        )
    }

    /// The controller `directive` claimed, re-resolved from `world` on every
    /// evaluation and falling back to whatever is stowed aboard `vessel` when the
    /// row names none — the row is the checkpoint, and a controller since
    /// released or decommissioned must surface rather than be dispatched at.
    private func claimedController(_ directive: Directive, _ vessel: Device, _ world: WorldSnapshot) -> Device? {
        guard let code = directive.controllerCode else {
            return Self.controller(aboard: vessel, in: world)
        }
        return world.device(code)
    }

    /// Put `surveyConfig` in force on the controller `directive` claimed aboard
    /// `vessel`, skipping the command when `world` already shows it running.
    private func configure(_ directive: Directive, _ vessel: Device, _ world: WorldSnapshot) -> MissionAction {
        guard let controller = claimedController(directive, vessel, world) else {
            return .stall(.noSurveyControllerAboard)
        }
        if controller.currentDirective == "survey_system",
           Self.configMatches(controller.currentDirectiveConfig) {
            return .advanceStep(nextStep: Step.launching)
        }
        return .dispatch(
            kind: .setDirective, deviceCode: controller.deviceCode,
            params: CommandParams(directive: "survey_system", configuration: Self.surveyConfig),
            nextStep: Step.launching
        )
    }

    /// Launch the controller `directive` claimed aboard `vessel`, resolved
    /// through `world`, which deploys its adopted drones.
    private func launch(_ directive: Directive, _ vessel: Device, _ world: WorldSnapshot) -> MissionAction {
        guard let controller = claimedController(directive, vessel, world) else {
            return .stall(.noSurveyControllerAboard)
        }
        return .dispatch(
            kind: OperationKind.simple("launch"), deviceCode: controller.deviceCode,
            params: CommandParams(), nextStep: Step.awaiting
        )
    }

    /// Whether an in-force config already equals `surveyConfig` on the three
    /// fields that matter. Compared field by field rather than whole-object: the
    /// server may echo extra keys, and an inequality there is not a reason to
    /// re-issue.
    static func configMatches(_ config: JSONValue?) -> Bool {
        guard let config else { return false }
        return config["planets"]?.stringValue == "all"
            && config["moons"]?.stringValue == "all"
            && config["recall"]?.boolValue == true
    }

    /// Fly `vessel` to `directive`'s current target, or advance once `world`
    /// already places it there.
    ///
    /// The open-op guard proves only that the last travel's operation row is
    /// closed. An arrival closes that row and writes `device.location` in two
    /// separate transactions, so a tick landing between them re-commands travel
    /// at a vessel already parked on the destination: a dispatch step's watermark
    /// must be the ARRIVAL, which this one does not carry
    /// (`confirm-steps-need-fresh-evidence`).
    private func travel(_ directive: Directive, _ vessel: Device, _ world: WorldSnapshot) -> MissionAction {
        guard let target = directive.currentTarget else {
            return .advanceStep(nextStep: Step.preflight)
        }
        if Self.system(of: vessel) == target { return .advanceStep(nextStep: Step.deployingBots) }
        if world.openOperation(for: vessel.deviceCode) != nil { return .wait }
        return .dispatch(
            kind: .travel, deviceCode: vessel.deviceCode,
            params: CommandParams(destination: target), nextStep: Step.travelling
        )
    }

    /// Deploy the next service bot still aboard `vessel`, or move on when the
    /// system already has them all.
    private func deployBots(_ directive: Directive, _ vessel: Device, _ world: WorldSnapshot) -> MissionAction {
        let aboard = RepairFleet.bots(aboard: vessel, in: world)
        guard let next = aboard.first else { return .advanceStep(nextStep: Step.configuring) }
        return .dispatch(
            kind: .simple("deploy"), deviceCode: next.deviceCode,
            params: CommandParams(), nextStep: Step.confirmingBotDeploy
        )
    }

    /// Judge an ordered deploy, looping back for the next bot until none is aboard.
    private func confirmBotDeploy(_ directive: Directive, _ vessel: Device, _ world: WorldSnapshot) -> MissionAction {
        let elapsed = world.now.timeIntervalSince(directive.stepStartedAt)
        if elapsed < Self.botProbeDelay { return .wait }
        let aboard = RepairFleet.bots(aboard: vessel, in: world)
        if aboard.isEmpty { return .advanceStep(nextStep: Step.configuring) }
        // A row that has not been read since the deploy was ordered cannot yet
        // show it landing; buy the read rather than believing a stale claim.
        if aboard.contains(where: { $0.updatedAt < directive.stepStartedAt }) {
            let lastLook = aboard.map(\.updatedAt).min() ?? .distantPast
            if world.now.timeIntervalSince(lastLook) < Self.botProbeInterval { return .wait }
            return .refreshDevices(deviceCodes: aboard.map(\.deviceCode), thenStall: nil)
        }
        return .advanceStep(nextStep: Step.deployingBots)
    }

    /// Hold `vessel` while any deployed service bot is still repairing.
    /// Gated on the bots falling IDLE, never a capacity threshold — `service`
    /// repairs to an unquantified level a threshold gate could wait on forever.
    private func awaitRepair(_ directive: Directive, _ vessel: Device, _ world: WorldSnapshot) -> MissionAction {
        let bots = RepairFleet.bots(deployedAt: vessel.location, in: world)
        if bots.isEmpty { return .advanceStep(nextStep: Step.stowingBots) }
        // A fleet nothing is worn enough to hold for leaves without paying the
        // probe delay or a single read.
        if !RepairFleet.needsRepair(RepairFleet.fleet(of: vessel, in: world)) {
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

    /// Stow the next service bot still standing in the system, or advance when
    /// none is left out.
    private func stowBots(_ directive: Directive, _ vessel: Device, _ world: WorldSnapshot) -> MissionAction {
        let out = RepairFleet.bots(deployedAt: vessel.location, in: world)
        guard let next = out.first else { return .advanceTarget }
        return .dispatch(
            kind: .stow, deviceCode: next.deviceCode,
            params: CommandParams(target: vessel.deviceCode),
            nextStep: Step.confirmingBotStow
        )
    }

    /// Judge an ordered stow, looping back for the next bot until none is out.
    private func confirmBotStow(_ directive: Directive, _ vessel: Device, _ world: WorldSnapshot) -> MissionAction {
        let elapsed = world.now.timeIntervalSince(directive.stepStartedAt)
        if elapsed < Self.botProbeDelay { return .wait }
        if elapsed > Self.recallDeadline { return .stall(.dronesNotRecovered) }
        let out = RepairFleet.bots(deployedAt: vessel.location, in: world)
        if out.isEmpty { return .advanceTarget }
        if out.contains(where: { $0.updatedAt < directive.stepStartedAt }) {
            let lastLook = out.map(\.updatedAt).min() ?? .distantPast
            if world.now.timeIntervalSince(lastLook) < Self.botProbeInterval { return .wait }
            return .refreshDevices(deviceCodes: out.map(\.deviceCode), thenStall: nil)
        }
        return .advanceStep(nextStep: Step.stowingBots)
    }
}
