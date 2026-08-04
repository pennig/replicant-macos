//
//  RelayReturnAndRestockTests.swift
//  Replicould — DirectiveEngine
//
//  The two halves of "the mesh grows unattended": the Relay Run's RETURN LEG,
//  and the demand-driven RESTOCK run that keeps spares standing at the hub.
//
//  Both come from `docs/superpowers/specs/2026-08-04-relay-return-and-restock-design.md`,
//  and both exist to remove a manual step:
//
//    1. The carrier used to stay where it planted its relay. On a one-carrier
//       fleet that meant the brain grew the mesh exactly once and then idled
//       until a human flew the vessel home.
//    2. Nothing printed ahead of demand, so the pool only ever drained and
//       every run afterwards waited out a print before it could leave.
//
//  The end-to-end proof that the loop now closes is
//  `BrainGrowLifecycleE2ETests`. This file is the unit half: the individual
//  decisions, including the ones the e2e's happy path never reaches.
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

/// The hub, and the deliberate gap this whole design turns on: the hub is a
/// LOCATION (`AINALRAM-BELT-1`) while `directive.originDesignation` only ever
/// holds its SYSTEM (`AINALRAM`). Travelling to the latter lands the carrier at
/// the system's entry point — an L4 — and not beside the autofactory.
private let hubLocation = "AINALRAM-BELT-1"
private let hubSystem = "AINALRAM"

private func device(
    _ code: String,
    type: String = "generic_device",
    location: String? = nil,
    stowedIn: String? = nil,
    status: String = "idle",
    features: [String] = [],
    availableCommands: [String] = [],
    tags: [String] = [],
    updatedAt: Date = now
) -> Device {
    Device(
        deviceCode: code, deviceType: type, replicantCode: "R1", status: status,
        location: location, locationName: nil, operationalCapacity: 100, queueSize: 0,
        stowedInDeviceCode: stowedIn, controllerDeviceCode: nil, attachedToDeviceCode: nil,
        createdAt: Date(timeIntervalSince1970: 0), availableCommands: availableCommands,
        features: features, tags: tags, detail: .object([:]),
        updatedAt: updatedAt, firstSeenAt: Date(timeIntervalSince1970: 0)
    )
}

private func carrier(_ code: String = "V1", location: String?) -> Device {
    device(code, type: "heaven_vessel", location: location, tags: [Brain.carrierTag])
}

private func hub(_ code: String = "AF1", location: String = hubLocation) -> Device {
    device(code, type: "autofactory", location: location, availableCommands: ["enqueue_print"])
}

/// A planted, live relay. Its SYSTEM is what makes a location count as meshed,
/// which is half of what makes a hub a hub.
private func liveRelay(_ code: String, at location: String) -> Device {
    device(code, type: "ftl_relay", location: location, status: "relaying", features: ["relay"])
}

/// An idle spare standing at the hub — what restock exists to produce.
private func spare(_ code: String, at location: String = hubLocation) -> Device {
    device(code, type: "ftl_relay", location: location, status: "inactive", features: ["cruise", "relay", "stow"])
}

private func census(_ resources: Int, at location: String = hubLocation, fetchedAt: Date = now) -> [String: LocationFootprint] {
    [location: LocationFootprint(
        location: location, devices: 1, resources: resources,
        resourceSites: 0, locationEvents: 0, replicants: 0, fetchedAt: fetchedAt
    )]
}

/// Comfortably above `BrainCeiling.aggregateSpendFloor`, so the reserve rail is
/// armed and silent — these tests are about the OTHER decisions, and a world the
/// rail vetoes would never reach them.
private func healthyCensus(fetchedAt: Date = now) -> [String: LocationFootprint] {
    census(BrainCeiling.aggregateSpendFloor * 2, fetchedAt: fetchedAt)
}

private func world(
    devices: [Device],
    openOperations: [String: GameModels.Operation] = [:],
    footprints: [String: LocationFootprint]? = nil,
    at instant: Date = now
) -> WorldSnapshot {
    WorldSnapshot(
        devices: Dictionary(devices.map { ($0.deviceCode, $0) }, uniquingKeysWith: { _, last in last }),
        openOperations: openOperations, log: [], dispatchedOperations: [:],
        systems: [:], siteAssays: [:], footprints: footprints ?? healthyCensus(), peers: [], now: instant
    )
}

