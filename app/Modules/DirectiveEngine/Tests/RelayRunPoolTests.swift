//
//  RelayRunPoolTests.swift
//  Replicould — DirectiveEngine
//
//  The hub relay POOL: a Relay Run takes an idle relay standing at the print
//  hub instead of printing a new one, and concurrent runs take disjoint relays
//  in the order they were created.
//
//  Every case here is drawn from one live incident (2026-08-04). Three Relay
//  Runs launched at `AINALRAM-BELT-1` within seven minutes because three
//  untagged HEAVEN vessels stood there. They all dispatched a print at the one
//  shared autofactory; `CommandClient` supersedes any other open op on a device,
//  so the two OLDEST lost their operation rows and the YOUNGEST was the only one
//  that could ever resolve a clone. It delivered; the other two stalled
//  `noRelayCoLocated` — standing beside three idle relays they were not allowed
//  to look at, because print completion was detected strictly by operation
//  result.
//
//  So the three properties under test are: take what is already there, survive
//  a superseded print, and hand out disjoint relays oldest-first.
//

import Foundation
import GameModels
import GameServices
import Testing
import UniverseModels
import Utils
@testable import DirectiveEngine

// MARK: - Fixtures

private let now = Date(timeIntervalSince1970: 10_000)
private let hubLocation = "AINALRAM-BELT-1"

private func device(
    _ code: String,
    type: String = "generic_device",
    location: String? = nil,
    stowedIn: String? = nil,
    status: String = "idle",
    features: [String] = [],
    availableCommands: [String] = [],
    tags: [String] = []
) -> Device {
    Device(
        deviceCode: code, deviceType: type, replicantCode: "R1", status: status,
        location: location, locationName: nil, operationalCapacity: 100, queueSize: 0,
        stowedInDeviceCode: stowedIn, controllerDeviceCode: nil, attachedToDeviceCode: nil,
        createdAt: Date(timeIntervalSince1970: 0), availableCommands: availableCommands,
        features: features, tags: tags, detail: .object([:]),
        updatedAt: now, firstSeenAt: Date(timeIntervalSince1970: 0)
    )
}

private func carrier(_ code: String, location: String? = hubLocation) -> Device {
    device(code, type: "heaven_vessel", location: location, tags: [Brain.carrierTag.string])
}

private func hub() -> Device {
    device("AF1", type: "autofactory", location: hubLocation, availableCommands: ["enqueue_print"])
}

/// An idle relay standing at the hub — the thing this whole suite is about.
/// `inactive` is the live status of a printed-but-unplanted relay.
private func spare(_ code: String, location: String? = hubLocation, status: String = "inactive", stowedIn: String? = nil) -> Device {
    device(
        code, type: "ftl_relay", location: location, stowedIn: stowedIn,
        status: status, features: ["cruise", "relay", "stow"]
    )
}

/// A Relay Run waiting for stock. `createdAt` is the FIFO key.
private func run(
    _ id: String,
    carrier code: String,
    createdAt: TimeInterval,
    step: String = RelayRun.Step.acquire.rawValue,
    status: DirectiveStatus = .running
) -> Directive {
    Directive(
        id: id, kind: .relayRun, status: status, deviceCode: code,
        controllerCode: nil, roamCentre: nil, fleetTag: nil,
        sourceRelayCode: nil, targets: ["VEGA"], targetIndex: 0,
        step: step, stepStartedAt: Date(timeIntervalSince1970: 9_900), returnToOrigin: false,
        originDesignation: nil, attentionReason: nil,
        createdAt: Date(timeIntervalSince1970: createdAt), updatedAt: Date(timeIntervalSince1970: createdAt)
    )
}

/// A fresh census showing the hub comfortably above the reserve floor, so the
/// rail never vetoes: these tests are about WHERE a relay comes from, and a run
/// blocked on stock would never reach that decision. The rail's own behaviour is
/// covered in `RelayRunTests`/`BrainCeilingTests`.
private func healthyCensus() -> [String: LocationFootprint] {
    [hubLocation: LocationFootprint(
        location: hubLocation, devices: 1, resources: 1_000_000,
        resourceSites: 0, locationEvents: 0, replicants: 0, fetchedAt: now
    )]
}

private func world(devices: [Device], peers: [Directive] = [], dispatched: [GameModels.Operation] = []) -> WorldSnapshot {
    WorldSnapshot(
        devices: Dictionary(devices.map { ($0.deviceCode, $0) }, uniquingKeysWith: { _, last in last }),
        openOperations: [:], log: [],
        dispatchedOperations: Dictionary(dispatched.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last }),
        systems: [:], siteAssays: [:], footprints: healthyCensus(),
        inventories: railClearingInventory(at: hubLocation, fetchedAt: now),
        peers: peers, now: now
    )
}

