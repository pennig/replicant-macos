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

/// The SAME staged fleet as `stagedFleet`, but as the fleet-wide sync actually
/// stores it: `GET devices` omits `controlled_devices` (that key is detail-only,
/// from `GET devices/{code}`), so the controller's blob carries no adoption list
/// and the link survives only in the drone's `controller_device_code` column.
/// This is the shape a real launcher sees for a controller nobody has opened the
/// inspector on.
private func listSyncedFleet(vesselAt location: String = "SOL-3") -> [Device] {
    [
        device("VES1", type: "transport_hauler", location: location),
        device("AMI1", type: "ami_survey_controller", location: location,
               stowedIn: "VES1", directives: ["survey_system", "belt_search"]),
        device("DRONE1", type: "survey_drone", location: location,
               stowedIn: "VES1", controlledBy: "AMI1"),
    ]
}

/// The fleet the moment a survey finishes: the controller has already stowed
/// itself back aboard, but only `aboard` of its `adopted` drones have made it
/// home — the rest are still flying in from all over the system.
///
/// This is the real shape observed on 2026-07-26: `directive.completed` and the
/// controller's `device.stowed` landed in the same second, while the digest
/// showed all six drones had only just departed for the rendezvous.
private func recallingFleet(
    aboard: Int, adopted: Int = 3, vesselAt location: String = "TAU-2"
) -> [Device] {
    var fleet = [
        device("VES1", type: "transport_hauler", location: location),
        device("AMI1", type: "ami_survey_controller", location: location,
               stowedIn: "VES1", directives: ["survey_system"]),
    ]
    for index in 0..<adopted {
        let home = index < aboard
        fleet.append(device(
            "DRONE\(index)", type: "survey_drone",
            location: home ? location : "TAU-\(index + 3)",
            stowedIn: home ? "VES1" : nil, controlledBy: "AMI1"
        ))
    }
    return fleet
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

/// The reason a world ultimately surfaces, whether the machine stalls with it
/// directly or demands an authoritative read first.
///
/// Preflight's two staging checks are NEGATIVE findings over local rows, and a
/// local row can be silent because nothing is aboard OR because the `.low`
/// confirm-read that would say so has been deferred under read-budget pressure.
/// So they route through `.refreshDevices`, and the engine re-asks once against
/// fresh rows before stalling with the carried reason
/// (`DirectiveEngineCore.resolveRefresh`). The matrix below asserts the REASON —
/// its actual contract, "every way the world can fail the run has a named
/// outcome" — while `SurveyRunStagingFreshnessTests` pins the demand-a-read
/// step itself.
private func stallReason(_ action: MissionAction) -> DirectiveAttentionReason? {
    switch action {
    case let .stall(reason): return reason
    case let .refreshDevices(_, thenStall): return thenStall
    default: return nil
    }
}

// MARK: - Stall matrix

@Suite("Survey Run — stall matrix")
struct SurveyRunStallTests {
    /// No controller stowed aboard: staging one is the player's job, so the run
    /// stalls with a reason naming exactly what's missing.
    @Test func stallsWithNoControllerAboard() {
        let fleet = [device("VES1", type: "transport_hauler")]
        #expect(stallReason(SurveyRun().nextAction(directive: run(), world: world(fleet)))
                == .noSurveyControllerAboard)
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
        #expect(stallReason(SurveyRun().nextAction(directive: run(), world: world(fleet)))
                == .noSurveyControllerAboard)
    }

    /// Controller aboard but no adopted drone with it: `launch` would deploy
    /// nothing and the survey would never start.
    @Test func stallsWithNoAdoptedDroneAboard() {
        let fleet = [
            device("VES1", type: "transport_hauler"),
            device("AMI1", type: "ami_survey_controller", stowedIn: "VES1",
                   directives: ["survey_system"]),
        ]
        #expect(stallReason(SurveyRun().nextAction(directive: run(), world: world(fleet)))
                == .noSurveyDroneAboard)
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
        #expect(stallReason(SurveyRun().nextAction(directive: run(), world: world(fleet)))
                == .noSurveyDroneAboard)
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
        #expect(stallReason(SurveyRun().nextAction(directive: run(), world: world(fleet)))
                == .noSurveyDroneAboard)
    }

    /// The vessel isn't in the fleet at all (decommissioned, or never read).
    @Test func stallsOnAMissingVessel() {
        #expect(SurveyRun().nextAction(directive: run(), world: world([]))
                == .stall(.unreachableDevice))
    }
}