private func openOp(_ entity: String, kind: OperationKind) -> [String: GameModels.Operation] {
    [entity: GameModels.Operation(
        id: "OP-1", entityCode: entity, kind: kind.rawValue, status: .active,
        source: .poll, startedAt: now, completesAt: nil, lastConfirmedAt: now, detail: .object([:])
    )]
}

private func relayRun(
    step: String,
    carrier code: String = "V1",
    returnToOrigin: Bool,
    target: String = "VEGA",
    stepStartedAt: Date = Date(timeIntervalSince1970: 9_900)
) -> Directive {
    Directive(
        id: "D1", kind: .relayRun, status: .running, deviceCode: code,
        controllerCode: nil, roamCentre: nil, fleetTag: nil, sourceRelayCode: nil,
        targets: [target], targetIndex: 0, step: step, stepStartedAt: stepStartedAt,
        returnToOrigin: returnToOrigin, originDesignation: hubSystem, attentionReason: nil,
        createdAt: Date(timeIntervalSince1970: 9_000), updatedAt: now
    )
}

private func restockRun(
    step: String = RestockRun.Step.stocking,
    hub code: String = "AF1",
    targets: [String],
    stepStartedAt: Date = Date(timeIntervalSince1970: 9_900)
) -> Directive {
    Directive(
        id: "R1", kind: .restockRun, status: .running, deviceCode: code,
        controllerCode: nil, roamCentre: nil, fleetTag: nil, sourceRelayCode: nil,
        targets: targets, targetIndex: 0, step: step, stepStartedAt: stepStartedAt,
        returnToOrigin: false, originDesignation: hubSystem, attentionReason: nil,
        createdAt: Date(timeIntervalSince1970: 9_000), updatedAt: now
    )
}

// MARK: - The return leg

@Suite("Relay Run — the return leg")
struct RelayRunReturnLegTests {

