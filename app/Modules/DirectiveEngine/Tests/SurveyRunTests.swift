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

/// `updatedAt` defaults to the same instant `world(now:)` defaults to, so a
/// fixture fleet reads as freshly synced unless a test deliberately ages it.
/// Preflight now cares: a staging row old enough to be untrustworthy earns a
/// read before it is believed.
private let fixtureNow = Date(timeIntervalSince1970: 1_000)

private func device(
    _ code: String,
    type: String,
    location: String? = "SOL-3",
    stowedIn: String? = nil,
    controlledBy: String? = nil,
    controlled: [String] = [],
    directives: [String] = [],
    updatedAt: Date = fixtureNow,
    arrivesAt: Date? = nil
) -> Device {
    var detail: [String: JSONValue] = [:]
    if let arrivesAt {
        // A drone flying home under recall. Both timing fields agree: a recall
        // is a single hop within the system.
        detail["travel"] = .object([
            "arrives_at": .string(arrivesAt.ISO8601Format()),
            "final_arrives_at": .string(arrivesAt.ISO8601Format()),
        ])
    }
    if !controlled.isEmpty {
        detail["controlled_devices"] = .array(controlled.map { drone in
            .object(["device_code": .string(drone), "device_type": .string("survey_drone")])
        })
    }
    if !directives.isEmpty {
        detail["available_directives"] = .array(directives.map(JSONValue.string))
    }
    return Device(
        deviceCode: code, deviceType: type, replicantCode: "R1",
        status: arrivesAt == nil ? "idle" : "travelling",
        location: location, locationName: nil, operationalCapacity: 100, queueSize: 0,
        stowedInDeviceCode: stowedIn, controllerDeviceCode: controlledBy,
        attachedToDeviceCode: nil, createdAt: Date(timeIntervalSince1970: 0),
        availableCommands: [], features: [], tags: [], detail: .object(detail),
        updatedAt: updatedAt, firstSeenAt: Date(timeIntervalSince1970: 0)
    )
}

/// A vessel with a survey controller and one adopted drone stowed aboard — the
/// staged state a Survey Run REQUIRES.
private func stagedFleet(
    vesselAt location: String = "SOL-3", updatedAt: Date = fixtureNow
) -> [Device] {
    [
        device("VES1", type: "transport_hauler", location: location, updatedAt: updatedAt),
        device("AMI1", type: "ami_survey_controller", location: location,
               stowedIn: "VES1", controlled: ["DRONE1"],
               directives: ["survey_system", "belt_search"], updatedAt: updatedAt),
        device("DRONE1", type: "survey_drone", location: location,
               stowedIn: "VES1", controlledBy: "AMI1", updatedAt: updatedAt),
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
    aboard: Int,
    adopted: Int = 3,
    vesselAt location: String = "TAU-2",
    updatedAt: Date = fixtureNow,
    arrivals: [Date?] = []
) -> [Device] {
    var fleet = [
        device("VES1", type: "transport_hauler", location: location, updatedAt: updatedAt),
        device("AMI1", type: "ami_survey_controller", location: location,
               stowedIn: "VES1", directives: ["survey_system"], updatedAt: updatedAt),
    ]
    for index in 0..<adopted {
        let home = index < aboard
        fleet.append(device(
            "DRONE\(index)", type: "survey_drone",
            location: home ? location : "TAU-\(index + 3)",
            stowedIn: home ? "VES1" : nil, controlledBy: "AMI1",
            updatedAt: updatedAt,
            arrivesAt: home ? nil : (arrivals.indices.contains(index) ? arrivals[index] : nil)
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
    dispatchedOperations: [String: GameModels.Operation] = [:],
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
        openOperations: openOps, log: log,
        dispatchedOperations: dispatchedOperations, systems: systems, now: now
    )
}

private func run(
    step: String = SurveyRun.Step.preflight,
    targets: [String] = ["TAU"],
    targetIndex: Int = 0,
    controllerCode: String? = nil,
    returnToOrigin: Bool = false,
    roamCentre: String? = nil,
    origin: String? = "SOL",
    stepStartedAt: Date = Date(timeIntervalSince1970: 900)
) -> Directive {
    Directive(
        id: "D1", kind: .surveyRun, status: .running, deviceCode: "VES1",
        controllerCode: controllerCode, roamCentre: roamCentre,
        targets: targets, targetIndex: targetIndex,
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
    case let .stall(reason, _): return reason
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

    /// A POSITIVE staging finding is only as trustworthy as the rows under it.
    ///
    /// The bug this pins: at 21:09:43 on 2026-07-26 preflight read six drones
    /// as stowed aboard and departed for WATTL. They had been sitting in
    /// POLARISUM for four and a half hours — survey drones emit no events, so
    /// nothing had corrected their stow columns, and the `.refreshDevices` net
    /// guarded only the *negative* branch. A stale "still aboard" sailed
    /// straight through unverified.
    ///
    /// The request must name the DRONES too, not just the vessel and controller.
    /// The engine expands a named device via that carrier's `stowed_devices`
    /// blob, and a real vessel's blob listed only an unrelated replicant matrix
    /// — so a request naming the vessel alone never refreshed the drone rows the
    /// check judges, the check stayed unsatisfied, and the run stalled
    /// `unreachableDevice` for five and a half hours. A freshness check must
    /// always ask for exactly the rows it covers.
    @Test func staleStagingRowsEarnAReadBeforeTheyAreBelieved() {
        let stale = fixtureNow.addingTimeInterval(-SurveyRun.stagingFreshness - 1)
        #expect(SurveyRun().nextAction(
            directive: run(), world: world(stagedFleet(updatedAt: stale))
        ) == .refreshDevices(deviceCodes: ["VES1", "AMI1", "DRONE1"],
                             thenStall: .unreachableDevice))
    }

    /// Freshly synced rows are believed as they always were — the demand is
    /// paid once per target at most, not on every evaluation.
    @Test func freshStagingRowsAreTrustedWithoutARead() {
        #expect(SurveyRun().nextAction(directive: run(), world: world(stagedFleet()))
                == .assignController(deviceCode: "AMI1", nextStep: SurveyRun.Step.travelling))
    }

    /// A target that is being SKIPPED never departs, so its staging doesn't
    /// matter and must not cost a read round.
    @Test func aSkippedTargetDoesNotPayForFreshness() {
        let stale = fixtureNow.addingTimeInterval(-SurveyRun.stagingFreshness - 1)
        let scanned = StarSystem(
            designation: "TAU", planetsScanned: 4, planetsTotal: 4,
            moonsScanned: 7, moonsTotal: 7
        )
        #expect(SurveyRun().nextAction(
            directive: run(),
            world: world(stagedFleet(updatedAt: stale), systems: ["TAU": scanned])
        ) == .advanceTarget)
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
                == .advanceStep(nextStep: SurveyRun.Step.deployingBots))
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