// MARK: - Staging freshness

/// Preflight must not read stale silence as "not staged".
///
/// The bug this pins: a run's second target stalled `noSurveyControllerAboard`
/// on a controller the server had already re-stowed after the first survey's
/// recall. The stow event had arrived and marked the device stale, but the
/// repair read was `.low` and the read budget sat at its floor, so it was
/// deferred for minutes. Preflight then judged the vessel unstaged from rows the
/// app itself knew were stale — and Retry, which re-runs a pure function over an
/// unchanged snapshot, could never clear it.
@Suite("Survey Run — staging freshness")
struct SurveyRunStagingFreshnessTests {
    /// A missing controller demands an authoritative read of the VESSEL before
    /// it counts: the vessel's own row is what names who is aboard, and the
    /// engine expands that into reads of the children.
    @Test func missingControllerDemandsAReadFirst() {
        let fleet = [device("VES1", type: "transport_hauler")]
        #expect(SurveyRun().nextAction(directive: run(), world: world(fleet))
                == .refreshDevices(deviceCodes: ["VES1"], thenStall: .noSurveyControllerAboard))
    }

    /// A missing drone demands the controller too — `controlled_devices` is
    /// detail-only, so a list-synced controller under-reports adoption and only
    /// reading both ends of the link makes the answer trustworthy.
    @Test func missingDroneDemandsVesselAndControllerReads() {
        let fleet = [
            device("VES1", type: "transport_hauler"),
            device("AMI1", type: "ami_survey_controller", stowedIn: "VES1",
                   directives: ["survey_system"]),
        ]
        #expect(SurveyRun().nextAction(directive: run(), world: world(fleet))
                == .refreshDevices(deviceCodes: ["VES1", "AMI1"],
                                   thenStall: .noSurveyDroneAboard))
    }

    /// A properly staged vessel never asks for a read: the freshness demand is
    /// paid only when the answer would otherwise be a stall, so the happy path
    /// costs nothing.
    @Test func stagedVesselSpendsNoReads() {
        #expect(SurveyRun().nextAction(directive: run(), world: world(stagedFleet()))
                == .assignController(deviceCode: "AMI1", nextStep: SurveyRun.Step.travelling))
    }

    /// Same for the list-synced shape, where adoption survives only on the
    /// drone's column — it is staged, so no read is demanded.
    @Test func listSyncedStagedVesselSpendsNoReads() {
        #expect(SurveyRun().nextAction(directive: run(), world: world(listSyncedFleet()))
                == .assignController(deviceCode: "AMI1", nextStep: SurveyRun.Step.travelling))
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

    /// The same staging, read back from the fleet-wide sync rather than a
    /// per-device read. Adoption is legible only from the drone's
    /// `controller_device_code`, because `GET devices` never sends
    /// `controlled_devices` — and a properly staged vessel must not stall just
    /// because nobody happened to open the controller's inspector.
    @Test func preflightAcceptsAdoptionRecordedOnlyOnTheDrone() {
        #expect(SurveyRun().nextAction(directive: run(), world: world(listSyncedFleet()))
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

// MARK: - Completion detection

private func completionEntry(at occurredAt: Date) -> DirectiveLogEntry {
    DirectiveLogEntry(
        id: "L1", directiveID: "D1", deviceCode: "AMI1", kind: .directiveCompleted,
        summary: "Survey System completed at TAU", step: "awaiting",
        operationID: nil, eventID: "E1", occurredAt: occurredAt
    )
}

private func emptyLaunchEntry(at occurredAt: Date) -> DirectiveLogEntry {
    DirectiveLogEntry(
        id: "L9", directiveID: "D1", deviceCode: "AMI1", kind: .launchDeployedNothing,
        summary: "Launch deployed no devices", step: "awaiting",
        operationID: nil, eventID: "E9", occurredAt: occurredAt
    )
}

@Suite("Survey Run — completion detection")
struct SurveyRunCompletionTests {
    /// No completion yet, inside the backstop window: just wait. Cheap, and the
    /// common case for most of a survey's duration.
    @Test func waitsForCompletion() {
        let directive = run(step: SurveyRun.Step.awaiting, controllerCode: "AMI1",
                            stepStartedAt: Date(timeIntervalSince1970: 900))
        #expect(SurveyRun().nextAction(
            directive: directive,
            world: world(stagedFleet(vesselAt: "TAU-2"), now: Date(timeIntervalSince1970: 1_000))
        ) == .wait)
    }

    /// A completion entry triggers the confirming read (spec §5 fast path).
    @Test func completionEventTriggersTheConfirmingRead() {
        let directive = run(step: SurveyRun.Step.awaiting, controllerCode: "AMI1",
                            stepStartedAt: Date(timeIntervalSince1970: 900))
        let snapshot = world(
            stagedFleet(vesselAt: "TAU-2"),
            log: [completionEntry(at: Date(timeIntervalSince1970: 950))],
            now: Date(timeIntervalSince1970: 1_000)
        )
        #expect(SurveyRun().nextAction(directive: directive, world: snapshot)
                == .refreshSystem(designation: "TAU", nextStep: SurveyRun.Step.confirming))
    }

    /// A completion stamped BEFORE this step began is a replay — it must not end
    /// a survey that only just started. Issue-time relative, not wall-clock.
    @Test func ignoresAReplayedPreStepCompletion() {
        let directive = run(step: SurveyRun.Step.awaiting, controllerCode: "AMI1",
                            stepStartedAt: Date(timeIntervalSince1970: 900))
        let snapshot = world(
            stagedFleet(vesselAt: "TAU-2"),
            log: [completionEntry(at: Date(timeIntervalSince1970: 500))],
            now: Date(timeIntervalSince1970: 1_000)
        )
        #expect(SurveyRun().nextAction(directive: directive, world: snapshot) == .wait)
    }

    /// Within the 5s skew tolerance a marginally older entry still counts —
    /// client and server clocks are not identical.
    @Test func toleratesClockSkewOnTheCompletionGuard() {
        let directive = run(step: SurveyRun.Step.awaiting, controllerCode: "AMI1",
                            stepStartedAt: Date(timeIntervalSince1970: 900))
        let snapshot = world(
            stagedFleet(vesselAt: "TAU-2"),
            log: [completionEntry(at: Date(timeIntervalSince1970: 897))],
            now: Date(timeIntervalSince1970: 1_000)
        )
        #expect(SurveyRun().nextAction(directive: directive, world: snapshot)
                == .refreshSystem(designation: "TAU", nextStep: SurveyRun.Step.confirming))
    }

    /// A non-completion entry (a step marker) never triggers confirmation —
    /// the timeline is full of those.
    @Test func ignoresNonCompletionLogEntries() {
        let directive = run(step: SurveyRun.Step.awaiting, controllerCode: "AMI1",
                            stepStartedAt: Date(timeIntervalSince1970: 900))
        let stepEntry = DirectiveLogEntry(
            id: "L2", directiveID: "D1", deviceCode: nil, kind: .stepStarted,
            summary: "Step: awaiting", step: "awaiting", operationID: nil,
            eventID: nil, occurredAt: Date(timeIntervalSince1970: 950)
        )
        let snapshot = world(stagedFleet(vesselAt: "TAU-2"), log: [stepEntry],
                             now: Date(timeIntervalSince1970: 1_000))
        #expect(SurveyRun().nextAction(directive: directive, world: snapshot) == .wait)
    }

    /// A launch that deployed nothing can never produce a completion, so the
    /// wait is pointless — surface it instead of holding the run forever.
    ///
    /// This is the second half of the POLARISUM loss: with the drones left
    /// behind, `launch` reported `devices_deployed: 0` and the run sat in
    /// awaiting/confirming for ten hours because nothing read that number.
    @Test func stallsWhenTheLaunchDeployedNothing() {
        let directive = run(step: SurveyRun.Step.awaiting, controllerCode: "AMI1",
                            stepStartedAt: Date(timeIntervalSince1970: 900))
        let snapshot = world(
            stagedFleet(vesselAt: "TAU-2"),
            log: [emptyLaunchEntry(at: Date(timeIntervalSince1970: 950))],
            now: Date(timeIntervalSince1970: 1_000)
        )
        #expect(SurveyRun().nextAction(directive: directive, world: snapshot)
                == .stall(.launchDeployedNothing))
    }

    /// An empty launch belonging to an EARLIER step is not this step's evidence
    /// — a Retry must not re-stall on the launch it was retrying.
    @Test func ignoresAnEmptyLaunchFromAnEarlierStep() {
        let directive = run(step: SurveyRun.Step.awaiting, controllerCode: "AMI1",
                            stepStartedAt: Date(timeIntervalSince1970: 900))
        let snapshot = world(
            stagedFleet(vesselAt: "TAU-2"),
            log: [emptyLaunchEntry(at: Date(timeIntervalSince1970: 500))],
            now: Date(timeIntervalSince1970: 1_000)
        )
        #expect(SurveyRun().nextAction(directive: directive, world: snapshot) == .wait)
    }

    /// The lost-event backstop: after the interval, poll the counts even with no
    /// completion event. A dropped SSE frame must not strand the run forever.
    @Test func backstopPollsAfterTheInterval() {
        let directive = run(step: SurveyRun.Step.awaiting, controllerCode: "AMI1",
                            stepStartedAt: Date(timeIntervalSince1970: 900))
        let late = Date(timeIntervalSince1970: 900 + SurveyRun.backstopInterval + 1)
        #expect(SurveyRun().nextAction(
            directive: directive,
            world: world(stagedFleet(vesselAt: "TAU-2"), now: late)
        ) == .refreshSystem(designation: "TAU", nextStep: SurveyRun.Step.confirming))
    }

    /// Counts agree: the target is done — but the run goes to `recovering`
    /// first, never straight to the next target. See `SurveyRunRecoveryTests`.
    @Test func confirmingHandsOffToRecoveryWhenFullyScanned() {
        let scanned = StarSystem(designation: "TAU", planetsScanned: 4, planetsTotal: 4)
        let directive = run(step: SurveyRun.Step.confirming, controllerCode: "AMI1")
        let snapshot = world(
            stagedFleet(vesselAt: "TAU-2"),
            log: [completionEntry(at: Date(timeIntervalSince1970: 950))],
            systems: ["TAU": scanned], now: Date(timeIntervalSince1970: 1_000)
        )
        #expect(SurveyRun().nextAction(directive: directive, world: snapshot)
                == .advanceStep(nextStep: SurveyRun.Step.recovering))
    }

    /// A completion event whose counts DISAGREE stalls `surveyIncomplete` rather
    /// than silently advancing over a half-surveyed system (spec §5).
    @Test func confirmingStallsWhenTheEventDisagrees() {
        let partial = StarSystem(designation: "TAU", planetsScanned: 2, planetsTotal: 4)
        let directive = run(step: SurveyRun.Step.confirming, controllerCode: "AMI1")
        let snapshot = world(
            stagedFleet(vesselAt: "TAU-2"),
            log: [completionEntry(at: Date(timeIntervalSince1970: 950))],
            systems: ["TAU": partial], now: Date(timeIntervalSince1970: 1_000)
        )
        #expect(SurveyRun().nextAction(directive: directive, world: snapshot)
                == .stall(.surveyIncomplete))
    }

    /// A BACKSTOP poll that finds the survey unfinished goes back to waiting —
    /// nothing claimed completion, so there is nothing to disbelieve.
    @Test func backstopDisagreementReturnsToWaiting() {
        let partial = StarSystem(designation: "TAU", planetsScanned: 2, planetsTotal: 4)
        let directive = run(step: SurveyRun.Step.confirming, controllerCode: "AMI1")
        let snapshot = world(stagedFleet(vesselAt: "TAU-2"), systems: ["TAU": partial],
                             now: Date(timeIntervalSince1970: 1_000))
        #expect(SurveyRun().nextAction(directive: directive, world: snapshot)
                == .advanceStep(nextStep: SurveyRun.Step.awaiting))
    }
}