    /// A settled run hands the carrier back. This is the transition that used
    /// to be `.done`, and the reason a one-carrier fleet grew the mesh exactly
    /// once.
    @Test("a meshed target advances to returning when the run was asked to come home")
    func settlingAdvancesToReturning() {
        let directive = relayRun(step: RelayRun.Step.settling, returnToOrigin: true)
        let snapshot = world(devices: [
            carrier(location: "VEGA-1-L4"), hub(), liveRelay("REL0", at: hubLocation),
            liveRelay("RLY1", at: "VEGA-1-L4"),
        ])

        #expect(RelayRun().nextAction(directive: directive, world: snapshot)
                == .advanceStep(nextStep: RelayRun.Step.returning))
    }

    /// …and ONLY when it was asked. `returnToOrigin` is a per-directive
    /// instruction, not a policy baked into the machine: an operator-launched
    /// run that deliberately chains onward must still be able to.
    @Test("a run that was not asked to come home finishes where it stands")
    func settlingIsDoneWithoutReturnToOrigin() {
        let directive = relayRun(step: RelayRun.Step.settling, returnToOrigin: false)
        let snapshot = world(devices: [
            carrier(location: "VEGA-1-L4"), hub(), liveRelay("REL0", at: hubLocation),
            liveRelay("RLY1", at: "VEGA-1-L4"),
        ])

        #expect(RelayRun().nextAction(directive: directive, world: snapshot) == .done)
    }

    /// **The load-bearing assertion of the whole return leg.**
    ///
    /// The destination is the hub LOCATION, re-derived from the world — not
    /// `directive.originDesignation`, which carries only the SYSTEM. A bare
    /// system designation travels to that system's entry point, an L4
    /// (`travel-system-proxy-codes`), so a run that used the remembered field
    /// would fly the carrier home to `AINALRAM-1-L4` while the autofactory
    /// stands at `AINALRAM-BELT-1`. `Brain.freeCarrier` demands an exact
    /// location match, so the carrier would be back in the right system and
    /// still unusable — the manual step moved rather than removed.
    @Test("returning flies to the hub LOCATION, never to the origin SYSTEM")
    func returningTargetsTheHubLocation() {
        let directive = relayRun(step: RelayRun.Step.returning, returnToOrigin: true)
        let snapshot = world(devices: [
            carrier(location: "VEGA-1-L4"), hub(), liveRelay("REL0", at: hubLocation),
        ])

        let action = RelayRun().nextAction(directive: directive, world: snapshot)

        #expect(action == .dispatch(
            kind: .travel, deviceCode: "V1",
            params: CommandParams(destination: hubLocation),
            nextStep: RelayRun.Step.returning
        ))
        #expect(action != .dispatch(
            kind: .travel, deviceCode: "V1",
            params: CommandParams(destination: directive.originDesignation),
            nextStep: RelayRun.Step.returning
        ), "the remembered origin is the lossy projection this must not use")
    }

    /// A carrier that never left, or that has arrived, is finished — no command
    /// at all. Mirrors `SurveyRun.returnHome`'s guard.
    @Test("a carrier already standing at the hub skips the leg")
    func alreadyHomeIsDone() {
        let directive = relayRun(step: RelayRun.Step.returning, returnToOrigin: true)
        let snapshot = world(devices: [
            carrier(location: hubLocation), hub(), liveRelay("REL0", at: hubLocation),
        ])

        #expect(RelayRun().nextAction(directive: directive, world: snapshot) == .done)
    }

    /// The trip is already under way: an open op on the carrier means a travel
    /// was issued and has not landed. Re-dispatching would stack a second
    /// travel on top of the first.
    @Test("an open operation on the carrier waits rather than re-issuing the travel")
    func openOperationWaits() {
        let directive = relayRun(step: RelayRun.Step.returning, returnToOrigin: true)
        let snapshot = world(
            devices: [carrier(location: "VEGA-1-L4"), hub(), liveRelay("REL0", at: hubLocation)],
            openOperations: openOp("V1", kind: .travel)
        )

        #expect(RelayRun().nextAction(directive: directive, world: snapshot) == .wait)
    }

    /// **No hub to fly to is `.done`, not a stall.** The relay is planted and
    /// the run's actual deliverable is met; a carrier left standing at the
    /// target is exactly where it would have been before this step existed. A
    /// stall here would escalate a run that succeeded, and put a human in the
    /// loop to tell them nothing had gone wrong.
    @Test("a world with no recognisable hub finishes the run instead of escalating")
    func noHubIsDoneNotStall() {
        let directive = relayRun(step: RelayRun.Step.returning, returnToOrigin: true)
        // The printer is present but its location holds NO stock, so it is not a
        // hub — the recognition rule fixed in `d4d46ea`.
        let snapshot = world(
            devices: [carrier(location: "VEGA-1-L4"), hub(), liveRelay("REL0", at: hubLocation)],
            footprints: census(0)
        )

        #expect(RelayRun().nextAction(directive: directive, world: snapshot) == .done)
    }
}

// MARK: - The hub seam

@Suite("Hub recognition — one rule, both callers")
struct HubRecognitionSeamTests {

    /// The brain launches from `WorldView.hubLocation` and the return leg flies
    /// to `RelayRun.hubLocation`. **If those two ever disagree, a run flies
    /// "home" to somewhere the next launch will not look**, and the fleet stalls
    /// with a carrier parked one location away from the printer. So the second
    /// is an adapter over the first rather than a second copy of the rule, and
    /// this pins that they answer identically on the same world.
    @Test("the mission's view of the hub is the brain's view of the hub", arguments: [
        ("a stocked printer in a meshed system", BrainCeiling.aggregateSpendFloor * 2, hubLocation, String?.some(hubLocation)),
        ("a printer whose location holds nothing", 0, hubLocation, String?.none),
        ("a printer in an unmeshed system", BrainCeiling.aggregateSpendFloor * 2, "ELSEWHERE-BELT-1", String?.none),
    ])
    func bothCallersAgree(_ label: String, stock: Int, printerAt: String, expected: String?) {
        let devices = [
            hub(location: printerAt),
            liveRelay("REL0", at: hubLocation),
            carrier(location: hubLocation),
        ]
        let snapshot = world(devices: devices, footprints: census(stock, at: printerAt))

        let fromMission = RelayRun.hubLocation(in: snapshot)
        let fromBrain = WorldView.hubLocation(
            in: devices,
            meshSystems: SalvageTargetPlanner.meshSystems(in: devices),
            stockByLocation: snapshot.footprints.mapValues(\.resources)
        )

        #expect(fromMission == expected, "\(label): the mission's answer")
        #expect(fromMission == fromBrain, "\(label): and it is the brain's answer")
    }
}