/// A print operation this directive dispatched, in whatever state a test needs.
private func printOp(status: OperationStatus, newDeviceCode: String? = nil) -> GameModels.Operation {
    var detail: [String: JSONValue] = ["device_type": .string("ftl_relay")]
    if let newDeviceCode { detail["result"] = .object(["new_device_code": .string(newDeviceCode)]) }
    return GameModels.Operation(
        id: "OP-PRINT", entityCode: "AF1", kind: OperationKind.print.rawValue,
        status: status, source: .event, startedAt: Date(timeIntervalSince1970: 0),
        completesAt: nil, lastConfirmedAt: now, detail: .object(detail)
    )
}

// MARK: - Taking what is already there

@Suite("Relay Run — the hub relay pool")
struct RelayRunPoolTests {
    /// The headline fix: a spare standing at the hub is taken, not re-printed.
    @Test("acquire claims an idle co-located relay instead of printing")
    func claimsIdleRelayInsteadOfPrinting() {
        let directive = run("D1", carrier: "V1", createdAt: 0)
        let snapshot = world(devices: [carrier("V1"), hub(), spare("RLY1")], peers: [directive])

        let action = RelayRun().nextAction(directive: directive, world: snapshot)

        #expect(action == .advanceStep(nextStep: RelayRun.Step.stowing.rawValue))
    }

    /// …and the relay the run then stows is that spare, not something else the
    /// resolution chain might have reached for.
    @Test("the claimed relay is the one stowing issues its command at")
    func claimedRelayIsTheOneStowed() {
        let directive = run("D1", carrier: "V1", createdAt: 0, step: RelayRun.Step.stowing.rawValue)
        let snapshot = world(devices: [carrier("V1"), hub(), spare("RLY1")], peers: [directive])

        let action = RelayRun().nextAction(directive: directive, world: snapshot)

        #expect(action == .dispatch(
            kind: .stow, deviceCode: "RLY1",
            params: CommandParams(target: "V1"), nextStep: RelayRun.Step.confirmingStow.rawValue
        ))
    }

    /// The pool is only what is genuinely free. Each of these is a relay the run
    /// must NOT touch, so with only these present it falls through to printing.
    @Test("a relay that is planted, held, or elsewhere is not in the pool", arguments: [
        ("relaying at the hub", "relaying", hubLocation, String?.none),
        ("idle but already in a hold", "inactive", hubLocation, String?.some("V9")),
        ("idle at another location", "inactive", "SOMEWHERE-ELSE", String?.none),
    ])
    func poolExcludesUnavailableRelays(_ label: String, status: String, location: String, stowedIn: String?) {
        let directive = run("D1", carrier: "V1", createdAt: 0)
        let ineligible = spare("RLY1", location: stowedIn == nil ? location : nil, status: status, stowedIn: stowedIn)
        let snapshot = world(devices: [carrier("V1"), hub(), ineligible], peers: [directive])

        let action = RelayRun().nextAction(directive: directive, world: snapshot)

        #expect(action == .dispatch(
            kind: .print, deviceCode: "AF1",
            params: CommandParams(deviceType: "ftl_relay"), nextStep: RelayRun.Step.printing.rawValue
        ), "\(label) must not be claimable")
    }

    /// With no stock at all the capability still prints — the pool is a saving,
    /// not a replacement for the print path.
    @Test("an empty pool still prints")
    func emptyPoolPrints() {
        let directive = run("D1", carrier: "V1", createdAt: 0)
        let snapshot = world(devices: [carrier("V1"), hub()], peers: [directive])

        let action = RelayRun().nextAction(directive: directive, world: snapshot)

        #expect(action == .dispatch(
            kind: .print, deviceCode: "AF1",
            params: CommandParams(deviceType: "ftl_relay"), nextStep: RelayRun.Step.printing.rawValue
        ))
    }
}

// MARK: - Surviving a superseded print

@Suite("Relay Run — a superseded print no longer strands the run")
struct RelayRunSupersededPrintTests {
    /// THE live defect. The run's own print op was superseded by a sibling's
    /// dispatch at the shared hub, so `printedRelayCode` is nil forever — but a
    /// relay is standing at the hub, and the run may now take it.
    @Test("printing claims from the pool when its own op was superseded")
    func supersededPrintRecoversFromPool() {
        let directive = run("D1", carrier: "V1", createdAt: 0, step: RelayRun.Step.printing.rawValue)
        let snapshot = world(
            devices: [carrier("V1"), hub(), spare("RLY1")],
            peers: [directive],
            dispatched: [printOp(status: .superseded)]
        )

        let action = RelayRun().nextAction(directive: directive, world: snapshot)

        #expect(action == .advanceStep(nextStep: RelayRun.Step.stowing.rawValue))
    }