// MARK: - Drone recovery

/// The vessel must not leave until the recall has actually landed its drones.
///
/// The bug this pins (live, 2026-07-26 16:31:58): the POLARISUM survey finished,
/// `directive.completed` fired, the controller stowed itself in the same second
/// — and the run dispatched the vessel home 16 seconds later while all six
/// drones were still in flight to the rendezvous. They were left in POLARISUM.
/// The next run then launched a controller with nothing aboard
/// (`ami.launched devices_deployed: 0`) and waited forever on a survey that
/// could never start.
@Suite("Survey Run — drone recovery")
struct SurveyRunRecoveryTests {
    /// A confirmed survey no longer departs on the spot: the run enters
    /// `recovering` and lets the recall finish first.
    @Test func confirmingEntersRecoveryRatherThanDepartingImmediately() {
        let scanned = StarSystem(designation: "TAU", planetsScanned: 4, planetsTotal: 4)
        let directive = run(step: SurveyRun.Step.confirming, controllerCode: "AMI1")
        let snapshot = world(
            recallingFleet(aboard: 0),
            log: [completionEntry(at: Date(timeIntervalSince1970: 950))],
            systems: ["TAU": scanned], now: Date(timeIntervalSince1970: 1_000)
        )
        #expect(SurveyRun().nextAction(directive: directive, world: snapshot)
                == .advanceStep(nextStep: SurveyRun.Step.recovering))
    }

    /// Every adopted drone back aboard: the vessel is free to move on.
    @Test func advancesOnceEveryDroneIsAboard() {
        let directive = run(step: SurveyRun.Step.recovering, controllerCode: "AMI1")
        #expect(SurveyRun().nextAction(directive: directive, world: world(recallingFleet(aboard: 3)))
                == .advanceTarget)
    }

    /// Drones still out, inside the grace window: wait, and spend NO read. The
    /// drones emit no events of their own, so a poll is the only way to see them
    /// — which is exactly why it must not happen on every 5s tick.
    @Test func waitsWhileTheRecallIsInFlight() {
        let directive = run(step: SurveyRun.Step.recovering, controllerCode: "AMI1")
        #expect(SurveyRun().nextAction(directive: directive, world: world(recallingFleet(aboard: 0)))
                == .wait)
    }

    /// A PARTIAL recall is not a recall — leaving one drone behind is the whole
    /// failure this step exists to prevent.
    @Test func waitsWhenOnlySomeDronesAreAboard() {
        let directive = run(step: SurveyRun.Step.recovering, controllerCode: "AMI1")
        #expect(SurveyRun().nextAction(directive: directive, world: world(recallingFleet(aboard: 2)))
                == .wait)
    }

    /// Once the grace window expires, take one authoritative read round before
    /// believing rows that only a read can refresh.
    @Test func demandsAReadOnceTheGraceWindowExpires() {
        let directive = run(step: SurveyRun.Step.recovering, controllerCode: "AMI1",
                            stepStartedAt: Date(timeIntervalSince1970: 900))
        let late = Date(timeIntervalSince1970: 900 + SurveyRun.recallGrace + 1)
        #expect(SurveyRun().nextAction(
            directive: directive, world: world(recallingFleet(aboard: 0), now: late)
        ) == .refreshDevices(deviceCodes: ["VES1", "AMI1"], thenStall: .dronesNotRecovered))
    }

    /// A controller that adopted nothing has nothing to wait for — don't hold a
    /// run for a recall that will never report.
    @Test func advancesImmediatelyWhenNothingWasAdopted() {
        let directive = run(step: SurveyRun.Step.recovering, controllerCode: "AMI1")
        #expect(SurveyRun().nextAction(directive: directive,
                                       world: world(recallingFleet(aboard: 0, adopted: 0)))
                == .advanceTarget)
    }

    /// A drone adopted by a DIFFERENT controller is not this run's to wait for.
    @Test func ignoresDronesAdoptedElsewhere() {
        var fleet = recallingFleet(aboard: 0, adopted: 0)
        fleet.append(device("OTHER", type: "survey_drone", location: "TAU-9", controlledBy: "AMI9"))
        let directive = run(step: SurveyRun.Step.recovering, controllerCode: "AMI1")
        #expect(SurveyRun().nextAction(directive: directive, world: world(fleet)) == .advanceTarget)
    }

    /// The recovery gate covers the LAST target too — the leg home is where the
    /// drones were actually lost, and preflight's staging checks never run on it.
    @Test func recoveryGatesTheFinalTargetBeforeTheLegHome() {
        let scanned = StarSystem(designation: "TAU", planetsScanned: 4, planetsTotal: 4)
        let directive = run(step: SurveyRun.Step.confirming, targets: ["TAU"], targetIndex: 0,
                            controllerCode: "AMI1", returnToOrigin: true, origin: "SOL")
        let snapshot = world(
            recallingFleet(aboard: 0),
            log: [completionEntry(at: Date(timeIntervalSince1970: 950))],
            systems: ["TAU": scanned], now: Date(timeIntervalSince1970: 1_000)
        )
        #expect(SurveyRun().nextAction(directive: directive, world: snapshot)
                == .advanceStep(nextStep: SurveyRun.Step.recovering))
    }
}