/// The fleet mid-survey: the controller and its drone are OUT working the
/// system, nothing stowed aboard — the shape `awaiting` sees for hours.
private func surveyingFleet(
    vesselAt location: String = "TAU-2", controllerUpdatedAt: Date = fixtureNow
) -> [Device] {
    [
        device("VES1", type: "transport_hauler", location: location),
        device("AMI1", type: "ami_survey_controller", location: "TAU-5",
               directives: ["survey_system"], updatedAt: controllerUpdatedAt),
        device("DRONE1", type: "survey_drone", location: "TAU-4", controlledBy: "AMI1",
               updatedAt: controllerUpdatedAt),
    ]
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

    /// The lost-event backstop: a dropped completion frame is recovered from
    /// the controller's own row — re-stowed aboard the vessel after the launch
    /// means the survey is over, and the counts cross-check in `confirming`.
    @Test func backstopAdvancesOnceTheControllerHasReStowed() {
        let directive = run(step: SurveyRun.Step.awaiting, controllerCode: "AMI1",
                            stepStartedAt: Date(timeIntervalSince1970: 900))
        let late = Date(timeIntervalSince1970: 900 + SurveyRun.backstopInterval + 1)
        #expect(SurveyRun().nextAction(
            directive: directive,
            world: world(stagedFleet(vesselAt: "TAU-2"), now: late)
        ) == .refreshSystem(designation: "TAU", nextStep: SurveyRun.Step.confirming))
    }

    /// Scan counts never end the wait on their own: past the backstop with the
    /// snapshot reading fully scanned but the controller demonstrably still out
    /// surveying, the run keeps waiting on the controller's row.
    @Test func backstopIgnoresScanCountsWhileTheControllerIsStillOut() {
        let directive = run(step: SurveyRun.Step.awaiting, controllerCode: "AMI1",
                            stepStartedAt: Date(timeIntervalSince1970: 900))
        let late = Date(timeIntervalSince1970: 900 + SurveyRun.backstopInterval + 1)
        let scanned = StarSystem(
            designation: "TAU", planetsScanned: 4, planetsTotal: 4,
            moonsScanned: 7, moonsTotal: 7
        )
        #expect(SurveyRun().nextAction(
            directive: directive,
            world: world(surveyingFleet(controllerUpdatedAt: late),
                         systems: ["TAU": scanned], now: late)
        ) == .wait)
    }

    /// A deployed controller whose row nothing has read in a whole backstop
    /// interval earns one read — its row is the only evidence that can end the
    /// wait, so it must not be judged from a reading that predates the wait.
    @Test func backstopBuysAControllerReadOnceItsRowIsStale() {
        let directive = run(step: SurveyRun.Step.awaiting, controllerCode: "AMI1",
                            stepStartedAt: Date(timeIntervalSince1970: 900))
        let late = Date(timeIntervalSince1970: 900 + SurveyRun.backstopInterval + 1)
        let stale = late.addingTimeInterval(-SurveyRun.backstopInterval - 1)
        #expect(SurveyRun().nextAction(
            directive: directive,
            world: world(surveyingFleet(controllerUpdatedAt: stale), now: late)
        ) == .refreshDevices(deviceCodes: ["AMI1"], thenStall: nil))
    }

    /// The throttle on that read: one controller read per backstop interval — a
    /// survey runs for hours, so a fresher row waits.
    @Test func backstopThrottlesControllerReadsToTheInterval() {
        let directive = run(step: SurveyRun.Step.awaiting, controllerCode: "AMI1",
                            stepStartedAt: Date(timeIntervalSince1970: 900))
        let late = Date(timeIntervalSince1970: 900 + SurveyRun.backstopInterval + 1)
        let recent = late.addingTimeInterval(-SurveyRun.backstopInterval + 1)
        #expect(SurveyRun().nextAction(
            directive: directive,
            world: world(surveyingFleet(controllerUpdatedAt: recent), now: late)
        ) == .wait)
    }

    /// A stowed claim on a row last read BEFORE this step began is pre-launch
    /// state, not evidence the survey ended — it earns a read, never the
    /// re-stowed fast path.
    @Test func backstopDoesNotTrustAPreLaunchStowedRow() {
        let directive = run(step: SurveyRun.Step.awaiting, controllerCode: "AMI1",
                            stepStartedAt: Date(timeIntervalSince1970: 900))
        let late = Date(timeIntervalSince1970: 900 + SurveyRun.backstopInterval + 1)
        let preLaunch = Date(timeIntervalSince1970: 800)
        #expect(SurveyRun().nextAction(
            directive: directive,
            world: world(stagedFleet(vesselAt: "TAU-2", updatedAt: preLaunch), now: late)
        ) == .refreshDevices(deviceCodes: ["AMI1"], thenStall: nil))
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

    /// A BACKSTOP poll that finds the survey unfinished with the controller
    /// still out goes back to waiting — nothing claimed completion, so there is
    /// nothing to disbelieve.
    @Test func backstopDisagreementReturnsToWaiting() {
        let partial = StarSystem(designation: "TAU", planetsScanned: 2, planetsTotal: 4)
        let directive = run(step: SurveyRun.Step.confirming, controllerCode: "AMI1")
        let snapshot = world(surveyingFleet(), systems: ["TAU": partial],
                             now: Date(timeIntervalSince1970: 1_000))
        #expect(SurveyRun().nextAction(directive: directive, world: snapshot)
                == .advanceStep(nextStep: SurveyRun.Step.awaiting))
    }

    /// A controller home with incomplete counts is the same contradiction as a
    /// completion event with incomplete counts — the survey ended early, so the
    /// run stalls rather than waiting on a survey nothing is flying.
    @Test func confirmingStallsWhenTheControllerIsHomeButCountsDisagree() {
        let partial = StarSystem(designation: "TAU", planetsScanned: 2, planetsTotal: 4)
        let directive = run(step: SurveyRun.Step.confirming, controllerCode: "AMI1")
        let snapshot = world(stagedFleet(vesselAt: "TAU-2"), systems: ["TAU": partial],
                             now: Date(timeIntervalSince1970: 1_000))
        #expect(SurveyRun().nextAction(directive: directive, world: snapshot)
                == .stall(.surveyIncomplete))
    }
}