// MARK: - Restock

@Suite("Restock Run — the printer runs against demand")
struct RestockRunTests {

    /// The headline: unmet demand and an empty pool means print one.
    @Test("a pool below demand prints a relay")
    func printsWhileBelowTarget() {
        let directive = restockRun(targets: ["VEGA", "ALTAIR"])
        let snapshot = world(devices: [hub(), liveRelay("REL0", at: hubLocation)])

        #expect(RestockRun().nextAction(directive: directive, world: snapshot) == .dispatch(
            kind: .print, deviceCode: "AF1",
            params: CommandParams(deviceType: RelayRun.relayDeviceType),
            nextStep: RestockRun.Step.printing
        ))
    }

    /// Enough spares already standing for the demand on the row — stop. The
    /// printer is not run for its own sake.
    @Test("a pool that already meets demand waits")
    func stopsAtDesired() {
        let directive = restockRun(targets: ["VEGA"])
        let snapshot = world(devices: [hub(), liveRelay("REL0", at: hubLocation), spare("RLY1")])

        #expect(RestockRun().nextAction(directive: directive, world: snapshot) == .wait)
    }

    /// **The cap.** Demand far beyond `idleCap` does not turn the whole
    /// stockpile into relays nobody is flying yet: ten parked spares is 3,700
    /// units of capital sitting in inventory rather than held as reserve.
    @Test("demand beyond the cap is clamped to the cap")
    func stopsAtTheCap() {
        let manyTargets = (1...25).map { "SYS\($0)" }
        let directive = restockRun(targets: manyTargets)
        #expect(RestockRun.desiredIdle(for: directive) == RestockRun.idleCap)

        let spares = (1...RestockRun.idleCap).map { spare("RLY\($0)") }
        let snapshot = world(devices: [hub(), liveRelay("REL0", at: hubLocation)] + spares)

        #expect(RestockRun().nextAction(directive: directive, world: snapshot) == .wait,
                "at the cap the printer stops, however much demand is left")
    }

    /// Demand met — every candidate meshed or already being flown to — so the
    /// row idles rather than completing. It is persistent by design: demand
    /// comes back as new value is surveyed.
    @Test("no demand means nothing to print for")
    func stopsWhenDemandIsMet() {
        let directive = restockRun(targets: [])
        let snapshot = world(devices: [hub(), liveRelay("REL0", at: hubLocation)])

        #expect(RestockRun.desiredIdle(for: directive) == 0)
        #expect(RestockRun().nextAction(directive: directive, world: snapshot) == .wait)
    }

    /// **One print in flight at a time, and this is a correctness guard rather
    /// than a throttle.** `CommandClient` supersedes any other open op on a
    /// device, so a second dispatch would silently orphan the first's operation
    /// row — the failure that stranded two Relay Runs on 2026-08-04.
    @Test("a print already in flight is never doubled up")
    func neverPrintsWithOneInFlight() {
        let directive = restockRun(targets: ["VEGA", "ALTAIR"])
        let snapshot = world(
            devices: [hub(), liveRelay("REL0", at: hubLocation)],
            openOperations: openOp("AF1", kind: .print)
        )

        #expect(RestockRun().nextAction(directive: directive, world: snapshot) == .wait)
    }

    /// The reserve floor is the same rail `RelayRun` arms, read through the same
    /// veto so the two cannot drift apart about what "too poor to print" means.
    @Test("the reserve floor vetoes the top-up")
    func respectsTheReserveVeto() {
        let directive = restockRun(targets: ["VEGA", "ALTAIR"])
        let snapshot = world(
            devices: [hub(), liveRelay("REL0", at: hubLocation)],
            footprints: census(1)
        )

        #expect(RestockRun().nextAction(directive: directive, world: snapshot) == .wait)
    }

    /// A census too old to trust is not evidence either way, so it waits. Unlike
    /// `RelayRun.acquire` there is no carrier standing by for the answer, so
    /// restock spends no read to hurry a top-up.
    @Test("a stale census waits rather than spending against an unreadable stockpile")
    func staleCensusWaits() {
        let directive = restockRun(targets: ["VEGA", "ALTAIR"])
        let stale = now.addingTimeInterval(-(RelayRun.pollInterval + 60))
        let snapshot = world(
            devices: [hub(), liveRelay("REL0", at: hubLocation)],
            footprints: healthyCensus(fetchedAt: stale)
        )

        #expect(RestockRun().nextAction(directive: directive, world: snapshot) == .wait)
    }

    /// **Every declining branch is `.wait`, never `.stall`.** Demand met, cap
    /// reached, print in flight, reserve short, census stale — none of those
    /// need an operator, and `brain-robustness-bar` clause 6 is explicit that
    /// idle-calm must not be dressed up as a halt. Asserted as a sweep so a new
    /// declining branch added later cannot quietly escalate.
    @Test("no ordinary refusal ever escalates")
    func refusalsNeverEscalate() {
        let inFlight = world(
            devices: [hub(), liveRelay("REL0", at: hubLocation)],
            openOperations: openOp("AF1", kind: .print)
        )
        let cases: [(String, Directive, WorldSnapshot)] = [
            ("demand met", restockRun(targets: []), world(devices: [hub(), liveRelay("REL0", at: hubLocation)])),
            ("pool full", restockRun(targets: ["VEGA"]),
             world(devices: [hub(), liveRelay("REL0", at: hubLocation), spare("RLY1")])),
            ("print in flight", restockRun(targets: ["VEGA"]), inFlight),
            ("reserve short", restockRun(targets: ["VEGA"]),
             world(devices: [hub(), liveRelay("REL0", at: hubLocation)], footprints: census(1))),
        ]

        for (label, directive, snapshot) in cases {
            let action = RestockRun().nextAction(directive: directive, world: snapshot)
            #expect(action == .wait, "\(label) must wait")
            if case .stall = action { Issue.record("\(label) escalated to a human") }
        }
    }

    /// The ONE legitimate stall: the hub has left the fleet. Guessing at another
    /// printer would be a fabrication, so this is the case that does want an
    /// operator.
    @Test("a hub that is gone from the fleet is the one thing worth escalating")
    func missingHubStalls() {
        let directive = restockRun(targets: ["VEGA"])
        let snapshot = world(devices: [liveRelay("REL0", at: hubLocation)])

        #expect(RestockRun().nextAction(directive: directive, world: snapshot)
                == .stall(.unreachableDevice))
    }

    /// **Restock does not care WHICH relay arrived**, unlike `RelayRun.printing`
    /// which must identify its own clone to fly it somewhere. Any relay reaching
    /// the hub's idle stock satisfies it, so the superseded-op failure that
    /// stranded two Relay Runs cannot strand this one: it re-decides from the
    /// pool count.
    @Test("a topped-up pool sends the run back to deciding")
    func printingReturnsToStockingOnceThePoolIsUp() {
        let directive = restockRun(step: RestockRun.Step.printing, targets: ["VEGA"])
        let snapshot = world(devices: [hub(), liveRelay("REL0", at: hubLocation), spare("RLY1")])

        #expect(RestockRun().nextAction(directive: directive, world: snapshot)
                == .advanceStep(nextStep: RestockRun.Step.stocking))
    }

    /// While the print is genuinely in flight the run holds still.
    @Test("waiting on a clone holds while the print op is open")
    func printingWaitsWhileTheOpIsOpen() {
        let directive = restockRun(step: RestockRun.Step.printing, targets: ["VEGA"])
        let snapshot = world(
            devices: [hub(), liveRelay("REL0", at: hubLocation)],
            openOperations: openOp("AF1", kind: .print)
        )

        #expect(RestockRun().nextAction(directive: directive, world: snapshot) == .wait)
    }

    /// A print that produced nothing and closed its op leaves the pool short
    /// with nothing to wait for. Re-deciding is the answer either way, which is
    /// what stops a silent never-arriving print from parking this step forever.
    @Test("a print that produced no relay re-decides instead of parking")
    func printingReDecidesWhenNothingArrived() {
        let stale = now.addingTimeInterval(-(RestockRun.printDeadline + 60))
        let directive = restockRun(step: RestockRun.Step.printing, targets: ["VEGA"], stepStartedAt: stale)
        let snapshot = world(devices: [hub(), liveRelay("REL0", at: hubLocation)])

        #expect(RestockRun().nextAction(directive: directive, world: snapshot)
                == .advanceStep(nextStep: RestockRun.Step.stocking))
    }
}
