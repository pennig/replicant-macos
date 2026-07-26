//
//  SurveyRunTests.swift
//  Replicould — DirectiveEngine
//
//  The Survey Run step machine as a pure function table. The stall matrix
//  (design spec §8) is the priority suite: every way the world can fail the run
//  has a named, tested outcome, because the engine pauses and surfaces rather
//  than improvising.
//
//  The run does NOT stow or adopt anything (operator decision, 2026-07-26):
//  staging is the player's job, so "not staged" is a stall, never a step.
//

import Foundation
import GameModels
import GameServices
import Testing
import UniverseModels
import Utils
@testable import DirectiveEngine

// MARK: - Fixtures

private func device(
    _ code: String,
    type: String,
    location: String? = "SOL-3",
    stowedIn: String? = nil,
    controlledBy: String? = nil,
    controlled: [String] = [],
    directives: [String] = []
) -> Device {
    var detail: [String: JSONValue] = [:]
    if !controlled.isEmpty {
        detail["controlled_devices"] = .array(controlled.map { drone in
            .object(["device_code": .string(drone), "device_type": .string("survey_drone")])
        })
    }
    if !directives.isEmpty {
        detail["available_directives"] = .array(directives.map(JSONValue.string))
    }
    return Device(
        deviceCode: code, deviceType: type, replicantCode: "R1", status: "idle",
        location: location, locationName: nil, operationalCapacity: 100, queueSize: 0,
        stowedInDeviceCode: stowedIn, controllerDeviceCode: controlledBy,
        attachedToDeviceCode: nil, createdAt: Date(timeIntervalSince1970: 0),
        availableCommands: [], features: [], tags: [], detail: .object(detail),
        updatedAt: Date(timeIntervalSince1970: 0), firstSeenAt: Date(timeIntervalSince1970: 0)
    )
}

/// A vessel with a survey controller and one adopted drone stowed aboard — the
/// staged state a Survey Run REQUIRES.
private func stagedFleet(vesselAt location: String = "SOL-3") -> [Device] {
    [
        device("VES1", type: "transport_hauler", location: location),
        device("AMI1", type: "ami_survey_controller", location: location,
               stowedIn: "VES1", controlled: ["DRONE1"],
               directives: ["survey_system", "belt_search"]),
        device("DRONE1", type: "survey_drone", location: location,
               stowedIn: "VES1", controlledBy: "AMI1"),
    ]
}

private func withDirective(_ device: Device, name: String, config: [String: JSONValue]) -> Device {
    var updated = device
    var detail: [String: JSONValue] = {
        if case let .object(existing) = updated.detail { return existing }
        return [:]
    }()
    detail["ami_directive"] = .object(["name": .string(name), "config": .object(config)])
    updated.detail = .object(detail)
    return updated
}

private func world(
    _ devices: [Device],
    log: [DirectiveLogEntry] = [],
    systems: [String: StarSystem] = [:],
    travelling: Bool = false,
    now: Date = Date(timeIntervalSince1970: 1_000)
) -> WorldSnapshot {
    let openOps: [String: GameModels.Operation] = travelling
        ? ["VES1": GameModels.Operation(
            id: "OP1", entityCode: "VES1", kind: OperationKind.travel.rawValue,
            status: .active, source: .optimistic,
            startedAt: Date(timeIntervalSince1970: 0), completesAt: nil,
            lastConfirmedAt: Date(timeIntervalSince1970: 0), detail: .object([:])
        )]
        : [:]
    return WorldSnapshot(
        devices: Dictionary(devices.map { ($0.deviceCode, $0) }, uniquingKeysWith: { _, last in last }),
        openOperations: openOps, log: log, systems: systems, now: now
    )
}