// MARK: - The system scan the counts depend on

/// `planets_scanned`/`planets_total` reach `GET locations/{star}` only once the
/// system itself has been scanned, and the survey drones never scan it — so a
/// completed survey whose counts are ABSENT is a missing system scan, not a
/// half-done survey, and the run buys the scan rather than stalling on it.
@Suite("Survey Run — system scan")
struct SurveyRunSystemScanTests {
    /// The LAONROCK shape: the survey finished, the location payload carries no
    /// counts at all, so the run goes and scans instead of stalling.
    @Test func confirmingScansWhenTheCountsAreAbsent() {
        let unscanned = StarSystem(designation: "TAU")
        let directive = run(step: SurveyRun.Step.confirming, controllerCode: "AMI1")
        let snapshot = world(
            stagedFleet(vesselAt: "TAU-2"),
            log: [completionEntry(at: Date(timeIntervalSince1970: 950))],
            systems: ["TAU": unscanned], now: Date(timeIntervalSince1970: 1_000)
        )
        #expect(SurveyRun().nextAction(directive: directive, world: snapshot)
                == .advanceStep(nextStep: SurveyRun.Step.scanning))
    }

    /// A system the catalogue holds nothing at all for is the same question.
    @Test func confirmingScansWhenTheSystemIsUnknown() {
        let directive = run(step: SurveyRun.Step.confirming, controllerCode: "AMI1")
        let snapshot = world(
            stagedFleet(vesselAt: "TAU-2"),
            log: [completionEntry(at: Date(timeIntervalSince1970: 950))],
            now: Date(timeIntervalSince1970: 1_000)
        )
        #expect(SurveyRun().nextAction(directive: directive, world: snapshot)
                == .advanceStep(nextStep: SurveyRun.Step.scanning))
    }

    /// The scanning step itself asks the engine for the replicant scan.
    @Test func scanningIssuesTheReplicantScan() {
        let directive = run(step: SurveyRun.Step.scanning, controllerCode: "AMI1")
        let snapshot = world(stagedFleet(vesselAt: "TAU-2"),
                             now: Date(timeIntervalSince1970: 1_000))
        #expect(SurveyRun().nextAction(directive: directive, world: snapshot)
                == .scanSystem(designation: "TAU", nextStep: SurveyRun.Step.confirming))
    }

    /// A scan that keeps failing must not buy a POST every tick forever: once the
    /// loop has spent its rounds, the run surfaces the incomplete survey.
    @Test func confirmingStallsOnceTheScanBudgetIsSpent() {
        let unscanned = StarSystem(designation: "TAU")
        let directive = run(step: SurveyRun.Step.confirming, controllerCode: "AMI1")
        var entries = [completionEntry(at: Date(timeIntervalSince1970: 950))]
        for round in 0..<SurveyRun.scanRounds {
            entries.append(scanLoopEntry(SurveyRun.Step.scanning, at: .init(timeIntervalSince1970: 960 + Double(round) * 2)))
            entries.append(scanLoopEntry(SurveyRun.Step.confirming, at: .init(timeIntervalSince1970: 961 + Double(round) * 2)))
        }
        let snapshot = world(
            stagedFleet(vesselAt: "TAU-2"), log: entries,
            systems: ["TAU": unscanned], now: Date(timeIntervalSince1970: 1_000)
        )
        #expect(SurveyRun().nextAction(directive: directive, world: snapshot)
                == .stall(.surveyIncomplete))
    }

    /// Retry writes a `.resolved` entry, which ends the run of the loop the budget
    /// counts — so a human retry buys a fresh scan rather than re-stalling on the
    /// spot, which is what the old `confirming` could never do.
    @Test func retryReArmsTheScan() {
        let unscanned = StarSystem(designation: "TAU")
        let directive = run(step: SurveyRun.Step.confirming, controllerCode: "AMI1")
        var entries = [completionEntry(at: Date(timeIntervalSince1970: 950))]
        for round in 0..<SurveyRun.scanRounds {
            entries.append(scanLoopEntry(SurveyRun.Step.scanning, at: .init(timeIntervalSince1970: 960 + Double(round) * 2)))
            entries.append(scanLoopEntry(SurveyRun.Step.confirming, at: .init(timeIntervalSince1970: 961 + Double(round) * 2)))
        }
        entries.append(DirectiveLogEntry(
            id: "LR", directiveID: "D1", deviceCode: nil, kind: .resolved,
            summary: "Retried confirming", step: SurveyRun.Step.confirming,
            operationID: nil, eventID: nil, occurredAt: Date(timeIntervalSince1970: 990)
        ))
        let snapshot = world(
            stagedFleet(vesselAt: "TAU-2"), log: entries,
            systems: ["TAU": unscanned], now: Date(timeIntervalSince1970: 1_000)
        )
        #expect(SurveyRun().nextAction(directive: directive, world: snapshot)
                == .advanceStep(nextStep: SurveyRun.Step.scanning))
    }

    /// A system that HAS been scanned and is genuinely half-surveyed keeps the old
    /// behaviour: counts that exist and disagree are a real contradiction, and no
    /// amount of re-scanning changes them.
    @Test func aScannedButPartialSystemStillStalls() {
        let partial = StarSystem(
            designation: "TAU", systemScanned: true, planetsScanned: 2, planetsTotal: 4)
        let directive = run(step: SurveyRun.Step.confirming, controllerCode: "AMI1")
        let snapshot = world(
            stagedFleet(vesselAt: "TAU-2"),
            log: [completionEntry(at: Date(timeIntervalSince1970: 950))],
            systems: ["TAU": partial], now: Date(timeIntervalSince1970: 1_000)
        )
        #expect(SurveyRun().nextAction(directive: directive, world: snapshot)
                == .stall(.surveyIncomplete))
    }
}

