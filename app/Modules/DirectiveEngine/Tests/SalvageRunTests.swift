//
//  SalvageRunTests.swift
//  Replicould — DirectiveEngine
//
//  The Salvage Run step machine as a pure function table, following the same
//  pattern as `SurveyRunTests`. This task pins the skeleton, the fleet
//  queries, and the first two steps — preflight and travel. The remaining
//  steps (emplacing onward) land in a later task.
//
//  The run does NOT stow or adopt anything, same contract as Survey Run:
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
private let fixtureNow = Date(timeIntervalSince1970: 1_000)

private func device(
    _ code: String,
    type: String = "generic_device",
    location: String? = nil,
    stowedIn: String? = nil,
    controlledBy: String? = nil,
    controlled: [String] = [],
    directives: [String] = [],
    features: [String] = [],
    status: String = "idle",
    updatedAt: Date = fixtureNow
) -> Device {
    var detail: [String: JSONValue] = [:]
    if !controlled.isEmpty {
        detail["controlled_devices"] = .array(controlled.map { drone in
            .object(["device_code": .string(drone), "device_type": .string("mining_drone")])
        })
    }
    if !directives.isEmpty {
        detail["available_directives"] = .array(directives.map(JSONValue.string))
    }
    return Device(
        deviceCode: code, deviceType: type, replicantCode: "R1",
        status: status, location: location, locationName: nil,
        operationalCapacity: 100, queueSize: 0,
        stowedInDeviceCode: stowedIn, controllerDeviceCode: controlledBy,
        attachedToDeviceCode: nil, createdAt: Date(timeIntervalSince1970: 0),
        availableCommands: [], features: features, tags: [], detail: .object(detail),
        updatedAt: updatedAt, firstSeenAt: Date(timeIntervalSince1970: 0)
    )
}

/// The vessel, not stowed anywhere and not yet at any target.
private let vessel = device("VESSEL", type: "heaven_vessel")

/// The AMI mining controller, staged the way the run REQUIRES: stowed aboard
/// the vessel, one drone adopted, and offering `gather_salvage` — the
/// capability `SalvageRun.controller(aboard:in:)` matches on, never
/// `device_type`.
private let controller = device(
    "CTRL", type: "ami_mining_controller", stowedIn: "VESSEL",
    controlled: ["DRONE"], directives: ["gather_salvage"]
)

/// The controller's one adopted drone, stowed aboard the same vessel.
private let drone = device("DRONE", type: "mining_drone", stowedIn: "VESSEL", controlledBy: "CTRL")

/// An FTL relay stowed aboard the vessel, idle (not yet planted anywhere).
private let relay = device("RELAY", type: "ftl_relay", stowedIn: "VESSEL", features: ["relay"])

private func operation(kind: OperationKind) -> GameModels.Operation {
    GameModels.Operation(
        id: "OP1", entityCode: "VESSEL", kind: kind.rawValue,
        status: .active, source: .optimistic,
        startedAt: Date(timeIntervalSince1970: 0), completesAt: nil,
        lastConfirmedAt: Date(timeIntervalSince1970: 0), detail: .object([:])
    )
}

private func world(
    devices: [Device],
    openOperations: [String: GameModels.Operation] = [:],
    log: [DirectiveLogEntry] = [],
    systems: [String: StarSystem] = [:],
    now: Date = fixtureNow
) -> WorldSnapshot {
    WorldSnapshot(
        devices: Dictionary(devices.map { ($0.deviceCode, $0) }, uniquingKeysWith: { _, last in last }),
        openOperations: openOperations, log: log, systems: systems, now: now
    )
}