private func run(
    step: String = SurveyRun.Step.preflight,
    targets: [String] = ["TAU"],
    targetIndex: Int = 0,
    controllerCode: String? = nil,
    returnToOrigin: Bool = false,
    origin: String? = "SOL",
    stepStartedAt: Date = Date(timeIntervalSince1970: 900)
) -> Directive {
    Directive(
        id: "D1", kind: .surveyRun, status: .running, deviceCode: "VES1",
        controllerCode: controllerCode, targets: targets, targetIndex: targetIndex,
        step: step, stepStartedAt: stepStartedAt, returnToOrigin: returnToOrigin,
        originDesignation: origin, attentionReason: nil,
        createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0)
    )
}

// MARK: - Stall matrix

@Suite("Survey Run — stall matrix")
struct SurveyRunStallTests {
    /// No controller stowed aboard: staging one is the player's job, so the run
    /// stalls with a reason naming exactly what's missing.
    @Test func stallsWithNoControllerAboard() {
        let fleet = [device("VES1", type: "transport_hauler")]
        #expect(SurveyRun().nextAction(directive: run(), world: world(fleet))
                == .stall(.noSurveyControllerAboard))
    }

    /// A controller that is co-located but NOT stowed doesn't count: `launch`
    /// deploys the controller's stowed devices, so one left standing alongside
    /// the vessel would be left behind the moment the vessel departs.
    @Test func stallsWhenTheControllerIsMerelyCoLocated() {
        let fleet = [
            device("VES1", type: "transport_hauler"),
            device("AMI1", type: "ami_survey_controller", controlled: ["DRONE1"],
                   directives: ["survey_system"]),
            device("DRONE1", type: "survey_drone", controlledBy: "AMI1"),
        ]
        #expect(SurveyRun().nextAction(directive: run(), world: world(fleet))
                == .stall(.noSurveyControllerAboard))
    }

    /// Controller aboard but no adopted drone with it: `launch` would deploy
    /// nothing and the survey would never start.
    @Test func stallsWithNoAdoptedDroneAboard() {
        let fleet = [
            device("VES1", type: "transport_hauler"),
            device("AMI1", type: "ami_survey_controller", stowedIn: "VES1",
                   directives: ["survey_system"]),
        ]
        #expect(SurveyRun().nextAction(directive: run(), world: world(fleet))
                == .stall(.noSurveyDroneAboard))
    }

    /// A drone stowed aboard but adopted by a DIFFERENT controller doesn't
    /// count — `launch` only deploys what this controller has adopted.
    @Test func stallsWhenTheDroneIsAdoptedElsewhere() {
        let fleet = [
            device("VES1", type: "transport_hauler"),
            device("AMI1", type: "ami_survey_controller", stowedIn: "VES1",
                   directives: ["survey_system"]),
            device("DRONE1", type: "survey_drone", stowedIn: "VES1", controlledBy: "AMI9"),
        ]
        #expect(SurveyRun().nextAction(directive: run(), world: world(fleet))
                == .stall(.noSurveyDroneAboard))
    }

    /// An adopted drone that was left behind (not stowed aboard this vessel)
    /// doesn't count either — it can't be deployed at the target.
    @Test func stallsWhenTheAdoptedDroneWasLeftBehind() {
        let fleet = [
            device("VES1", type: "transport_hauler"),
            device("AMI1", type: "ami_survey_controller", stowedIn: "VES1",
                   controlled: ["DRONE1"], directives: ["survey_system"]),
            device("DRONE1", type: "survey_drone", controlledBy: "AMI1"),
        ]
        #expect(SurveyRun().nextAction(directive: run(), world: world(fleet))
                == .stall(.noSurveyDroneAboard))
    }

    /// The vessel isn't in the fleet at all (decommissioned, or never read).
    @Test func stallsOnAMissingVessel() {
        #expect(SurveyRun().nextAction(directive: run(), world: world([]))
                == .stall(.unreachableDevice))
    }
}

// MARK: - Preflight and travel