private func scanLoopEntry(_ step: String, at occurredAt: Date) -> DirectiveLogEntry {
    DirectiveLogEntry(
        id: "LS-\(step)-\(occurredAt.timeIntervalSince1970)", directiveID: "D1",
        deviceCode: nil, kind: .stepStarted, summary: "Step: \(step)", step: step,
        operationID: nil, eventID: nil, occurredAt: occurredAt
    )
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
                == .advanceStep(nextStep: SurveyRun.Step.repairing))
    }

    /// The recall has only just been ordered — give it a beat before spending a
    /// read on drones that cannot possibly be home yet.
    @Test func waitsBrieflyBeforeTheFirstProbe() {
        let start = Date(timeIntervalSince1970: 900)
        let directive = run(step: SurveyRun.Step.recovering, controllerCode: "AMI1",
                            stepStartedAt: start)
        let justAfter = start.addingTimeInterval(SurveyRun.recallProbeDelay - 1)
        #expect(SurveyRun().nextAction(
            directive: directive,
            world: world(recallingFleet(aboard: 0, updatedAt: start), now: justAfter)
        ) == .wait)
    }

    /// The live ESELLUSAU stall (2026-07-29). A location-scoped probe can never
    /// observe the state this gate waits for, because **stowing a device clears
    /// its location** — so the success condition erases the evidence.
    ///
    /// Verified against the live API while the run sat stuck: all six drones
    /// reported `status: stowed`, `stowed_in_device_code: F2908E6E`,
    /// `location: null`, and `GET devices?location=ESELLUSAU` returned exactly
    /// ONE row — the vessel. The unfiltered fleet list returned all six with
    /// their stow columns intact, which is the proof that scope, not staleness,
    /// was the problem. The drones' rows never moved, so `lastLook` never
    /// advanced and the probe re-fired on every tick until the 20-minute
    /// deadline surfaced `dronesNotRecovered` over a fully recovered fleet.
    ///
    /// So the probe must NAME the drones whose rows decide the gate.
    /// `resolveRefresh` reads each named code directly (`GET devices/{code}`),
    /// which reports a stowed drone wherever it is; the carrier expansion is an
    /// addition to that, not the mechanism — which is what the old "a named
    /// probe could miss the rows it judges" reasoning conflated. Preflight's
    /// staging check already names its drones for exactly this reason.
    @Test func probeNamesTheStrandedDronesRatherThanTheirSystem() {
        let start = Date(timeIntervalSince1970: 900)
        let directive = run(step: SurveyRun.Step.recovering, controllerCode: "AMI1",
                            stepStartedAt: start)
        let due = start.addingTimeInterval(SurveyRun.recallProbeDelay + 1)
        // Rows last read before the probe interval, so the "don't re-read fresh
        // rows" floor is not what decides this.
        let lastSync = due.addingTimeInterval(-SurveyRun.recallProbeInterval - 1)
        // Only the two still out — a drone already home is not re-read.
        #expect(SurveyRun().nextAction(
            directive: directive,
            world: world(recallingFleet(aboard: 1, updatedAt: lastSync), now: due)
        ) == .refreshDevices(deviceCodes: ["DRONE1", "DRONE2"], thenStall: nil))
    }

    /// A probe that comes back "still flying" must NOT stall — the drones are
    /// doing exactly what was asked of them. Waiting is the correct fallback.
    @Test func aProbeThatFindsThemStillFlyingWaitsRatherThanStalls() {
        let start = Date(timeIntervalSince1970: 900)
        let directive = run(step: SurveyRun.Step.recovering, controllerCode: "AMI1",
                            stepStartedAt: start)
        let due = start.addingTimeInterval(SurveyRun.recallProbeDelay + 1)
        let lastSync = due.addingTimeInterval(-SurveyRun.recallProbeInterval - 1)
        let action = SurveyRun().nextAction(
            directive: directive,
            world: world(recallingFleet(aboard: 0, updatedAt: lastSync), now: due)
        )
        guard case let .refreshDevices(_, thenStall) = action else {
            Issue.record("expected a probe, got \(action)"); return
        }
        #expect(thenStall == nil)
    }

    /// The point of the probe: wait for the FARTHEST traveller's own arrival
    /// time rather than a hardcoded guess. Planets are not equidistant.
    @Test func waitsForTheFarthestTravellersArrival() {
        let now = Date(timeIntervalSince1970: 1_000)
        let directive = run(step: SurveyRun.Step.recovering, controllerCode: "AMI1",
                            stepStartedAt: Date(timeIntervalSince1970: 900))
        let near = now.addingTimeInterval(30)
        let far = now.addingTimeInterval(12 * 60)
        #expect(SurveyRun().nextAction(
            directive: directive,
            world: world(
                recallingFleet(aboard: 0, adopted: 2, updatedAt: now, arrivals: [near, far]),
                now: now
            )
        ) == .wait)
    }

    /// A known ETA still in the future costs nothing to honour — no repeat
    /// probe while the drones are demonstrably still on their way.
    @Test func doesNotReprobeWhileAKnownArrivalIsStillAhead() {
        let now = Date(timeIntervalSince1970: 1_000)
        let directive = run(step: SurveyRun.Step.recovering, controllerCode: "AMI1",
                            stepStartedAt: Date(timeIntervalSince1970: 900))
        let ahead = now.addingTimeInterval(5)
        // Rows are ancient, so only the live ETA can be what suppresses the probe.
        let stale = now.addingTimeInterval(-SurveyRun.recallProbeInterval * 10)
        #expect(SurveyRun().nextAction(
            directive: directive,
            world: world(
                recallingFleet(aboard: 0, adopted: 1, updatedAt: stale, arrivals: [ahead]),
                now: now
            )
        ) == .wait)
    }

    /// Once the farthest arrival has passed, look again — that is when the
    /// answer can actually have changed.
    @Test func reprobesOnceTheFarthestArrivalHasPassed() {
        let now = Date(timeIntervalSince1970: 1_000)
        let directive = run(step: SurveyRun.Step.recovering, controllerCode: "AMI1",
                            stepStartedAt: Date(timeIntervalSince1970: 900))
        let passed = now.addingTimeInterval(-1)
        let stale = now.addingTimeInterval(-SurveyRun.recallProbeInterval - 1)
        #expect(SurveyRun().nextAction(
            directive: directive,
            world: world(
                recallingFleet(aboard: 0, adopted: 1, updatedAt: stale, arrivals: [passed]),
                now: now
            )
        ) == .refreshDevices(deviceCodes: ["DRONE0"], thenStall: nil))
    }

    /// A drone that arrived but has not stowed reports no ETA at all. Without a
    /// floor that would re-probe on every 5s tick; the rows' own `updatedAt` is
    /// the "when did we last look" clock that prevents it.
    @Test func doesNotProbeMoreOftenThanTheProbeInterval() {
        let now = Date(timeIntervalSince1970: 1_000)
        let directive = run(step: SurveyRun.Step.recovering, controllerCode: "AMI1",
                            stepStartedAt: Date(timeIntervalSince1970: 900))
        let justLooked = now.addingTimeInterval(-SurveyRun.recallProbeInterval + 1)
        #expect(SurveyRun().nextAction(
            directive: directive,
            world: world(recallingFleet(aboard: 0, adopted: 1, updatedAt: justLooked), now: now)
        ) == .wait)
    }

    /// A recall that never completes must still surface. The cap is measured
    /// from the step's start, which `.wait` and a probe both leave untouched.
    @Test func stallsOnceTheRecallDeadlinePasses() {
        let start = Date(timeIntervalSince1970: 900)
        let directive = run(step: SurveyRun.Step.recovering, controllerCode: "AMI1",
                            stepStartedAt: start)
        let tooLate = start.addingTimeInterval(SurveyRun.recallDeadline + 1)
        #expect(SurveyRun().nextAction(
            directive: directive,
            world: world(recallingFleet(aboard: 0, updatedAt: start), now: tooLate)
        ) == .stall(.dronesNotRecovered))
    }

    /// A PARTIAL recall is not a recall — leaving one drone behind is the whole
    /// failure this step exists to prevent.
    @Test func doesNotAdvanceWhenOnlySomeDronesAreAboard() {
        let now = Date(timeIntervalSince1970: 1_000)
        let directive = run(step: SurveyRun.Step.recovering, controllerCode: "AMI1",
                            stepStartedAt: Date(timeIntervalSince1970: 900))
        let ahead = now.addingTimeInterval(60)
        let action = SurveyRun().nextAction(
            directive: directive,
            world: world(
                recallingFleet(aboard: 2, adopted: 3, updatedAt: now, arrivals: [nil, nil, ahead]),
                now: now
            )
        )
        #expect(action != .advanceTarget)
    }

    /// A controller that adopted nothing has nothing to wait for — don't hold a
    /// run for a recall that will never report.
    @Test func advancesImmediatelyWhenNothingWasAdopted() {
        let directive = run(step: SurveyRun.Step.recovering, controllerCode: "AMI1")
        #expect(SurveyRun().nextAction(directive: directive,
                                       world: world(recallingFleet(aboard: 0, adopted: 0)))
                == .advanceStep(nextStep: SurveyRun.Step.repairing))
    }

    /// A drone adopted by a DIFFERENT controller is not this run's to wait for.
    @Test func ignoresDronesAdoptedElsewhere() {
        var fleet = recallingFleet(aboard: 0, adopted: 0)
        fleet.append(device("OTHER", type: "survey_drone", location: "TAU-9", controlledBy: "AMI9"))
        let directive = run(step: SurveyRun.Step.recovering, controllerCode: "AMI1")
        #expect(SurveyRun().nextAction(directive: directive, world: world(fleet))
                == .advanceStep(nextStep: SurveyRun.Step.repairing))
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

