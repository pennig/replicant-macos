//
//  HaulRunTests.swift
//  Replicould — DirectiveEngine
//
//  The Haul Run as a pure function: (directive, world) → one action. No network,
//  no clock — `world.now` is the only time source (design spec §6).
//

import Foundation
import GameModels
import GameServices
import Testing
import UniverseModels
import Utils
@testable import DirectiveEngine

private let fixtureNow = Date(timeIntervalSince1970: 10_000)

private func controller(
    _ code: String,
    tags: [String] = ["auto:haul"],
    directives: [String] = ["delivery", "ferry", "shuttle", "consolidate"],
    currentDirective: String? = nil,
    currentConfig: [String: JSONValue]? = nil,
    updatedAt: Date = fixtureNow
) -> Device {
    var detail: [String: JSONValue] = [
        "available_directives": .array(directives.map(JSONValue.string)),
    ]
    if let currentDirective {
        detail["ami_directive"] = .object([
            "name": .string(currentDirective),
            "config": .object(currentConfig ?? [:]),
        ])
    }
    return Device(
        deviceCode: code, deviceType: "ami_transport_controller", replicantCode: "R1",
        status: "coordinating", location: "ATIANFU-1-L4", locationName: nil,
        operationalCapacity: 100, queueSize: 0,
        stowedInDeviceCode: nil, controllerDeviceCode: nil, attachedToDeviceCode: nil,
        createdAt: Date(timeIntervalSince1970: 0), availableCommands: [],
        features: ["ami"], tags: tags, detail: .object(detail),
        updatedAt: updatedAt, firstSeenAt: Date(timeIntervalSince1970: 0)
    )
}

private func relay(at location: String) -> Device {
    Device(
        deviceCode: "RLY-\(location)", deviceType: "ftl_relay", replicantCode: "R1",
        status: "relaying", location: location, locationName: nil,
        operationalCapacity: 100, queueSize: 0,
        stowedInDeviceCode: nil, controllerDeviceCode: nil, attachedToDeviceCode: nil,
        createdAt: Date(timeIntervalSince1970: 0), availableCommands: [],
        features: ["relay"], tags: [], detail: .object([:]),
        updatedAt: fixtureNow, firstSeenAt: Date(timeIntervalSince1970: 0)
    )
}

private func footprint(_ location: String, _ resources: Int, at fetchedAt: Date = fixtureNow) -> LocationFootprint {
    LocationFootprint(
        location: location, devices: 0, resources: resources, resourceSites: 0,
        locationEvents: 0, replicants: 0, fetchedAt: fetchedAt
    )
}

private func world(
    devices: [Device],
    footprints: [LocationFootprint] = [],
    now: Date = fixtureNow
) -> WorldSnapshot {
    WorldSnapshot(
        devices: Dictionary(devices.map { ($0.deviceCode, $0) }, uniquingKeysWith: { _, last in last }),
        openOperations: [:],
        footprints: Dictionary(footprints.map { ($0.location, $0) }, uniquingKeysWith: { _, last in last }),
        now: now
    )
}

private func run(
    step: String,
    stepStartedAt: Date = fixtureNow,
    fleetTag: String? = HaulRun.defaultFleetTag
) -> Directive {
    Directive(
        id: "D1", kind: .haulRun, status: .running, deviceCode: "C1",
        fleetTag: fleetTag, targets: [], targetIndex: 0, step: step,
        stepStartedAt: stepStartedAt, returnToOrigin: false,
        originDesignation: nil, attentionReason: nil,
        createdAt: fixtureNow, updatedAt: fixtureNow
    )
}

private let meshed = [relay(at: "AINALRAM-1-L4"), relay(at: "ATIANFU-1-L4")]

@Suite("Haul Run")
struct HaulRunTests {

    // MARK: preflight