private func running(
    step: String = SalvageRun.Step.preflight,
    targets: [String] = ["TOSLIT"],
    targetIndex: Int = 0,
    controllerCode: String? = nil,
    fleetTag: String? = nil,
    roamCentre: String? = "AINALRAM",
    stepStartedAt: Date = Date(timeIntervalSince1970: 900)
) -> Directive {
    Directive(
        id: "D1", kind: .salvageRun, status: .running, deviceCode: "VESSEL",
        controllerCode: controllerCode, roamCentre: roamCentre, fleetTag: fleetTag,
        targets: targets, targetIndex: targetIndex,
        step: step, stepStartedAt: stepStartedAt, returnToOrigin: false,
        originDesignation: nil, attentionReason: nil,
        createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0)
    )
}

// MARK: - Preflight

@Suite("Salvage Run — preflight")
struct SalvageRunPreflightTests {
    /// No controller stowed aboard: staging one is the player's job. The
    /// negative finding is over local rows, so it demands an authoritative tag
    /// read before surfacing it — "nothing aboard" and "nobody has looked
    /// lately" read as the same silence locally, and only the first is worth
    /// stopping a run for.
    @Test func stallsWhenNoMiningControllerIsAboard() {
        let snapshot = world(devices: [vessel])
        #expect(SalvageRun().nextAction(directive: running(step: "preflight"), world: snapshot)
                == .refreshFleet(tag: "auto:salvage", thenStall: .noMiningControllerAboard))
    }

    /// The controller is aboard, but nothing it has adopted is with it.
    @Test func stallsWhenTheControllerHasNoDroneAboard() {
        let snapshot = world(devices: [vessel, controller])
        #expect(SalvageRun().nextAction(directive: running(step: "preflight"), world: snapshot)
                == .refreshFleet(tag: "auto:salvage", thenStall: .noMiningDroneAboard))
    }

    /// A fully staged vessel claims its controller and moves to travel.
    @Test func claimsTheControllerAndTravelsWhenFullyStaged() {
        let snapshot = world(devices: [vessel, controller, drone, relay])
        #expect(SalvageRun().nextAction(directive: running(step: "preflight"), world: snapshot)
                == .assignController(deviceCode: "CTRL", nextStep: "travelling"))
    }

    /// The relay is an ENABLER, not an optional extra: without one the run
    /// would have to park at the target for the whole haul, which is exactly
    /// what the two-machine split exists to avoid. Out of relays and the
    /// target needs one, so the vessel routes to base rather than departing.
    @Test func routesToBaseWhenOutOfRelaysAndTheTargetNeedsOne() {
        let snapshot = world(devices: [vessel, controller, drone]) // no relay aboard
        #expect(SalvageRun().nextAction(directive: running(step: "preflight"), world: snapshot)
                == .advanceStep(nextStep: "restocking"))
    }

    /// A Salvage Run is always continuous — it has no finish line, so an
    /// empty queue means "plan the next one", never `.done`.
    @Test func extendsTheQueueWhenItEmpties() {
        let snapshot = world(devices: [vessel, controller, drone, relay])
        let directive = running(step: "preflight", targets: ["TOSLIT"], targetIndex: 1)
        #expect(SalvageRun().nextAction(directive: directive, world: snapshot)
                == .extendQueue(centre: "AINALRAM"))
    }

    /// An exhausted queue extends BEFORE the staging guards run — a fresh row
    /// with nothing staged yet must not stall on staging it hasn't reached.
    @Test func extendsTheQueueBeforeCheckingStaging() {
        let snapshot = world(devices: [vessel]) // nothing staged at all
        let directive = running(step: "preflight", targets: ["TOSLIT"], targetIndex: 1)
        #expect(SalvageRun().nextAction(directive: directive, world: snapshot)
                == .extendQueue(centre: "AINALRAM"))
    }

    /// A missing `roamCentre` must not crash, and a continuous run must not
    /// silently finish either — it falls back to the vessel's own system.
    @Test func fallsBackToTheVesselsSystemWhenRoamCentreIsMissing() {
        let here = device("VESSEL", type: "heaven_vessel", location: "TOSLIT-3")
        let snapshot = world(devices: [here, controller, drone, relay])
        let directive = running(step: "preflight", targets: ["TOSLIT"], targetIndex: 1, roamCentre: nil)
        #expect(SalvageRun().nextAction(directive: directive, world: snapshot)
                == .extendQueue(centre: "TOSLIT"))
    }

    /// The vessel isn't in the fleet at all (decommissioned, or never read).
    @Test func stallsWhenTheVesselIsMissingEntirely() {
        #expect(SalvageRun().nextAction(directive: running(step: "preflight"), world: world(devices: []))
                == .stall(.unreachableDevice))
    }

    /// A row written without its own `fleetTag` still resolves against the
    /// default tag rather than failing to name one at all.
    @Test func usesTheDefaultFleetTagWhenTheRowCarriesNone() {
        let snapshot = world(devices: [vessel])
        let directive = running(step: "preflight", fleetTag: nil)
        #expect(SalvageRun().nextAction(directive: directive, world: snapshot)
                == .refreshFleet(tag: "auto:salvage", thenStall: .noMiningControllerAboard))
    }

    /// A row carrying its own `fleetTag` uses that instead of the default.
    @Test func usesTheRowsOwnFleetTagWhenItHasOne() {
        let snapshot = world(devices: [vessel])
        let directive = running(step: "preflight", fleetTag: "auto:salvage-2")
        #expect(SalvageRun().nextAction(directive: directive, world: snapshot)
                == .refreshFleet(tag: "auto:salvage-2", thenStall: .noMiningControllerAboard))
    }
}