// MARK: - Continuous roam

/// Preflight's roam branch. The engine-side resolution of `.extendQueue` — the
/// census read, the append, and the re-ask — lives in `DirectiveEngineRoamTests`;
/// these tests only pin what the pure machine decides.
@Suite("Survey Run — continuous roam")
struct SurveyRunRoamTests {
    /// An exhausted queue is not the end of a continuous run — it is the cue to
    /// extend it.
    @Test func exhaustedQueueExtendsWhenARoamCentreIsSet() {
        let action = SurveyRun().nextAction(
            directive: run(targets: ["TAU"], targetIndex: 1, roamCentre: "ATIANFU"),
            world: world(stagedFleet())
        )
        #expect(action == .extendQueue(centre: "ATIANFU"))
    }

    /// The fixed-queue regression. Without a centre an exhausted queue must
    /// still finish exactly as it does today.
    @Test func exhaustedQueueStillFinishesWithoutARoamCentre() {
        let action = SurveyRun().nextAction(
            directive: run(targets: ["TAU"], targetIndex: 1, roamCentre: nil),
            world: world(stagedFleet())
        )
        #expect(action == .done)
    }

    /// The other fixed-queue regression: the return leg is untouched.
    @Test func exhaustedQueueStillReturnsToOriginWhenAsked() {
        let action = SurveyRun().nextAction(
            directive: run(
                targets: ["TAU"], targetIndex: 1,
                returnToOrigin: true, roamCentre: nil, origin: "SOL"
            ),
            world: world(stagedFleet(vesselAt: "TAU-1"))
        )
        #expect(action == .advanceStep(nextStep: SurveyRun.Step.returning))
    }

