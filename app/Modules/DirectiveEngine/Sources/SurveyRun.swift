//
//  SurveyRun.swift
//  Replicould — DirectiveEngine
//
//  Fly a vessel down a queue of target systems and survey each one: set the
//  stowed AMI controller's `survey_system` directive, launch it (which deploys
//  its adopted stowed drones), wait for completion, move on.
//
//  **Staging is the player's job.** The run uses an AMI survey controller that
//  is ALREADY stowed aboard the vessel and drones that controller has ALREADY
//  adopted. It never stows and never adopts — adoption is persistent state that
//  would outlive the mission, and re-parenting someone's fleet behind their back
//  is not the engine's call. Missing either is a stall with a reason naming it.
//
//  Pure by contract: no I/O, no clock reads (time comes from `world.now`), no
//  randomness. Every effect is the returned `MissionAction`. That is what makes
//  the stall matrix a table of plain function calls over fixtures.
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

    /// This mission's step vocabulary. Plain strings because `Directive.step` is
    /// deliberately untyped — each kind owns its own vocabulary.
    public enum Step {
        public static let preflight = "preflight"
        public static let travelling = "travelling"
        public static let configuring = "configuring"
        public static let launching = "launching"
        public static let awaiting = "awaiting"
        public static let confirming = "confirming"
        public static let recovering = "recovering"
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
    /// Generous, because it is now a genuine backstop rather than the primary
    /// timer: the ETA-driven wait below handles the honest cases, so reaching
    /// this means the recall really is not happening.
    public static let recallDeadline: TimeInterval = 20 * 60

    /// How old a row backing a POSITIVE staging finding may be and still be
    /// believed without an authoritative re-read.
    ///
    /// Staging is judged from `stowedInDeviceCode` columns, and survey drones
    /// emit no events at all — so a drone abandoned in another system keeps
    /// claiming it is aboard until something reads it. The existing
    /// `.refreshDevices` net guards only the *negative* direction ("we see
    /// nothing, but have we been allowed to look?"); this is the same doubt
    /// applied to a positive, which is the direction that actually loses a
    /// fleet. Costs at most one read round per target.
    public static let stagingFreshness: TimeInterval = 5 * 60

    /// The survey configuration this mission insists on: a FULL survey with the
    /// drones recalled when done, so the vessel can move on to the next target
    /// (spec §4 step 4). Deliberately different from the composer's manual
    /// default (`moons: none`) — a Survey Run means the whole system.
    public static let surveyConfig: [String: JSONValue] = [
        "planets": .string("all"),
        "moons": .string("all"),
        "recall": .bool(true),
    ]

    public func nextAction(directive: Directive, world: WorldSnapshot) -> MissionAction {
        guard let vessel = world.device(directive.deviceCode) else {
            return .stall(.unreachableDevice)
        }
        switch directive.step {
        case Step.preflight: return preflight(directive, vessel, world)
        case Step.travelling: return travel(directive, vessel, world)
        case Step.configuring: return configure(directive, vessel, world)
        case Step.launching: return launch(directive, vessel, world)
        case Step.awaiting: return awaitCompletion(directive, world)
        case Step.confirming: return confirm(directive, world)
        case Step.recovering: return recover(directive, vessel, world)
        case Step.returning: return returnHome(directive, vessel, world)
        default:
            // An unrecognised step must never dispatch. Waiting is inert and
            // recoverable; the user can cancel or the row can be repaired.
            logger.notice("survey run \(directive.id, privacy: .public): unknown step \(directive.step, privacy: .public) — waiting")
            return .wait
        }
    }

    // MARK: - Fleet queries

    /// The AMI survey controller stowed aboard this vessel, if any. Forwards to
    /// the shared `AMIFleet` query (extracted 2026-07-30 so `SalvageRun` can
    /// share the identical two-ended read) — see there for the full "why".
    public static func controller(aboard vessel: Device, in world: WorldSnapshot) -> Device? {
        AMIFleet.stowed(aboard: vessel, in: world, offering: "survey_system")
    }

    /// The controller's adopted drones that are also aboard the vessel. Forwards
    /// to `AMIFleet` — see there for why adoption is read from both ends of the
    /// controller/drone link.
    public static func adoptedDrones(
        of controller: Device, aboard vessel: Device, in world: WorldSnapshot
    ) -> [Device] {
        AMIFleet.adoptedDrones(of: controller, aboard: vessel, in: world)
    }

    /// Every device this controller has adopted, wherever it currently is —
    /// including the ones still deployed. Forwards to `AMIFleet` — see there for
    /// why the recall gate needs the whole set rather than just the ones aboard.
    public static func adoptedDrones(of controller: Device, in world: WorldSnapshot) -> [Device] {
        AMIFleet.adoptedDrones(of: controller, in: world)
    }

    /// Whether any row backing a staging finding is too old to act on.
    ///
    /// One stale row is enough: the claim "everything needed is aboard" is a
    /// conjunction, so its weakest member decides how much it is worth.
    static func stagingIsStale(_ devices: [Device], _ world: WorldSnapshot) -> Bool {
        devices.contains { world.now.timeIntervalSince($0.updatedAt) > stagingFreshness }
    }

    /// Whether a system's scan counts say it is completely surveyed.
    ///
    /// Forwards to `StarSystem.isFullyScanned`, which is the one definition —
    /// shared with the persistence layer that stamps `stars.fullyScannedAt`, so
    /// the picker, the engine, and the catalog can never disagree about whether
    /// a system is done. The `nil`-tolerance stays here: a system we hold no
    /// blob for is not evidence of completeness.
    public static func isFullyScanned(_ system: StarSystem?) -> Bool {
        system?.isFullyScanned ?? false
    }

    /// The star system a device is currently in, or nil in transit / stowed.
    static func system(of device: Device) -> String? {
        device.location.map { SiteAssay.system(of: $0) }
    }

    // MARK: - Completion detection (spec §5)

    /// How long to wait on the `directive.completed` fast path before polling
    /// the counts anyway. A dropped SSE frame must not strand a run forever, and
    /// ten minutes keeps the cost to a handful of reads per survey.
    public static let backstopInterval: TimeInterval = 10 * 60

    /// Tolerance when comparing a completion's time against the step's start.
    /// Same value and reasoning as `Reconciler.eventTimeSkewTolerance`.
    static let eventTimeSkewTolerance: TimeInterval = 5

    /// Whether a completion for THIS step has landed in the timeline.
    ///
    /// Issue-time relative, not wall-clock: a completion delivered by catch-up
    /// after the app was closed still counts, while one predating this step is a
    /// replay and does not. Same guard shape as
    /// `Reconciler.completeOpenOperation` and the `directive.*` route.
    public static func completionSeen(_ directive: Directive, _ world: WorldSnapshot) -> Bool {
        saw(.directiveCompleted, directive, world)
    }

    /// Whether a launch reporting zero deployed devices landed in THIS step.
    ///
    /// A launch that deployed nothing cannot produce the completion `awaiting`
    /// is waiting for, so this turns a permanent wait into a named stall. Same
    /// issue-time guard as completions, and for the same reason in reverse: a
    /// Retry must not re-stall on the very launch it was retrying.
    public static func emptyLaunchSeen(_ directive: Directive, _ world: WorldSnapshot) -> Bool {
        saw(.launchDeployedNothing, directive, world)
    }

    /// Whether an entry of `kind` belongs to the directive's current step.
    private static func saw(
        _ kind: DirectiveLogKind, _ directive: Directive, _ world: WorldSnapshot
    ) -> Bool {
        world.log.contains { entry in
            entry.kind == kind
                && entry.occurredAt >= directive.stepStartedAt
                    .addingTimeInterval(-eventTimeSkewTolerance)
        }
    }

    // MARK: - Steps

    private func preflight(_ directive: Directive, _ vessel: Device, _ world: WorldSnapshot) -> MissionAction {
        guard let target = directive.currentTarget else {
            // A CONTINUOUS run never exhausts its queue — it extends it. Checked
            // before the return leg so the two stay independently expressible:
            // nothing sets both today, but "roam, then come home" should remain a
            // matter of setting both flags rather than needing new code.
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
        // Both staging checks are NEGATIVE findings over local rows, and a local
        // row can be silent for two very different reasons: nothing is aboard, or
        // nobody has been allowed to look lately (the confirm-read that would say
        // so is `.low` and the read budget may have deferred it for minutes).
        // Only the first is worth stopping a run for, so demand an authoritative
        // look before surfacing either — the engine re-asks once against fresh
        // rows and stalls with the carried reason if the answer holds.
        guard let controller = Self.controller(aboard: vessel, in: world) else {
            return .refreshDevices(
                deviceCodes: [vessel.deviceCode], thenStall: .noSurveyControllerAboard
            )
        }
        let drones = Self.adoptedDrones(of: controller, aboard: vessel, in: world)
        guard !drones.isEmpty else {
            // The controller too: `controlled_devices` is detail-only, so a
            // list-synced controller under-reports adoption and the drones' own
            // `controller_device_code` is the half that survives — reading both
            // ends is what makes this answer trustworthy.
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
        // The staging answer is positive — but it rests on rows that only a
        // read can correct, and believing a stale one is how six drones were
        // left in POLARISUM. Demand an authoritative look before committing the
        // vessel to a departure. After a successful refresh these rows are
        // fresh and this is inert; the engine only stalls here if the reads
        // themselves could not be had, which `.unreachableDevice` names
        // honestly.
        if Self.stagingIsStale([vessel, controller] + drones, world) {
            // Name every row the check covers, drones included. The engine's
            // carrier expansion reads the VESSEL's `stowed_devices` blob, which
            // is not a reliable inverse of the drones' own `stowedInDeviceCode`
            // columns — a live vessel listed one unrelated matrix while six
            // drones claimed to be aboard it. Naming only the vessel left the
            // drone rows exactly as stale as before, so the check could never
            // be satisfied and the run stalled for five and a half hours.
            return .refreshDevices(
                deviceCodes: [vessel.deviceCode, controller.deviceCode] + drones.map(\.deviceCode),
                thenStall: .unreachableDevice
            )
        }
        return .assignController(deviceCode: controller.deviceCode, nextStep: Step.travelling)
    }

    /// The riskiest wait in the design: the controller drives its drones
    /// server-side, so there is no operation the app created to key off. Two
    /// tiers — the completion entry the `directive.*` route writes, and a
    /// counts poll as the lost-event backstop.
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

    private func confirm(_ directive: Directive, _ world: WorldSnapshot) -> MissionAction {
        guard let target = directive.currentTarget else {
            return .advanceStep(nextStep: Step.preflight)
        }
        // Confirmed done — but NOT free to leave. `recall: true` means the AMI
        // is only now flying its drones home, so departing on this evidence
        // strands them (see `recover`).
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

    /// Hold the vessel until the AMI's recall has actually landed every adopted
    /// drone back aboard.
    ///
    /// This gate is the whole reason the step exists. `directive.completed`
    /// means *the survey* finished, NOT *the recall* — verified live on
    /// 2026-07-26, where the completion event and the controller's own
    /// `device.stowed` arrived in the same second while the digest showed all
    /// six drones had only just departed for the rendezvous. The run read that
    /// as clearance and dispatched the vessel 16 seconds later; the drones were
    /// left in POLARISUM, and the next launch deployed nothing.
    ///
    /// Placed BEFORE `.advanceTarget` on purpose, so it covers both ways a
    /// vessel leaves: the next target's travel leg, and the queue-exhausted leg
    /// home. The latter is where the drones were actually lost, and preflight's
    /// staging checks never run on it.
    private func recover(_ directive: Directive, _ vessel: Device, _ world: WorldSnapshot) -> MissionAction {
        guard let controller = claimedController(directive, vessel, world) else {
            // Nothing to recall, and a vanished controller is preflight's
            // diagnosis to make — holding the run here would stall on a reason
            // that doesn't name the real problem.
            return .advanceTarget
        }
        let adopted = Self.adoptedDrones(of: controller, in: world)
        let stranded = adopted.filter { $0.stowedInDeviceCode != vessel.deviceCode }
        if stranded.isEmpty { return .advanceTarget }

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
        // Name the drones whose own rows decide this gate — never a location
        // scope. Stowing a device CLEARS its location, so a location-scoped list
        // cannot report the very state this step waits for: the success
        // condition erases the evidence. Live on 2026-07-29,
        // `GET devices?location=ESELLUSAU` returned exactly ONE row (the vessel)
        // while all six drones sat stowed aboard it reporting `location: null`.
        // Their rows never moved, so `lastLook` never advanced either and the
        // probe re-fired on every tick until the deadline surfaced
        // `dronesNotRecovered` over a fully recovered fleet.
        //
        // `resolveRefresh` reads each named code directly, which reports a
        // stowed drone wherever it is and an in-transit one with its travel
        // block — the carrier expansion is an addition to that, not the
        // mechanism, which is what the old "a named probe could miss the rows it
        // judges" reasoning conflated. Naming the DRONES also sidesteps the
        // vessel's `stowed_devices` blob, which is not a reliable inverse of
        // these columns (see preflight). Costs one read per drone still out —
        // the price preflight already pays per target, and it shrinks as they
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

    private func returnHome(_ directive: Directive, _ vessel: Device, _ world: WorldSnapshot) -> MissionAction {
        guard let origin = directive.originDesignation else { return .done }
        if Self.system(of: vessel) == origin { return .done }
        if world.openOperation(for: vessel.deviceCode) != nil { return .wait }
        return .dispatch(
            kind: .travel, deviceCode: vessel.deviceCode,
            params: CommandParams(destination: origin), nextStep: Step.returning
        )
    }

    /// The controller this run claimed, re-resolved from the fleet on every
    /// evaluation — the row is the checkpoint, and a controller since released
    /// or decommissioned must surface rather than be dispatched at.
    private func claimedController(_ directive: Directive, _ vessel: Device, _ world: WorldSnapshot) -> Device? {
        guard let code = directive.controllerCode else {
            return Self.controller(aboard: vessel, in: world)
        }
        return world.device(code)
    }

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

    private func travel(_ directive: Directive, _ vessel: Device, _ world: WorldSnapshot) -> MissionAction {
        guard let target = directive.currentTarget else {
            return .advanceStep(nextStep: Step.preflight)
        }
        if Self.system(of: vessel) == target { return .advanceStep(nextStep: Step.configuring) }
        // An open op means the trip is under way. Expected, not a stall — and
        // the guard that stops a second travel landing on top of the first.
        if world.openOperation(for: vessel.deviceCode) != nil { return .wait }
        return .dispatch(
            kind: .travel, deviceCode: vessel.deviceCode,
            params: CommandParams(destination: target), nextStep: Step.travelling
        )
    }
}