    /// Before this change that same world stalled. Pin the regression: with no
    /// relay to claim, the superseded op still walks to the deadline and stalls
    /// — the pool must not have papered over a genuinely stuck run.
    @Test("a superseded print with no stock still stalls at the deadline")
    func supersededPrintWithNoStockStillStalls() {
        var directive = run("D1", carrier: "V1", createdAt: 0, step: RelayRun.Step.printing.rawValue)
        directive.stepStartedAt = Date(timeIntervalSince1970: 0)  // long past the print deadline
        let snapshot = world(
            devices: [carrier("V1"), hub()],
            peers: [directive],
            dispatched: [printOp(status: .superseded)]
        )

        let action = RelayRun().nextAction(directive: directive, world: snapshot)

        #expect(action == .stall(.noRelayCoLocated))
    }
}

// MARK: - The relay in the hold outranks the one this run printed

@Suite("Relay Run — what the carrier holds outranks what it printed")
struct RelayRunClaimOutranksPrintTests {
    /// Two printers stand at the hub, so a run's own print can complete AFTER it
    /// has already taken a spare off the pool and stowed it. Resolution must
    /// stay on the relay in the hold; following the clone watches a relay that
    /// is standing on the ground and can never come aboard.
    @Test("confirmStow follows the relay aboard, not the clone the print named")
    func stowedRelayOutranksThePrintedClone() {
        var directive = run("D1", carrier: "V1", createdAt: 0, step: RelayRun.Step.confirmingStow.rawValue)
        directive.stepStartedAt = Date(timeIntervalSince1970: 0)  // long past the stow deadline
        let snapshot = world(
            devices: [
                carrier("V1"), hub(),
                spare("RLY-POOL", location: nil, status: "stowed", stowedIn: "V1"),
                spare("RLY-PRINT"),
            ],
            peers: [directive],
            dispatched: [printOp(status: .completed, newDeviceCode: "RLY-PRINT")]
        )

        let action = RelayRun().nextAction(directive: directive, world: snapshot)

        #expect(action == .claimRelay(deviceCode: "RLY-POOL", nextStep: RelayRun.Step.travelling.rawValue))
    }

    /// …and the claim is what makes that survive `deploy`, which empties the
    /// hold and so retires the aboard lookup exactly when the later steps still
    /// need to know which relay this run is planting.
    @Test("a stamped claim outlives the deploy that empties the hold")
    func claimOutlivesTheDeploy() {
        var directive = run("D1", carrier: "V1", createdAt: 0, step: RelayRun.Step.activating.rawValue)
        directive.claimedRelayCode = "RLY-POOL"
        let point = "VEGA-1-L4"
        let snapshot = world(
            devices: [
                carrier("V1", location: point), hub(),
                spare("RLY-POOL", location: point),
                spare("RLY-PRINT"),
            ],
            peers: [directive],
            dispatched: [printOp(status: .completed, newDeviceCode: "RLY-PRINT")]
        )

        let action = RelayRun().nextAction(directive: directive, world: snapshot)

        #expect(action == .dispatch(
            kind: OperationKind.simple("activate"), deviceCode: "RLY-POOL",
            params: CommandParams(), nextStep: RelayRun.Step.confirmingRelay.rawValue
        ))
    }
}

// MARK: - FIFO