    /// The roam branch is checked BEFORE the return leg, so a run carrying both
    /// keeps surveying rather than going home. Nothing sets both today; this
    /// pins the ordering so "roam, then come home" stays expressible later.
    @Test func roamTakesPrecedenceOverTheReturnLeg() {
        let action = SurveyRun().nextAction(
            directive: run(
                targets: ["TAU"], targetIndex: 1,
                returnToOrigin: true, roamCentre: "ATIANFU", origin: "SOL"
            ),
            world: world(stagedFleet(vesselAt: "TAU-1"))
        )
        #expect(action == .extendQueue(centre: "ATIANFU"))
    }

    /// A roam run still skips a target the census already says is done, without
    /// spending a trip on it — the existing preflight guard, unchanged.
    @Test func roamStillSkipsAnAlreadyScannedTarget() {
        let scanned = StarSystem(
            designation: "TAU", planetsScanned: 4, planetsTotal: 4,
            moonsScanned: 7, moonsTotal: 7
        )
        let action = SurveyRun().nextAction(
            directive: run(targets: ["TAU"], targetIndex: 0, roamCentre: "ATIANFU"),
            world: world(stagedFleet(), systems: ["TAU": scanned])
        )
        #expect(action == .advanceTarget)
    }
}

// MARK: - Arrival freshness