// MARK: - Travel

@Suite("Salvage Run — travel")
struct SalvageRunTravelTests {
    /// Travel is dispatched at the vessel, toward the target system.
    @Test func dispatchesTravelToTheTarget() {
        let snapshot = world(devices: [vessel, controller, drone, relay])
        #expect(SalvageRun().nextAction(directive: running(step: "travelling"), world: snapshot)
                == .dispatch(kind: .travel, deviceCode: "VESSEL",
                             params: CommandParams(destination: "TOSLIT"), nextStep: "travelling"))
    }

    /// Mid-travel is a wait, never a stall — and never a second travel command
    /// stacked on the one already in flight. An open op is the guard.
    @Test func waitsWhileTheTripIsUnderway() {
        let snapshot = world(devices: [vessel, controller, drone, relay],
                              openOperations: ["VESSEL": operation(kind: .travel)])
        #expect(SalvageRun().nextAction(directive: running(step: "travelling"), world: snapshot) == .wait)
    }

    /// Arrived, and a relay is already relaying here — nothing to emplace, so
    /// the run skips straight past that step.
    @Test func skipsStraightToMiningWhenTheSystemIsAlreadyMeshed() {
        let arrived = device("VESSEL", type: "heaven_vessel", location: "TOSLIT-3")
        let here = device("R", location: "TOSLIT-3-L4", features: ["relay"], status: "relaying")
        let snapshot = world(devices: [arrived, controller, drone, relay, here])
        #expect(SalvageRun().nextAction(directive: running(step: "travelling"), world: snapshot)
                == .advanceStep(nextStep: "configuring"))
    }

    /// Arrived at an unmeshed system: go emplace the relay before mining.
    @Test func goesToEmplaceTheRelayOnArrivalAtAnUnmeshedSystem() {
        let arrived = device("VESSEL", type: "heaven_vessel", location: "TOSLIT-3")
        let snapshot = world(devices: [arrived, controller, drone, relay])
        #expect(SalvageRun().nextAction(directive: running(step: "travelling"), world: snapshot)
                == .advanceStep(nextStep: "emplacing"))
    }
}

// MARK: - Unrecognised step

@Suite("Salvage Run — unrecognised step")
struct SalvageRunUnknownStepTests {
    /// A step this task hasn't wired up yet (or a genuinely unknown one) must
    /// never dispatch — it waits, same contract as `SurveyRun`.
    @Test func waitsOnAStepNotYetImplemented() {
        let snapshot = world(devices: [vessel, controller, drone, relay])
        #expect(SalvageRun().nextAction(directive: running(step: "emplacing"), world: snapshot) == .wait)
    }
}