@Suite("Relay Run — the pool is served oldest-first")
struct RelayRunPoolFIFOTests {
    /// Two runs, two spares: they take DISJOINT relays, oldest to lowest code.
    /// Disjointness is what makes the claim race-free without a lease — the two
    /// runs are independent executors that can evaluate in the same instant.
    @Test("concurrent runs claim disjoint relays, oldest first")
    func concurrentRunsClaimDisjointRelays() {
        let older = run("D-OLD", carrier: "V1", createdAt: 100, step: RelayRun.Step.stowing.rawValue)
        let younger = run("D-NEW", carrier: "V2", createdAt: 200, step: RelayRun.Step.stowing.rawValue)
        let devices = [carrier("V1"), carrier("V2"), hub(), spare("RLY-A"), spare("RLY-B")]
        let peers = [older, younger]

        let olderAction = RelayRun().nextAction(directive: older, world: world(devices: devices, peers: peers))
        let youngerAction = RelayRun().nextAction(directive: younger, world: world(devices: devices, peers: peers))

        #expect(olderAction == .dispatch(
            kind: .stow, deviceCode: "RLY-A",
            params: CommandParams(target: "V1"), nextStep: RelayRun.Step.confirmingStow.rawValue
        ), "the older run takes the lowest-code relay")
        #expect(youngerAction == .dispatch(
            kind: .stow, deviceCode: "RLY-B",
            params: CommandParams(target: "V2"), nextStep: RelayRun.Step.confirmingStow.rawValue
        ), "the younger run takes a DIFFERENT relay, not the same one")
    }

    /// One spare, two runs: the older takes it and the younger prints rather
    /// than contending for it. This is the case that used to invert — the
    /// youngest run won the shared print queue.
    @Test("with one spare the older run takes it and the younger prints")
    func shallowPoolServesTheOlderRun() {
        let older = run("D-OLD", carrier: "V1", createdAt: 100)
        let younger = run("D-NEW", carrier: "V2", createdAt: 200)
        let devices = [carrier("V1"), carrier("V2"), hub(), spare("RLY-A")]
        let peers = [older, younger]

        let olderAction = RelayRun().nextAction(directive: older, world: world(devices: devices, peers: peers))
        let youngerAction = RelayRun().nextAction(directive: younger, world: world(devices: devices, peers: peers))

        #expect(olderAction == .advanceStep(nextStep: RelayRun.Step.stowing.rawValue))
        #expect(youngerAction == .dispatch(
            kind: .print, deviceCode: "AF1",
            params: CommandParams(deviceType: "ftl_relay"), nextStep: RelayRun.Step.printing.rawValue
        ))
    }

    /// The line has to ADVANCE: once the older run has its relay aboard it
    /// leaves the queue, and the younger becomes the head. Without this the
    /// second run would wait behind a run that is already flying.
    @Test("a run holding a relay leaves the queue")
    func loadedRunLeavesTheQueue() {
        let older = run("D-OLD", carrier: "V1", createdAt: 100)
        let younger = run("D-NEW", carrier: "V2", createdAt: 200)
        let devices = [
            carrier("V1"), carrier("V2"), hub(),
            spare("RLY-A", location: nil, stowedIn: "V1"),  // already aboard the older run
            spare("RLY-B"),
        ]

        #expect(RelayRun.queuePosition(younger, at: hubLocation, in: world(devices: devices, peers: [older, younger])) == 0)
        #expect(RelayRun().nextAction(
            directive: younger, world: world(devices: devices, peers: [older, younger])
        ) == .advanceStep(nextStep: RelayRun.Step.stowing.rawValue))
    }

    /// A paused run is stopped by operator choice and may stay stopped for good,
    /// so it must not sit at the head of the line holding everyone else off.
    /// `.needsAttention` is the opposite — halted but one retry from moving —
    /// and keeps its place, which is what lets the two live stalled runs be
    /// served in the order they were created.
    @Test("a paused run yields its place, a needsAttention one keeps it", arguments: [
        (DirectiveStatus.paused, 0),
        (DirectiveStatus.needsAttention, 1),
    ])
    func pausedRunsYieldTheirPlace(_ status: DirectiveStatus, expected: Int) {
        let ahead = run("D-AHEAD", carrier: "V2", createdAt: 1, status: status)
        let mine = run("D-MINE", carrier: "V1", createdAt: 500)
        let devices = [carrier("V1"), carrier("V2"), hub(), spare("RLY-A")]

        let position = RelayRun.queuePosition(
            mine, at: hubLocation, in: world(devices: devices, peers: [ahead, mine])
        )

        #expect(position == expected)
    }

    /// Only Relay Runs at THIS hub are in the line — another kind of mission, or
    /// a Relay Run whose carrier stands somewhere else, is not competing for
    /// this pool and must not push anyone down it.
    @Test("the queue counts only Relay Runs waiting at this hub")
    func queueIsScopedToRelayRunsAtThisHub() {
        var haul = run("D-HAUL", carrier: "V2", createdAt: 1)
        haul.kind = .haulRun
        var elsewhere = run("D-FAR", carrier: "V3", createdAt: 2)
        elsewhere.deviceCode = "V3"
        let mine = run("D-MINE", carrier: "V1", createdAt: 500)
        let devices = [carrier("V1"), carrier("V2"), carrier("V3", location: "FAR-AWAY"), hub(), spare("RLY-A")]

        let position = RelayRun.queuePosition(
            mine, at: hubLocation, in: world(devices: devices, peers: [haul, elsewhere, mine])
        )

        #expect(position == 0, "neither the haul run nor the distant relay run is in this hub's line")
    }
}