/// The tick that decides a travel dispatch, 139 ms after the arrival op closed
/// — inside the window where `device.location` has not been written yet.
private let arrivalClosedAt = fixtureNow.addingTimeInterval(-0.139)

/// A vessel row written before the arrival closed, recent enough that the
/// throttled read has not come due, so the gate answers `.wait`.
private let rowLaggingArrival = arrivalClosedAt.addingTimeInterval(-5)

/// One CLOSED travel op for the vessel, keyed the way `dispatchedOperations`
/// is. Distinct from `world(travelling:)`, which builds the single OPEN op the
/// `openOperation` guard reads — a finished op must never read as in-flight.
private func afterArrival(
    status: OperationStatus = .completed, completedAt: Date = arrivalClosedAt
) -> [String: GameModels.Operation] {
    let op = GameModels.Operation(
        id: "OP-ARRIVED", entityCode: "VES1", kind: OperationKind.travel.rawValue,
        status: status, source: .event,
        startedAt: completedAt.addingTimeInterval(-120), completesAt: nil,
        lastConfirmedAt: completedAt, detail: .object([:])
    )
    return [op.id: op]
}

/// Both of the run's travel dispatch sites against the two-transaction arrival
/// window: `travel.arrived` closes the op first and writes `device.location`
/// second, so a tick in between reads "trip finished, still elsewhere" and
/// re-commands travel at a vessel already parked.
///
/// Every fixture carries the PRIOR state — a closed travel op AND a vessel row
/// older than it. A world with no completed travel takes the cold-run arm.
@Suite("Survey Run — arrival freshness")
struct SurveyRunArrivalFreshnessTests {
    // MARK: Site 1 — travel (destination = the target system)

    @Test func travelWaitsWhenTheVesselRowStillLagsTheArrival() {
        let directive = run(step: SurveyRun.Step.travelling, controllerCode: "AMI1")
        let snapshot = world(stagedFleet(vesselAt: "SOL-3", updatedAt: rowLaggingArrival),
                             dispatchedOperations: afterArrival())
        #expect(SurveyRun().nextAction(directive: directive, world: snapshot) == .wait)
    }