// MARK: - Finishing

@Suite("Survey Run — finishing")
struct SurveyRunFinishTests {
    /// Queue exhausted with returnToOrigin off: done, and the vessel stays put
    /// ready to be chained onward.
    @Test func finishesWithoutReturning() {
        let directive = run(targets: ["TAU"], targetIndex: 1)
        #expect(SurveyRun().nextAction(directive: directive, world: world(stagedFleet(vesselAt: "TAU-2")))
                == .done)
    }

    /// returnToOrigin on and away from home: one final leg.
    @Test func returnsToOriginWhenAsked() {
        let directive = run(targets: ["TAU"], targetIndex: 1, returnToOrigin: true, origin: "SOL")
        #expect(SurveyRun().nextAction(directive: directive, world: world(stagedFleet(vesselAt: "TAU-2")))
                == .advanceStep(nextStep: SurveyRun.Step.returning))
    }

    /// Already home: done, no pointless leg.
    @Test func doesNotReturnWhenAlreadyHome() {
        let directive = run(targets: ["TAU"], targetIndex: 1, returnToOrigin: true, origin: "SOL")
        #expect(SurveyRun().nextAction(directive: directive, world: world(stagedFleet(vesselAt: "SOL-3")))
                == .done)
    }

    /// The return leg dispatches travel home, then completes on arrival.
    @Test func returningTravelsHomeThenCompletes() {
        let directive = run(step: SurveyRun.Step.returning, targets: ["TAU"], targetIndex: 1,
                            returnToOrigin: true, origin: "SOL")
        #expect(SurveyRun().nextAction(directive: directive, world: world(stagedFleet(vesselAt: "TAU-2")))
                == .dispatch(kind: .travel, deviceCode: "VES1",
                             params: CommandParams(destination: "SOL"),
                             nextStep: SurveyRun.Step.returning))
        #expect(SurveyRun().nextAction(directive: directive, world: world(stagedFleet(vesselAt: "SOL-3")))
                == .done)
    }

    /// The return leg waits while in transit rather than re-dispatching.
    @Test func returningWaitsWhileTravelling() {
        let directive = run(step: SurveyRun.Step.returning, targets: ["TAU"], targetIndex: 1,
                            returnToOrigin: true, origin: "SOL")
        #expect(SurveyRun().nextAction(directive: directive,
                                       world: world(stagedFleet(vesselAt: "TAU-2"), travelling: true))
                == .wait)
    }
}
