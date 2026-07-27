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

    /// How long to let the AMI's post-survey recall run before demanding an
    /// authoritative read of who is actually aboard.
    ///
    /// A plain wait rather than a poll, deliberately: survey drones emit no
    /// per-device events at all (verified over a full day of live traffic —
    /// every one of their movements is rolled up into the controller's
    /// `ami.survey.digest`), so their stow columns only change when something
    /// reads them. Polling that on the engine's 5s tick would be a read storm
    /// for a fact that cannot change faster than the drones can fly. Waiting
    /// out the recall and then paying for ONE read round costs a handful of
    /// reads per target instead of hundreds.
    public static let recallGrace: TimeInterval = 5 * 60

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

    /// The AMI survey controller stowed aboard this vessel, if any.
    ///
    /// STOWED, not merely co-located: `launch` deploys the controller's stowed
    /// devices, and one left standing alongside the vessel is left behind the
    /// moment it departs. Identified by capability (`survey_system` in its
    /// available directives) rather than `device_type`, so a differently-named
    /// controller with the same capability still works — the fallback
    /// vocabulary behind `availableDirectives` covers only repair devices, so it
    /// can never make a non-controller match here.
    public static func controller(aboard vessel: Device, in world: WorldSnapshot) -> Device? {
        world.devices.values
            .filter { $0.stowedInDeviceCode == vessel.deviceCode }
            .filter { $0.availableDirectives.contains("survey_system") }
            .min { $0.deviceCode < $1.deviceCode }
    }

    /// The controller's adopted drones that are also aboard the vessel. Both
    /// halves matter: `launch` only deploys devices this controller has adopted,
    /// and only ones that actually travelled with it.
    ///
    /// Adoption is read from BOTH ends of the link, because only one end is
    /// always present. `controlled_devices` — the controller's side — ships only
    /// in the single-device payload (`GET devices/{code}`); the fleet-wide
    /// `GET devices` omits it entirely, and since a list sync rewrites the whole
    /// `detail` blob it also erases whatever a previous inspector read had put
    /// there. The drone's side, `controller_device_code`, is a promoted column
    /// present in every payload. Reading only the controller's side meant a
    /// perfectly staged vessel looked unstaged unless someone had recently
    /// opened that controller's inspector.
    public static func adoptedDrones(
        of controller: Device, aboard vessel: Device, in world: WorldSnapshot
    ) -> [Device] {
        adoptedDrones(of: controller, in: world)
            .filter { $0.stowedInDeviceCode == vessel.deviceCode }
    }

    /// Every device this controller has adopted, wherever it currently is —
    /// including the ones still deployed. The recall gate needs the whole set
    /// (the `aboard:` variant above answers a different question: who came
    /// along), because "some drones are home" is precisely the state that loses
    /// the others.
    public static func adoptedDrones(of controller: Device, in world: WorldSnapshot) -> [Device] {
        let claimed = Set(controller.controlledDeviceCodes)
        return world.devices.values
            .filter { $0.controllerDeviceCode == controller.deviceCode || claimed.contains($0.deviceCode) }
            .sorted { $0.deviceCode < $1.deviceCode }
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
    /// UNKNOWN counts are never "scanned": surveying an already-done system
    /// costs one wasted trip, but skipping an unscanned one silently loses the
    /// whole point of the run. Wrong in the cheap direction, deliberately.
    public static func isFullyScanned(_ system: StarSystem?) -> Bool {
        guard let system,
              let planetsTotal = system.planetsTotal, planetsTotal > 0,
              let planetsScanned = system.planetsScanned,
              planetsScanned >= planetsTotal
        else { return false }
        // Moons are optional in the payload; when the server reports a total, it
        // has to be met too.
        if let moonsTotal = system.moonsTotal, moonsTotal > 0 {
            guard let moonsScanned = system.moonsScanned, moonsScanned >= moonsTotal else {
                return false
            }
        }
        return true
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
            return .refreshDevices(
                deviceCodes: [vessel.deviceCode, controller.deviceCode],
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
        // Inside the grace window this is expected, not a fault: the drones are
        // simply still flying. Wait without spending a read — they emit no
        // events, so their rows can't move on their own, and polling a fact
        // that changes on a multi-minute scale at the 5s tick rate would burn
        // the read budget for nothing (see `recallGrace`).
        guard world.now.timeIntervalSince(directive.stepStartedAt) > Self.recallGrace else {
            return .wait
        }
        // Window expired. The rows saying "still out" are exactly the rows only
        // a read can refresh, so buy one authoritative look before conceding —
        // and if it holds, surface rather than depart without them.
        return .refreshDevices(
            deviceCodes: [vessel.deviceCode, controller.deviceCode],
            thenStall: .dronesNotRecovered
        )
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