    /// The no-regression half: a row written AT the arrival still departs. If
    /// this fails the gate has become a brake on every legitimate travel.
    @Test func travelStillDispatchesWhenTheRowPostDatesTheArrival() {
        let directive = run(step: SurveyRun.Step.travelling, controllerCode: "AMI1")
        let snapshot = world(stagedFleet(vesselAt: "SOL-3", updatedAt: arrivalClosedAt),
                             dispatchedOperations: afterArrival())
        #expect(SurveyRun().nextAction(directive: directive, world: snapshot)
                == .dispatch(kind: .travel, deviceCode: "VES1",
                             params: CommandParams(destination: "TAU"),
                             nextStep: SurveyRun.Step.travelling))
    }

    /// Where the gate may sit, not just whether it fires. Every other stale
    /// fixture here has `location != destination` and so passes equally against
    /// a gate hoisted above the equality check; this one is just as stale but
    /// already names the target — the benign direction, which must advance.
    @Test func travelAdvancesOnAStaleRowThatAlreadyNamesTheTarget() {
        let directive = run(step: SurveyRun.Step.travelling, controllerCode: "AMI1")
        let snapshot = world(stagedFleet(vesselAt: "TAU-2", updatedAt: rowLaggingArrival),
                             dispatchedOperations: afterArrival())
        #expect(SurveyRun().nextAction(directive: directive, world: snapshot)
                == .advanceStep(nextStep: SurveyRun.Step.deployingBots))
    }

    // MARK: Site 2 — returnHome (destination = the run's origin)

    @Test func returnWaitsWhenTheVesselRowStillLagsTheArrival() {
        let directive = run(step: SurveyRun.Step.returning, targets: ["TAU"], targetIndex: 1,
                            returnToOrigin: true, origin: "SOL")
        let snapshot = world(stagedFleet(vesselAt: "TAU-2", updatedAt: rowLaggingArrival),
                             dispatchedOperations: afterArrival())
        #expect(SurveyRun().nextAction(directive: directive, world: snapshot) == .wait)
    }

    @Test func returnStillDispatchesWhenTheRowPostDatesTheArrival() {
        let directive = run(step: SurveyRun.Step.returning, targets: ["TAU"], targetIndex: 1,
                            returnToOrigin: true, origin: "SOL")
        let snapshot = world(stagedFleet(vesselAt: "TAU-2", updatedAt: arrivalClosedAt),
                             dispatchedOperations: afterArrival())
        #expect(SurveyRun().nextAction(directive: directive, world: snapshot)
                == .dispatch(kind: .travel, deviceCode: "VES1",
                             params: CommandParams(destination: "SOL"),
                             nextStep: SurveyRun.Step.returning))
    }

    /// Gate placement for site 2: a stale row already home must finish the run,
    /// never wait. Hoisting the gate turns every arrival home into a stall.
    @Test func returnCompletesOnAStaleRowThatAlreadyNamesTheOrigin() {
        let directive = run(step: SurveyRun.Step.returning, targets: ["TAU"], targetIndex: 1,
                            returnToOrigin: true, origin: "SOL")
        let snapshot = world(stagedFleet(vesselAt: "SOL-3", updatedAt: rowLaggingArrival),
                             dispatchedOperations: afterArrival())
        #expect(SurveyRun().nextAction(directive: directive, world: snapshot) == .done)
    }

    // MARK: The cold run

    /// No completed travel means no watermark to post-date, so a first
    /// evaluation departs at once. This is why the watermark is the ARRIVAL and
    /// not `stepStartedAt`, which would delay every first travel by a deadline.
    @Test func dispatchesImmediatelyOnAColdRunWithNoCompletedTravel() {
        let directive = run(step: SurveyRun.Step.travelling, controllerCode: "AMI1")
        let fleet = stagedFleet(vesselAt: "SOL-3", updatedAt: rowLaggingArrival)
        let snapshot = world(fleet)
        #expect(SalvageRun.lastTravelCompletion(for: fleet[0], snapshot) == nil)
        #expect(SurveyRun().nextAction(directive: directive, world: snapshot)
                == .dispatch(kind: .travel, deviceCode: "VES1",
                             params: CommandParams(destination: "TAU"),
                             nextStep: SurveyRun.Step.travelling))
    }

    /// A `.superseded` op stamps `lastConfirmedAt` on a travel that never
    /// arrived, so it must not install itself as the watermark and gate a real
    /// dispatch behind an arrival that did not happen.
    @Test func aSupersededTravelIsNotAnArrival() {
        let directive = run(step: SurveyRun.Step.travelling, controllerCode: "AMI1")
        let snapshot = world(stagedFleet(vesselAt: "SOL-3", updatedAt: rowLaggingArrival),
                             dispatchedOperations: afterArrival(status: .superseded))
        #expect(SurveyRun().nextAction(directive: directive, world: snapshot)
                == .dispatch(kind: .travel, deviceCode: "VES1",
                             params: CommandParams(destination: "TAU"),
                             nextStep: SurveyRun.Step.travelling))
    }

    // MARK: The escalation ladder

    /// The DEADLINE outranks the throttled read. Reversed, a vessel whose reads
    /// never land never reaches its deadline and buys a `.high` read every tick.
    @Test func surfacesVesselPositionUnconfirmedOnceTheArrivalDeadlinePasses() {
        let longAgo = fixtureNow.addingTimeInterval(-SalvageRun.arrivalConfirmDeadline)
        let directive = run(step: SurveyRun.Step.travelling, controllerCode: "AMI1")
        let snapshot = world(
            stagedFleet(vesselAt: "SOL-3", updatedAt: longAgo.addingTimeInterval(-5)),
            dispatchedOperations: afterArrival(completedAt: longAgo)
        )
        #expect(SurveyRun().nextAction(directive: directive, world: snapshot)
                == .refreshDevices(deviceCodes: ["VES1"], thenStall: .vesselPositionUnconfirmed))
    }

    /// Past the read throttle but inside the deadline: buy one read, carrying no
    /// stall reason so an unresolved probe waits rather than halting the run.
    @Test func buysOneThrottledReadOnceTheRowIsOldEnough() {
        let directive = run(step: SurveyRun.Step.travelling, controllerCode: "AMI1")
        let stale = arrivalClosedAt.addingTimeInterval(-SalvageRun.arrivalReadInterval - 1)
        let snapshot = world(stagedFleet(vesselAt: "SOL-3", updatedAt: stale),
                             dispatchedOperations: afterArrival())
        #expect(SurveyRun().nextAction(directive: directive, world: snapshot)
                == .refreshDevices(deviceCodes: ["VES1"], thenStall: nil))
    }
}