    /// A fleet nobody has read recently is re-read authoritatively before the run
    /// believes it — the tag endpoint is the only scope that sees every member.
    @Test func preflightRefreshesAStaleFleet() {
        let stale = controller("C1", updatedAt: fixtureNow.addingTimeInterval(-3_600))
        let action = HaulRun().nextAction(
            directive: run(step: HaulRun.Step.preflight),
            world: world(devices: [stale] + meshed)
        )
        #expect(action == .refreshFleet(tag: "auto:haul", thenStall: .noHaulControllerTagged))
    }

    /// A fresh, tagged controller needs no read at all.
    @Test func preflightAdvancesOnAFreshTaggedFleet() {
        let action = HaulRun().nextAction(
            directive: run(step: HaulRun.Step.preflight),
            world: world(devices: [controller("C1")] + meshed)
        )
        #expect(action == .advanceStep(nextStep: HaulRun.Step.surveying))
    }

    /// An untagged controller is invisible to the run — the tag IS the opt-in.
    @Test func anUntaggedControllerIsNotPartOfTheFleet() {
        let action = HaulRun().nextAction(
            directive: run(step: HaulRun.Step.preflight),
            world: world(devices: [controller("C1", tags: [])] + meshed)
        )
        #expect(action == .refreshFleet(tag: "auto:haul", thenStall: .noHaulControllerTagged))
    }

    /// Capability, not device type: a controller is one because it offers
    /// `ferry`, so a differently-named device with the same capability works.
    @Test func aTaggedDeviceWithoutFerryIsNotAHaulController() {
        let notAController = controller("C1", directives: ["survey_system"])
        #expect(HaulRun.controllers(in: world(devices: [notAController]), tag: "auto:haul").isEmpty)
    }

    // MARK: surveying

    /// A stale census is re-read — one request covering discovery and drain
    /// detection at once.
    @Test func surveyingRefreshesAStaleCensus() {
        let old = footprint("ATIANFU-BELT-1", 3_537, at: fixtureNow.addingTimeInterval(-3_600))
        let action = HaulRun().nextAction(
            directive: run(step: HaulRun.Step.surveying),
            world: world(devices: [controller("C1")] + meshed, footprints: [old])
        )
        #expect(action == .refreshFootprint(nextStep: HaulRun.Step.assigning))
    }

    /// A census read moments ago is not read again — the 5s tick must not
    /// multiply into requests.
    @Test func surveyingSkipsARecentCensus() {
        let action = HaulRun().nextAction(
            directive: run(step: HaulRun.Step.surveying),
            world: world(
                devices: [controller("C1")] + meshed,
                footprints: [footprint("ATIANFU-BELT-1", 3_537)]
            )
        )
        #expect(action == .advanceStep(nextStep: HaulRun.Step.assigning))
    }

    // MARK: assigning