@Suite("Survey Run — preflight and travel")
struct SurveyRunPreflightTests {
    /// A staged fleet claims its controller and moves to travel.
    @Test func preflightClaimsTheController() {
        #expect(SurveyRun().nextAction(directive: run(), world: world(stagedFleet()))
                == .assignController(deviceCode: "AMI1", nextStep: SurveyRun.Step.travelling))
    }

    /// A target the cache already shows fully scanned is SKIPPED, not surveyed
    /// (spec §5's precondition). Cached-only: the live read is presence-gated,
    /// so a system we haven't reached yet can only be judged from what we hold.
    @Test func skipsAnAlreadyScannedTarget() {
        let scanned = StarSystem(
            designation: "TAU", planetsScanned: 4, planetsTotal: 4,
            moonsScanned: 7, moonsTotal: 7
        )
        #expect(SurveyRun().nextAction(directive: run(), world: world(stagedFleet(), systems: ["TAU": scanned]))
                == .advanceTarget)
    }

    /// Planets done but moons outstanding is NOT a skip.
    @Test func doesNotSkipWhenMoonsAreOutstanding() {
        let partial = StarSystem(
            designation: "TAU", planetsScanned: 4, planetsTotal: 4,
            moonsScanned: 2, moonsTotal: 7
        )
        #expect(SurveyRun().nextAction(directive: run(), world: world(stagedFleet(), systems: ["TAU": partial]))
                == .assignController(deviceCode: "AMI1", nextStep: SurveyRun.Step.travelling))
    }

    /// Partial planet progress is not a skip either.
    @Test func doesNotSkipAPartiallyScannedTarget() {
        let partial = StarSystem(designation: "TAU", planetsScanned: 2, planetsTotal: 4)
        #expect(SurveyRun().nextAction(directive: run(), world: world(stagedFleet(), systems: ["TAU": partial]))
                == .assignController(deviceCode: "AMI1", nextStep: SurveyRun.Step.travelling))
    }

    /// Unknown counts never count as scanned. Surveying an already-done system
    /// wastes a trip; skipping an unscanned one loses the point of the run.
    @Test func unknownCountsAreNotScanned() {
        #expect(SurveyRun.isFullyScanned(nil) == false)
        #expect(SurveyRun.isFullyScanned(StarSystem(designation: "TAU")) == false)
        #expect(SurveyRun.isFullyScanned(StarSystem(designation: "TAU", planetsTotal: 0)) == false)
    }

    /// Travel is dispatched at the vessel, toward the target system.
    @Test func travelDispatchesTowardTheTarget() {
        let directive = run(step: SurveyRun.Step.travelling, controllerCode: "AMI1")
        #expect(SurveyRun().nextAction(directive: directive, world: world(stagedFleet()))
                == .dispatch(kind: .travel, deviceCode: "VES1",
                             params: CommandParams(destination: "TAU"),
                             nextStep: SurveyRun.Step.travelling))
    }

    /// Already in the target system: no travel command at all.
    @Test func skipsTravelWhenAlreadyThere() {
        let directive = run(step: SurveyRun.Step.travelling, controllerCode: "AMI1")
        #expect(SurveyRun().nextAction(directive: directive, world: world(stagedFleet(vesselAt: "TAU-2")))
                == .advanceStep(nextStep: SurveyRun.Step.configuring))
    }

    /// Mid-travel is a WAIT, never a stall (spec §4) — and never a second travel
    /// command stacked on the one already in flight.
    @Test func waitsWhileTravelling() {
        let directive = run(step: SurveyRun.Step.travelling, controllerCode: "AMI1")
        #expect(SurveyRun().nextAction(directive: directive, world: world(stagedFleet(), travelling: true))
                == .wait)
    }
}

// MARK: - Configure and launch

