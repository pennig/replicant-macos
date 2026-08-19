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
    public var firstStep: String { Step.preflight.rawValue }

    public init() {}

    /// This mission's step vocabulary, as `Directive.step` holds it (D6).
    public enum Step: String, CaseIterable, Sendable {
        /// Prove the staging aboard the vessel before committing to a target.
        case preflight
        /// Fly the vessel to the current target system.
        case travelling
        /// Put the service bots into the system so they can repair as it works.
        case deployingBots
        /// Read whether the ordered deploy landed before ordering the next.
        case confirmingBotDeploy
        /// Ensure each deployed bot carries an ACTIVE `service` directive.
        case armingBots
        /// Read whether an ordered arm landed before ordering the next.
        case confirmingBotArm
        /// Put `surveyConfig` in force on the stowed controller.
        case configuring
        /// Launch the controller, which deploys its adopted drones.
        case launching
        /// Wait out the survey itself.
        case awaiting
        /// Check the target's scan counts against the claimed completion.
        case confirming
        /// Scan the system itself, which is what puts counts in the payload.
        case scanning
        /// Hold the vessel until every recalled drone is back aboard.
        case recovering
        /// Hold the vessel while the service bots finish what they are repairing.
        case repairing
        /// Recall the deployed service bots before the vessel departs.
        case stowingBots
        /// Read whether the ordered recall landed before ordering the next.
        case confirmingBotStow
        /// Fly the vessel back to the run's origin.
        case returning
    }

    /// The tag a row falls back to when it carries none of its own.
    public static let defaultFleetTag = FleetTag(goal: .survey)

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
    public static let recallDeadline: TimeInterval = 20 * 60  // recover's drone recovery — BotPhase does not own it

    /// The cap on system-scan attempts per visit to `confirming`. One POST covers
    /// the honest case; the rest rides out a transient. A retry writes `.resolved`,
    /// which ends the run of the loop and re-arms the whole budget.
    public static let scanRounds = 3

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
        guard let step = Step(rawValue: directive.step) else {
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
            // An empty hold skips arming: Survey configures and gets on with it.
            case .finished: .advanceStep(nextStep: Step.configuring.rawValue)
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
            case .finished: .advanceStep(nextStep: Step.configuring.rawValue)
            case .more: .advanceStep(nextStep: Step.armingBots.rawValue)
            case .noSubject: .stall(.unreachableDevice)
            }
        case .confirmingBotArm:
            return switch botPhase(.confirmArm, directive).next(ctx) {
            case let .action(action): action
            case .finished: .advanceStep(nextStep: Step.configuring.rawValue)
            case .more: .advanceStep(nextStep: Step.armingBots.rawValue)
            case .noSubject: .stall(.unreachableDevice)
            }
        case .configuring: return configure(directive, vessel, world)
        case .launching: return launch(directive, vessel, world)
        case .awaiting: return awaitCompletion(directive, vessel, world)
        case .confirming: return confirm(directive, vessel, world)
        case .scanning: return scanSystem(directive)
        case .recovering: return recover(directive, vessel, world)
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
        case .returning: return returnHome(directive, vessel, world)
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
            runNoun: "survey run", unrepairedStep: Step.armingBots.rawValue
        )
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

    /// How long to wait on the `directive.completed` fast path before falling
    /// back to the controller's own row as completion evidence, and the floor
    /// between the controller reads that fallback buys.
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
            return .advanceStep(nextStep: Step.returning.rawValue)
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
        return .assignController(deviceCode: controller.deviceCode, nextStep: Step.travelling.rawValue)
    }

    /// Wait out `directive`'s survey against `world`. The completion entry the
    /// `directive.*` route writes is the fast path; the controller's own row
    /// re-stowed aboard `vessel` is the lost-event backstop. Counts never decide.
    private func awaitCompletion(_ directive: Directive, _ vessel: Device, _ world: WorldSnapshot) -> MissionAction {
        guard let target = directive.currentTarget else {
            return .advanceStep(nextStep: Step.preflight.rawValue)
        }
        if Self.completionSeen(directive, world) {
            return .refreshSystem(designation: target, nextStep: Step.confirming.rawValue)
        }
        // The controller told us this launch deployed nothing. No drones are
        // out, so no completion is coming and the backstop would poll an empty
        // system every ten minutes until someone noticed. Surface it now.
        if Self.emptyLaunchSeen(directive, world) { return .stall(.launchDeployedNothing) }
        let ctx = StepContext(directive: directive, world: world, step: directive.step)
        guard ctx.elapsed > Self.backstopInterval, let controller = claimedController(directive, vessel, world)
        else { return .wait }
        // Re-stowed after the launch means the survey is over; the counts
        // cross-check happens in `confirming`.
        if controller.stowedInDeviceCode == vessel.deviceCode,
           controller.updatedAt >= directive.stepStartedAt
               .addingTimeInterval(-Self.eventTimeSkewTolerance) {
            return .refreshSystem(designation: target, nextStep: Step.confirming.rawValue)
        }
        // No deadline; `.age(backstopInterval)` makes the freshness check the same
        // test as the throttle — one controller read per backstop interval.
        var ladder = ConfirmRow(deadline: .infinity, onExpiry: .judge)
        ladder.watermark = .age(Self.backstopInterval)
        ladder.readInterval = Self.backstopInterval
        return switch ladder.verdict([controller], ctx) {
        case let .act(action): action
        case .judge: .wait
        }
    }

    /// Judge `directive`'s current target against `world`'s freshly-read scan
    /// counts: done, contradicted, or still running.
    private func confirm(_ directive: Directive, _ vessel: Device, _ world: WorldSnapshot) -> MissionAction {
        guard let target = directive.currentTarget else {
            return .advanceStep(nextStep: Step.preflight.rawValue)
        }
        // Confirmed done, but NOT free to leave. `recall: true` means the AMI is
        // only now flying its drones home, so departing on this evidence strands
        // them (see `recover`).
        if Self.isFullyScanned(world.system(target)) {
            return .advanceStep(nextStep: Step.recovering.rawValue)
        }
        // The server said it finished — event or re-stowed controller — and the
        // counts disagree; surface that rather than advancing over a half-survey.
        if Self.completionSeen(directive, world)
            || claimedController(directive, vessel, world)?.stowedInDeviceCode
                == vessel.deviceCode {
            // No counts AT ALL is a different fact from counts that fall short:
            // the payload carries them only once the system has been scanned, and
            // the drones scan bodies, never the system. Buy the scan first.
            if world.system(target)?.planetsTotal == nil, scanRoundsSpent(world) < Self.scanRounds {
                return .advanceStep(nextStep: Step.scanning.rawValue)
            }
            return .stall(.surveyIncomplete)
        }
        // A backstop poll that found it unfinished: nothing ever claimed
        // completion, so there is nothing to disbelieve. Keep waiting.
        return .advanceStep(nextStep: Step.awaiting.rawValue)
    }

    /// Ask the engine to scan `directive`'s current target.
    private func scanSystem(_ directive: Directive) -> MissionAction {
        guard let target = directive.currentTarget else {
            return .advanceStep(nextStep: Step.preflight.rawValue)
        }
        return .scanSystem(designation: target, nextStep: Step.confirming.rawValue)
    }

    /// Scans already spent in this unbroken run of the `scanning`/`confirming`
    /// loop. Off the log because `stepStartedAt` re-stamps on every hop.
    private func scanRoundsSpent(_ world: WorldSnapshot) -> Int {
        MissionLogBudget.dispatchRounds(world, dispatch: Step.scanning.rawValue, confirm: Step.confirming.rawValue)
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
            return .advanceStep(nextStep: Step.repairing.rawValue)
        }
        let adopted = Self.adoptedDrones(of: controller, in: world)
        let stranded = adopted.filter { $0.stowedInDeviceCode != vessel.deviceCode }
        if stranded.isEmpty { return .advanceStep(nextStep: Step.repairing.rawValue) }

        // No staleness gate: `.age(recallProbeInterval)` makes the freshness check
        // and the throttle the same test — a plain periodic poll, not one fresh read.
        let ctx = StepContext(directive: directive, world: world, step: directive.step)
        var ladder = ConfirmRow(deadline: Self.recallDeadline, onExpiry: .stallNow(.dronesNotRecovered))
        ladder.watermark = .age(Self.recallProbeInterval)
        ladder.probeDelay = Self.recallProbeDelay
        ladder.readInterval = Self.recallProbeInterval
        ladder.waitsOutArrival = true
        return switch ladder.verdict(stranded, ctx) {
        case let .act(action): action
        case .judge: .wait
        }
    }

    /// Fly `vessel` back to `directive`'s origin, finishing once `world` puts it
    /// in that system.
    private func returnHome(_ directive: Directive, _ vessel: Device, _ world: WorldSnapshot) -> MissionAction {
        let ctx = StepContext(directive: directive, world: world, step: directive.step)
        let home = ReturnHome(deviceCodes: [vessel.deviceCode], destination: .origin)
        return switch home.next(ctx) {
        case let .action(action): action
        case .finished, .more, .noSubject: .done
        }
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
            return .advanceStep(nextStep: Step.launching.rawValue)
        }
        return .dispatch(
            kind: .setDirective, deviceCode: controller.deviceCode,
            params: CommandParams(directive: "survey_system", configuration: Self.surveyConfig),
            nextStep: Step.launching.rawValue
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
            params: CommandParams(), nextStep: Step.awaiting.rawValue
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

    /// The fleet tag `directive` resolves against, falling back to
    /// `defaultFleetTag` for a row that carries none of its own.
    static func fleetTag(_ directive: Directive) -> FleetTag {
        directive.fleetTag.flatMap(FleetTag.init(parsing:)) ?? Self.defaultFleetTag
    }

    /// The tag `Brain.ensureSurvey` stamps for a theatre at `depot` — the mine
    /// ferry tag's sibling, per theatre rather than per belt.
    public static func fleetTag(forTheatre depot: String) -> FleetTag {
        FleetTag(goal: .survey, scope: .theatre(depot: depot))
    }

    /// Whether `device` wears `depot`'s survey tag, its own or the bare one it
    /// falls back from — the operator's opt-in, wherever the device stands.
    /// Fleet MEMBERSHIP is `isFleetTagged`.
    static func wearsFleetTag(_ device: Device, at depot: String) -> Bool {
        device.carries(fleetTag(forTheatre: depot), policy: .exactOrUnscoped)
    }

    /// Whether `depot` may spend `device` — `FleetMembership.isDeployable`:
    /// its survey fleet by tag or location, and placeable by the census.
    static func isFleetTagged(_ device: Device, at depot: String, resolver: TheatreResolver) -> Bool {
        FleetMembership.isDeployable(device, toDepot: depot, goal: .survey, resolver: resolver)
    }

}
