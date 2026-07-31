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
    log: [DirectiveLogEntry] = [],
    now: Date = fixtureNow
) -> WorldSnapshot {
    WorldSnapshot(
        devices: Dictionary(devices.map { ($0.deviceCode, $0) }, uniquingKeysWith: { _, last in last }),
        openOperations: [:],
        log: log,
        footprints: Dictionary(footprints.map { ($0.location, $0) }, uniquingKeysWith: { _, last in last }),
        now: now
    )
}

/// A bare `.stepStarted` timeline entry, the shape `dispatchAttemptCount`
/// walks — everything the log-derived re-entry budget needs and nothing
/// else. `id` is just a running counter; nothing in the budget reads it.
private func stepStartedEntry(_ id: Int, _ step: String, at occurredAt: Date) -> DirectiveLogEntry {
    DirectiveLogEntry(
        id: "L\(id)", directiveID: "D1", deviceCode: nil, kind: .stepStarted,
        summary: "Step: \(step)", step: step, operationID: nil, eventID: nil,
        occurredAt: occurredAt
    )
}

private func run(
    step: String,
    stepStartedAt: Date = fixtureNow,
    fleetTag: String? = HaulRun.defaultFleetTag,
    controllerCode: String? = nil
) -> Directive {
    Directive(
        id: "D1", kind: .haulRun, status: .running, deviceCode: "C1",
        controllerCode: controllerCode,
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

    /// The headline: pin the controller against the richest reachable pile.
    /// `assigning` no longer dispatches directly — it claims the controller
    /// (`.assignController`) and hands off to `dispatching`, which is what lets
    /// `confirming` later judge exactly this one controller rather than the
    /// whole fleet's plan (fix landed 2026-07-31, see `Step.dispatching`).
    @Test func assigningPinsTheControllerAtTheRichestPile() {
        let action = HaulRun().nextAction(
            directive: run(step: HaulRun.Step.assigning),
            world: world(
                devices: [controller("C1")] + meshed,
                footprints: [footprint("ATIANFU-BELT-1", 3_537)]
            )
        )
        #expect(action == .assignController(deviceCode: "C1", nextStep: HaulRun.Step.dispatching))
    }

    /// The guard that makes repointing terminate: a controller already running
    /// the intended config is left alone. Without this the run would re-pin the
    /// same controller on every cycle forever.
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

    /// A controller pointed at a DIFFERENT pile is not in force, so it is
    /// pinned again for repointing — this is what happens the moment a pile
    /// drains. The actual re-dispatch (with the NEW pile's params) is
    /// `dispatching`'s job — see `dispatchingRepointsToTheNewRichestPile`.
    @Test func assigningRepinsAControllerOnADrainedPile() {
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
        #expect(action == .assignController(deviceCode: "C1", nextStep: HaulRun.Step.dispatching))
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

    /// **CRITICAL regression guard (2026-07-31 review).** Once the first pinned
    /// controller settles, `assigning` reaches the SECOND one — the sequence
    /// the original single-step design could never complete, because
    /// `confirming` re-derived the whole plan and waited on a controller
    /// nothing had dispatched.
    @Test func assigningReachesTheSecondControllerOnceTheFirstSettles() {
        let settledC1 = controller(
            "C1", currentDirective: "ferry",
            currentConfig: [
                "collect": .string("ATIANFU-BELT-1"),
                "deliver": .string(HaulRun.deliveryLocation),
            ]
        )
        let c2 = controller("C2")
        // A second reachable pile in the ALREADY-meshed delivery system
        // (AINALRAM) — no extra relay needed, and richer than nothing.
        let action = HaulRun().nextAction(
            directive: run(step: HaulRun.Step.assigning, controllerCode: "C1"),
            world: world(
                devices: [settledC1, c2] + meshed,
                footprints: [footprint("ATIANFU-BELT-1", 3_537), footprint("AINALRAM-2", 900)]
            )
        )
        #expect(action == .assignController(deviceCode: "C2", nextStep: HaulRun.Step.dispatching))
    }

    // MARK: dispatching

    /// Once pinned, the controller is issued the exact command `assigning`
    /// chose: the richest reachable pile, `ferry` to the delivery location.
    @Test func dispatchingIssuesSetDirectiveToThePinnedController() {
        let action = HaulRun().nextAction(
            directive: run(step: HaulRun.Step.dispatching, controllerCode: "C1"),
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

    /// The repoint case: a controller pinned while sitting on a now-drained
    /// pile is issued the NEW richest target, not the old one.
    @Test func dispatchingRepointsToTheNewRichestPile() {
        let onOldPile = controller(
            "C1", currentDirective: "ferry",
            currentConfig: [
                "collect": .string("SHERATANON-6-1"),
                "deliver": .string(HaulRun.deliveryLocation),
            ]
        )
        let action = HaulRun().nextAction(
            directive: run(step: HaulRun.Step.dispatching, controllerCode: "C1"),
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

    /// **Minor regression guard (2026-07-31 review).** The controller
    /// `assigning` pinned is gone by the time `dispatching` runs — untagged or
    /// removed mid-cycle. This is where the unreachable-device guard can
    /// actually fire: `Directive.controllerCode` is read back off the
    /// persisted row here, unlike in `assigning` where it always comes fresh
    /// from `world.devices` and could never be absent.
    @Test func dispatchingStallsWhenThePinnedControllerHasVanished() {
        let action = HaulRun().nextAction(
            directive: run(step: HaulRun.Step.dispatching, controllerCode: "C1"),
            world: world(devices: meshed, footprints: [footprint("ATIANFU-BELT-1", 3_537)])
        )
        #expect(action == .stall(.unreachableDevice))
    }

    /// Defensive: `assigning` always pins a controller before advancing here,
    /// so this should never happen in practice — but waiting/re-planning is
    /// inert and recoverable, so a missing pin bounces back rather than
    /// force-unwrapping.
    @Test func dispatchingWithNoPinnedControllerReturnsToAssigning() {
        let action = HaulRun().nextAction(
            directive: run(step: HaulRun.Step.dispatching),
            world: world(devices: [controller("C1")] + meshed, footprints: [footprint("ATIANFU-BELT-1", 3_537)])
        )
        #expect(action == .advanceStep(nextStep: HaulRun.Step.assigning))
    }

    /// Deferred item folded in during the round-2 fix: a controller that
    /// became correctly pointed BETWEEN the `assigning` and `dispatching`
    /// ticks (another controller's dispatch shifted the ranking, say) gets no
    /// redundant `set_directive` — `dispatchAssignment` re-checks `isInForce`
    /// before issuing anything.
    @Test func dispatchingSkipsARedundantDispatchWhenAlreadyInForce() {
        let alreadySettled = controller(
            "C1", currentDirective: "ferry",
            currentConfig: [
                "collect": .string("ATIANFU-BELT-1"),
                "deliver": .string(HaulRun.deliveryLocation),
            ]
        )
        let action = HaulRun().nextAction(
            directive: run(step: HaulRun.Step.dispatching, controllerCode: "C1"),
            world: world(devices: [alreadySettled] + meshed, footprints: [footprint("ATIANFU-BELT-1", 3_537)])
        )
        #expect(action == .advanceStep(nextStep: HaulRun.Step.assigning))
    }

    // MARK: dispatch-attempt budget
    //
    // Round-2 regression coverage: `hasTakenSomeHaulConfig` (used by
    // `confirm`) is looser than `isInForce` (used by `assign`), so a
    // controller whose dispatched command is accepted but never actually
    // APPLIED reads as instantly settled and gets re-pinned/re-dispatched by
    // `assign` every cycle forever, with no deadline anywhere in the loop to
    // stop it. `dispatchAssignment`'s log-derived `dispatchAttemptCount`
    // bounds that.

    /// Right at the budget: exactly `dispatchAttemptLimit` PRIOR dispatches
    /// are logged, so this evaluation is dispatch number `dispatchAttemptLimit`
    /// itself — still within budget, so it proceeds.
    @Test func dispatchingProceedsWithinItsRepeatAttemptBudget() {
        var log: [DirectiveLogEntry] = []
        var when = fixtureNow.addingTimeInterval(-60)
        var nextID = 0
        for _ in 0..<(HaulRun.dispatchAttemptLimit - 1) {
            log.append(stepStartedEntry(nextID, HaulRun.Step.assigning, at: when)); nextID += 1; when += 1
            log.append(stepStartedEntry(nextID, HaulRun.Step.dispatching, at: when)); nextID += 1; when += 1
            log.append(stepStartedEntry(nextID, HaulRun.Step.confirming, at: when)); nextID += 1; when += 1
        }
        log.append(stepStartedEntry(nextID, HaulRun.Step.assigning, at: when)); nextID += 1; when += 1
        log.append(stepStartedEntry(nextID, HaulRun.Step.dispatching, at: when)) // the CURRENT entry

        let stillOnOldPile = controller(
            "C1", currentDirective: "ferry",
            currentConfig: [
                "collect": .string("SOME-OLDER-PILE-1"),
                "deliver": .string(HaulRun.deliveryLocation),
            ]
        )
        let action = HaulRun().nextAction(
            directive: run(step: HaulRun.Step.dispatching, controllerCode: "C1"),
            world: world(
                devices: [stillOnOldPile] + meshed,
                footprints: [footprint("ATIANFU-BELT-1", 3_537)],
                log: log
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

    /// **The loop terminator.** One cycle past `dispatchingProceedsWithinItsRepeatAttemptBudget`
    /// — `dispatchAttemptLimit` PRIOR dispatches plus this one makes
    /// `dispatchAttemptLimit + 1`, so `dispatchAssignment` stalls instead of
    /// spending another `set_directive` POST on a command that has already
    /// failed to apply this many times running. Without this bound, the
    /// scenario `censusChurnDuringConfirmDoesNotFalselyStall` exercises for
    /// `confirm` turns into an unbounded re-dispatch loop the moment the
    /// controller's config genuinely never updates.
    @Test func dispatchingStallsAfterExhaustingItsRepeatAttemptBudget() {
        var log: [DirectiveLogEntry] = []
        var when = fixtureNow.addingTimeInterval(-60)
        var nextID = 0
        for _ in 0..<HaulRun.dispatchAttemptLimit {
            log.append(stepStartedEntry(nextID, HaulRun.Step.assigning, at: when)); nextID += 1; when += 1
            log.append(stepStartedEntry(nextID, HaulRun.Step.dispatching, at: when)); nextID += 1; when += 1
            log.append(stepStartedEntry(nextID, HaulRun.Step.confirming, at: when)); nextID += 1; when += 1
        }
        log.append(stepStartedEntry(nextID, HaulRun.Step.assigning, at: when)); nextID += 1; when += 1
        log.append(stepStartedEntry(nextID, HaulRun.Step.dispatching, at: when)) // the CURRENT entry

        let stillOnOldPile = controller(
            "C1", currentDirective: "ferry",
            currentConfig: [
                "collect": .string("SOME-OLDER-PILE-1"),
                "deliver": .string(HaulRun.deliveryLocation),
            ]
        )
        let action = HaulRun().nextAction(
            directive: run(step: HaulRun.Step.dispatching, controllerCode: "C1"),
            world: world(
                devices: [stillOnOldPile] + meshed,
                footprints: [footprint("ATIANFU-BELT-1", 3_537)],
                log: log
            )
        )
        #expect(action == .stall(.commandRejected))
    }

    /// A Retry (`.resolved`) re-arms the budget exactly like
    /// `SalvageRun.stepEntryCount` — an operator's Retry must buy a genuinely
    /// new attempt, not replay an exhausted one.
    @Test func dispatchingRetryReArmsTheBudget() {
        var log: [DirectiveLogEntry] = []
        var when = fixtureNow.addingTimeInterval(-120)
        var nextID = 0
        // A full exhausted budget...
        for _ in 0..<HaulRun.dispatchAttemptLimit {
            log.append(stepStartedEntry(nextID, HaulRun.Step.assigning, at: when)); nextID += 1; when += 1
            log.append(stepStartedEntry(nextID, HaulRun.Step.dispatching, at: when)); nextID += 1; when += 1
            log.append(stepStartedEntry(nextID, HaulRun.Step.confirming, at: when)); nextID += 1; when += 1
        }
        // ...followed by an operator Retry...
        log.append(DirectiveLogEntry(
            id: "LR", directiveID: "D1", deviceCode: nil, kind: .resolved,
            summary: "Retried", step: HaulRun.Step.confirming, operationID: nil,
            eventID: nil, occurredAt: when
        ))
        when += 1
        // ...and one fresh attempt since.
        log.append(stepStartedEntry(nextID, HaulRun.Step.assigning, at: when)); nextID += 1; when += 1
        log.append(stepStartedEntry(nextID, HaulRun.Step.dispatching, at: when)) // the CURRENT entry

        let stillOnOldPile = controller(
            "C1", currentDirective: "ferry",
            currentConfig: [
                "collect": .string("SOME-OLDER-PILE-1"),
                "deliver": .string(HaulRun.deliveryLocation),
            ]
        )
        let action = HaulRun().nextAction(
            directive: run(step: HaulRun.Step.dispatching, controllerCode: "C1"),
            world: world(
                devices: [stillOnOldPile] + meshed,
                footprints: [footprint("ATIANFU-BELT-1", 3_537)],
                log: log
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

    // MARK: confirming

    /// While the controller has not taken the config, wait — and crucially do NOT
    /// re-dispatch, which would reset the deadline measuring the wait.
    @Test func confirmingWaitsForTheControllerToTakeTheConfig() {
        let action = HaulRun().nextAction(
            directive: run(step: HaulRun.Step.confirming, controllerCode: "C1"),
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
            directive: run(step: HaulRun.Step.confirming, controllerCode: "C1"),
            world: world(devices: [settled] + meshed, footprints: [footprint("ATIANFU-BELT-1", 3_537)])
        )
        #expect(action == .advanceStep(nextStep: HaulRun.Step.assigning))
    }

    /// **CRITICAL regression guard (2026-07-31 review).** `confirming` must
    /// judge only the controller it was dispatched for — never the whole
    /// tagged fleet. Two controllers, only one ever dispatched: before the
    /// fix, `confirming` re-derived the full plan and saw the untouched
    /// second controller "pending" forever, so it could never leave this
    /// step and the run stalled with a false `.commandRejected` inside
    /// `confirmDeadline`. `assigning` dispatches exactly one controller per
    /// tick ("N controllers settle over N ticks"), so `confirming` must see
    /// only the ONE it was pinned to for that to actually be true.
    @Test func confirmingIgnoresAnUndispatchedSecondController() {
        let settledC1 = controller(
            "C1", currentDirective: "ferry",
            currentConfig: [
                "collect": .string("ATIANFU-BELT-1"),
                "deliver": .string(HaulRun.deliveryLocation),
            ]
        )
        let neverDispatchedC2 = controller("C2")
        // Both piles REACHABLE (unlike an earlier draft of this test, which
        // put the second pile in an unmeshed system — `HaulTargetPlanner`
        // filtered it out, `zip` produced only ONE assignment, C2 never
        // appeared in the plan at all, and the test passed against the
        // pre-fix code too, proving nothing). `AINALRAM-2` shares the
        // delivery system, so it's reachable by construction.
        let action = HaulRun().nextAction(
            directive: run(step: HaulRun.Step.confirming, controllerCode: "C1"),
            world: world(
                devices: [settledC1, neverDispatchedC2] + meshed,
                footprints: [footprint("ATIANFU-BELT-1", 3_537), footprint("AINALRAM-2", 900)]
            )
        )
        #expect(action == .advanceStep(nextStep: HaulRun.Step.assigning))
    }

    /// **IMPORTANT regression guard (2026-07-31 review).** The census can move
    /// during the confirm window — even with a SINGLE controller — because
    /// `LocationsFeature` refreshes the footprint table whenever the operator
    /// opens the Locations catalog. `confirming` must accept ANY config this
    /// run could have issued, not only the exact pile most recently ranked
    /// richest, or a re-derived plan that no longer names the controller's
    /// real (accepted) target produces the same false stall as the critical
    /// bug above, reachable with just one controller.
    @Test func censusChurnDuringConfirmDoesNotFalselyStall() {
        let settledOnItsOriginalPile = controller(
            "C1", currentDirective: "ferry",
            currentConfig: [
                "collect": .string("ATIANFU-BELT-1"),
                "deliver": .string(HaulRun.deliveryLocation),
            ]
        )
        // A richer, REACHABLE pile appeared after the dispatch was issued —
        // re-deriving the plan now would name a DIFFERENT collect target than
        // the one C1 is actually running. `AINALRAM-2` shares the delivery
        // system, so — unlike an earlier draft of this test, which used an
        // unmeshed location that `HaulTargetPlanner` filtered out before it
        // ever entered the ranking — it is genuinely reachable and genuinely
        // outranks `ATIANFU-BELT-1` once ATIANFU has been drawn down to 100.
        let action = HaulRun().nextAction(
            directive: run(step: HaulRun.Step.confirming, controllerCode: "C1"),
            world: world(
                devices: [settledOnItsOriginalPile] + meshed,
                footprints: [footprint("ATIANFU-BELT-1", 100), footprint("AINALRAM-2", 9_000)]
            )
        )
        #expect(action == .advanceStep(nextStep: HaulRun.Step.assigning))
    }

    /// **Controller vanishing between assign and confirm.** The device
    /// `dispatching` issued the command to is gone by the time `confirming`
    /// checks it — waiting out the deadline on a device that can never report
    /// back would just delay reaching the same conclusion.
    @Test func confirmingStallsWhenThePinnedControllerHasVanished() {
        let action = HaulRun().nextAction(
            directive: run(step: HaulRun.Step.confirming, controllerCode: "C1"),
            world: world(devices: meshed, footprints: [footprint("ATIANFU-BELT-1", 3_537)])
        )
        #expect(action == .stall(.unreachableDevice))
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
                stepStartedAt: fixtureNow.addingTimeInterval(-HaulRun.confirmDeadline - 1),
                controllerCode: "C1"
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