@Suite("Survey Run — configure and launch")
struct SurveyRunConfigureTests {
    /// A controller with no directive in force gets the full-survey config.
    @Test func setsTheSurveyDirective() {
        let directive = run(step: SurveyRun.Step.configuring, controllerCode: "AMI1")
        #expect(SurveyRun().nextAction(directive: directive, world: world(stagedFleet(vesselAt: "TAU-2")))
                == .dispatch(
                    kind: .setDirective, deviceCode: "AMI1",
                    params: CommandParams(directive: "survey_system", configuration: SurveyRun.surveyConfig),
                    nextStep: SurveyRun.Step.launching
                ))
    }

    /// An in-force directive that already matches EXACTLY is not re-issued
    /// (spec §4 step 4).
    @Test func skipsSetDirectiveWhenAlreadyExact() {
        var fleet = stagedFleet(vesselAt: "TAU-2")
        fleet[1] = withDirective(fleet[1], name: "survey_system", config: [
            "planets": .string("all"), "moons": .string("all"), "recall": .bool(true),
        ])
        let directive = run(step: SurveyRun.Step.configuring, controllerCode: "AMI1")
        #expect(SurveyRun().nextAction(directive: directive, world: world(fleet))
                == .advanceStep(nextStep: SurveyRun.Step.launching))
    }

    /// A MISMATCHED config is re-issued — `moons: none` left over from manual
    /// use would silently survey half the system.
    @Test func reissuesAMismatchedConfig() {
        var fleet = stagedFleet(vesselAt: "TAU-2")
        fleet[1] = withDirective(fleet[1], name: "survey_system", config: [
            "planets": .string("all"), "moons": .string("none"), "recall": .bool(true),
        ])
        let directive = run(step: SurveyRun.Step.configuring, controllerCode: "AMI1")
        guard case let .dispatch(kind, _, _, _) =
                SurveyRun().nextAction(directive: directive, world: world(fleet))
        else {
            Issue.record("expected the mismatched config to be re-issued")
            return
        }
        #expect(kind == .setDirective)
    }

    /// `recall: false` is a mismatch too — without recall the drones don't come
    /// home and the vessel can't move on to the next target.
    @Test func reissuesWhenRecallIsOff() {
        var fleet = stagedFleet(vesselAt: "TAU-2")
        fleet[1] = withDirective(fleet[1], name: "survey_system", config: [
            "planets": .string("all"), "moons": .string("all"), "recall": .bool(false),
        ])
        let directive = run(step: SurveyRun.Step.configuring, controllerCode: "AMI1")
        guard case let .dispatch(kind, _, _, _) =
                SurveyRun().nextAction(directive: directive, world: world(fleet))
        else {
            Issue.record("expected recall: false to be re-issued")
            return
        }
        #expect(kind == .setDirective)
    }

    /// A different directive entirely is replaced.
    @Test func replacesADifferentDirective() {
        var fleet = stagedFleet(vesselAt: "TAU-2")
        fleet[1] = withDirective(fleet[1], name: "belt_search", config: [:])
        let directive = run(step: SurveyRun.Step.configuring, controllerCode: "AMI1")
        guard case let .dispatch(kind, _, _, _) =
                SurveyRun().nextAction(directive: directive, world: world(fleet))
        else {
            Issue.record("expected a replacement")
            return
        }
        #expect(kind == .setDirective)
    }

    /// Launch goes to the CONTROLLER, not the vessel — it is what deploys the
    /// adopted stowed drones (spec §3).
    @Test func launchesTheController() {
        let directive = run(step: SurveyRun.Step.launching, controllerCode: "AMI1")
        #expect(SurveyRun().nextAction(directive: directive, world: world(stagedFleet(vesselAt: "TAU-2")))
                == .dispatch(kind: OperationKind.simple("launch"), deviceCode: "AMI1",
                             params: CommandParams(), nextStep: SurveyRun.Step.awaiting))
    }

    /// The controller vanishing mid-run (released, decommissioned) stalls rather
    /// than dispatching at a device that is no longer there.
    @Test func stallsWhenTheClaimedControllerIsGone() {
        let directive = run(step: SurveyRun.Step.launching, controllerCode: "AMI1")
        let fleet = [device("VES1", type: "transport_hauler", location: "TAU-2")]
        #expect(SurveyRun().nextAction(directive: directive, world: world(fleet))
                == .stall(.noSurveyControllerAboard))
    }
}
