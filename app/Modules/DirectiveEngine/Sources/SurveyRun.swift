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
        public static let returning = "returning"
    }

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
        let claimed = Set(controller.controlledDeviceCodes)
        return world.devices.values
            .filter { $0.stowedInDeviceCode == vessel.deviceCode }
            .filter { $0.controllerDeviceCode == controller.deviceCode || claimed.contains($0.deviceCode) }
            .sorted { $0.deviceCode < $1.deviceCode }
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
        world.log.contains { entry in
            entry.kind == .directiveCompleted
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
        guard let controller = Self.controller(aboard: vessel, in: world) else {
            return .stall(.noSurveyControllerAboard)
        }
        guard !Self.adoptedDrones(of: controller, aboard: vessel, in: world).isEmpty else {
            return .stall(.noSurveyDroneAboard)
        }
        // Cached-only skip check: `GET locations/{star}` is presence-gated, so a
        // target we haven't reached can only be judged from what we already hold.
        if Self.isFullyScanned(world.system(target)) { return .advanceTarget }
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
        if world.now.timeIntervalSince(directive.stepStartedAt) > Self.backstopInterval {
            return .refreshSystem(designation: target, nextStep: Step.confirming)
        }
        return .wait
    }

    private func confirm(_ directive: Directive, _ world: WorldSnapshot) -> MissionAction {
        guard let target = directive.currentTarget else {
            return .advanceStep(nextStep: Step.preflight)
        }
        if Self.isFullyScanned(world.system(target)) { return .advanceTarget }
        // The server SAID it finished and the counts disagree — surface that
        // rather than advancing over a half-surveyed system.
        if Self.completionSeen(directive, world) { return .stall(.surveyIncomplete) }
        // A backstop poll that found it unfinished: nothing ever claimed
        // completion, so there is nothing to disbelieve. Keep waiting.
        return .advanceStep(nextStep: Step.awaiting)
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