    /// The headline: point the controller at the richest reachable pile.
    @Test func assigningDispatchesSetDirective() {
        let action = HaulRun().nextAction(
            directive: run(step: HaulRun.Step.assigning),
            world: world(
                devices: [controller("C1")] + meshed,
                footprints: [footprint("ATIANFU-BELT-1", 3_537)]
            )
        )
        #expect(action == .dispatch(
            kind: .setDirective,
            deviceCode: "C1",
            params: CommandParams(directive: "ferry", configuration: [
                "collect": .string("ATIANFU-BELT-1"),
                "deliver": .string(HaulRun.deliveryLocation),
            ]),
            nextStep: HaulRun.Step.confirming
        ))
    }

    /// The guard that makes the dispatch terminate: a controller already running
    /// the intended config is left alone. Without this the run would re-issue the
    /// same command on every cycle forever.
    @Test func assigningSkipsAControllerAlreadyPointedCorrectly() {
        let settled = controller(
            "C1", currentDirective: "ferry",
            currentConfig: [
                "collect": .string("ATIANFU-BELT-1"),
                "deliver": .string(HaulRun.deliveryLocation),
            ]
        )
        let action = HaulRun().nextAction(
            directive: run(step: HaulRun.Step.assigning),
            world: world(devices: [settled] + meshed, footprints: [footprint("ATIANFU-BELT-1", 3_537)])
        )
        #expect(action == .advanceStep(nextStep: HaulRun.Step.hauling))
    }

    /// A controller pointed at a DIFFERENT pile is repointed — this is what
    /// happens the moment a pile drains.
    @Test func assigningRepointsAControllerOnADrainedPile() {
        let onOldPile = controller(
            "C1", currentDirective: "ferry",
            currentConfig: [
                "collect": .string("SHERATANON-6-1"),
                "deliver": .string(HaulRun.deliveryLocation),
            ]
        )
        let action = HaulRun().nextAction(
            directive: run(step: HaulRun.Step.assigning),
            world: world(
                devices: [onOldPile] + meshed,
                footprints: [footprint("SHERATANON-6-1", 0), footprint("ATIANFU-BELT-1", 3_537)]
            )
        )
        #expect(action == .dispatch(
            kind: .setDirective,
            deviceCode: "C1",
            params: CommandParams(directive: "ferry", configuration: [
                "collect": .string("ATIANFU-BELT-1"),
                "deliver": .string(HaulRun.deliveryLocation),
            ]),
            nextStep: HaulRun.Step.confirming
        ))
    }

    /// Nothing reachable is a LULL, not an ending. The run must never complete —
    /// the Salvage Run keeps making new piles under it.
    @Test func nothingReachableIdlesRatherThanFinishing() {
        let action = HaulRun().nextAction(
            directive: run(step: HaulRun.Step.assigning),
            world: world(
                devices: [controller("C1")] + meshed,
                footprints: [footprint("TENEGSHE-3", 80)]
            )
        )
        #expect(action == .advanceStep(nextStep: HaulRun.Step.hauling))
        #expect(action != .done)
    }

    /// The fleet vanishing mid-run is a configuration problem, so it stalls.
    @Test func assigningStallsWhenTheFleetIsGone() {
        let action = HaulRun().nextAction(
            directive: run(step: HaulRun.Step.assigning),
            world: world(devices: meshed, footprints: [footprint("ATIANFU-BELT-1", 3_537)])
        )
        #expect(action == .stall(.noHaulControllerTagged))
    }

    // MARK: confirming

    /// While the controller has not taken the config, wait — and crucially do NOT
    /// re-dispatch, which would reset the deadline measuring the wait.
    @Test func confirmingWaitsForTheControllerToTakeTheConfig() {
        let action = HaulRun().nextAction(
            directive: run(step: HaulRun.Step.confirming),
            world: world(devices: [controller("C1")] + meshed, footprints: [footprint("ATIANFU-BELT-1", 3_537)])
        )
        #expect(action == .wait)
    }

    /// Once it has, move on to the next controller.
    @Test func confirmingAdvancesOnceTheConfigIsInForce() {
        let settled = controller(
            "C1", currentDirective: "ferry",
            currentConfig: [
                "collect": .string("ATIANFU-BELT-1"),
                "deliver": .string(HaulRun.deliveryLocation),
            ]
        )
        let action = HaulRun().nextAction(
            directive: run(step: HaulRun.Step.confirming),
            world: world(devices: [settled] + meshed, footprints: [footprint("ATIANFU-BELT-1", 3_537)])
        )
        #expect(action == .advanceStep(nextStep: HaulRun.Step.assigning))
    }

    /// **A `blocked:` eval state is NOT a fault.** The live controller reads
    /// `blocked:[('no_taxi_plate', 1)]` — a real shortage for its cruise-only
    /// haulers — while its surge-capable freighter hauls perfectly well. Reading
    /// that as a failure would halt a healthy run, so the config comparison must
    /// ignore `_eval_state` entirely.
    @Test func aBlockedEvalStateStillCountsAsInForce() {
        var detail: [String: JSONValue] = [
            "available_directives": .array(
                ["delivery", "ferry", "shuttle", "consolidate"].map(JSONValue.string)
            ),
        ]
        detail["ami_directive"] = .object([
            "name": .string("ferry"),
            "_eval_state": .string("blocked:[('no_taxi_plate', 1)]"),
            "config": .object([
                "collect": .string("ATIANFU-BELT-1"),
                "deliver": .string(HaulRun.deliveryLocation),
            ]),
        ])
        let blocked = Device(
            deviceCode: "C1", deviceType: "ami_transport_controller", replicantCode: "R1",
            status: "coordinating", location: "ATIANFU-1-L4", locationName: nil,
            operationalCapacity: 100, queueSize: 0,
            stowedInDeviceCode: nil, controllerDeviceCode: nil, attachedToDeviceCode: nil,
            createdAt: Date(timeIntervalSince1970: 0), availableCommands: [],
            features: ["ami"], tags: ["auto:haul"], detail: .object(detail),
            updatedAt: fixtureNow, firstSeenAt: Date(timeIntervalSince1970: 0)
        )
        let action = HaulRun().nextAction(
            directive: run(step: HaulRun.Step.assigning),
            world: world(devices: [blocked] + meshed, footprints: [footprint("ATIANFU-BELT-1", 3_537)])
        )
        // Already pointed correctly — no re-dispatch, blocked state or not.
        #expect(action == .advanceStep(nextStep: HaulRun.Step.hauling))
    }

    /// A controller that never takes the config gets ONE authoritative re-read
    /// before the run gives up — the local row may simply be stale.
    @Test func confirmingReReadsThenStallsPastTheDeadline() {
        let action = HaulRun().nextAction(
            directive: run(
                step: HaulRun.Step.confirming,
                stepStartedAt: fixtureNow.addingTimeInterval(-HaulRun.confirmDeadline - 1)
            ),
            world: world(devices: [controller("C1")] + meshed, footprints: [footprint("ATIANFU-BELT-1", 3_537)])
        )
        #expect(action == .refreshDevices(deviceCodes: ["C1"], thenStall: .commandRejected))
    }

    // MARK: hauling

    /// The poll interval is measured here because `.wait` is the only action that
    /// does not re-stamp `stepStartedAt`.
    @Test func haulingWaitsOutThePollInterval() {
        let action = HaulRun().nextAction(
            directive: run(step: HaulRun.Step.hauling),
            world: world(devices: [controller("C1")] + meshed)
        )
        #expect(action == .wait)
    }

    @Test func haulingRechecksAfterThePollInterval() {
        let action = HaulRun().nextAction(
            directive: run(
                step: HaulRun.Step.hauling,
                stepStartedAt: fixtureNow.addingTimeInterval(-HaulRun.pollInterval - 1)
            ),
            world: world(devices: [controller("C1")] + meshed)
        )
        #expect(action == .advanceStep(nextStep: HaulRun.Step.surveying))
    }

    // MARK: contracts

    /// A Haul Run never uses `.extendQueue`, so its planner hook must answer
    /// idle — answering `.exhausted` would finish a run that has no finish line.
    @Test func theRoamHookIdlesBecauseTheRunNeverExtendsAQueue() {
        let plan = HaulRun().plan(
            RoamContext(centre: nil, vessel: nil, stars: [], assays: [], devices: [], attempted: [])
        )
        #expect(plan == .idle)
    }

    /// An unknown step must never dispatch — waiting is inert and recoverable.
    @Test func anUnknownStepWaits() {
        let action = HaulRun().nextAction(
            directive: run(step: "nonsense"),
            world: world(devices: [controller("C1")] + meshed)
        )
        #expect(action == .wait)
    }

    /// The registry is what makes the engine actually run this machine. A machine
    /// nobody registers is dead code that every unit test above still passes.
    @Test func theMachineIsRegistered() {
        let machine = MissionRegistry.machine(for: .haulRun)
        #expect(machine != nil)
        #expect(machine?.firstStep == HaulRun.Step.preflight)
    }
}
