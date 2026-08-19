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

import API
import Dependencies
import Foundation
import GameDatabase
import GameModels
import GameServices
import GameSession
import SQLiteData
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
    device(code, type: "heaven_vessel", location: location, tags: [Brain.carrierTag.string])
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

/// Theatres derived the same way `WorldSnapshot.read` does — off `devices` and
/// `footprints` alone, each meshed system its own component — so a fixture
/// stocking a printer resolves a theatre exactly as production would.
private func theatres(devices: [Device], footprints: [String: LocationFootprint]) -> [Theatre] {
    let mesh = SalvageTargetPlanner.meshSystems(in: devices)
    let components = Dictionary(uniqueKeysWithValues: mesh.map { ($0, $0) })
    return TheatreRegistry.recognise(
        devices: devices, pins: [], records: [], meshSystems: mesh,
        components: components, stockByLocation: footprints.mapValues(\.resources)
    )
}

private func world(
    devices: [Device],
    openOperations: [String: GameModels.Operation] = [:],
    footprints: [String: LocationFootprint]? = nil,
    at instant: Date = now
) -> WorldSnapshot {
    let resolvedFootprints = footprints ?? healthyCensus()
    return WorldSnapshot(
        devices: Dictionary(devices.map { ($0.deviceCode, $0) }, uniquingKeysWith: { _, last in last }),
        openOperations: openOperations, log: [], dispatchedOperations: [:],
        systems: [:], siteAssays: [:], footprints: resolvedFootprints,
        theatres: theatres(devices: devices, footprints: resolvedFootprints),
        peers: [], now: instant
    )
}

private func openOp(
    _ entity: String, kind: OperationKind, directiveID: String? = nil
) -> [String: GameModels.Operation] {
    [entity: GameModels.Operation(
        id: "OP-1", entityCode: entity, kind: kind.rawValue, status: .active,
        source: .poll, startedAt: now, completesAt: nil, lastConfirmedAt: now, detail: .object([:]),
        directiveID: directiveID
    )]
}

/// `theatreDepot` defaults to the file's canonical hub so a fixture that
/// recognises one there resolves it without every call site stamping it.
private func relayRun(
    step: String,
    carrier code: String = "V1",
    returnToOrigin: Bool,
    target: String = "VEGA",
    stepStartedAt: Date = Date(timeIntervalSince1970: 9_900),
    theatreDepot: String? = hubLocation
) -> Directive {
    Directive(
        id: "D1", kind: .relayRun, status: .running, deviceCode: code,
        controllerCode: nil, roamCentre: nil, fleetTag: nil, sourceRelayCode: nil,
        targets: [target], targetIndex: 0, step: step, stepStartedAt: stepStartedAt,
        returnToOrigin: returnToOrigin, originDesignation: hubSystem, attentionReason: nil,
        createdAt: Date(timeIntervalSince1970: 9_000), updatedAt: now, theatreDepot: theatreDepot
    )
}

private func restockRun(
    step: String = RestockRun.Step.stocking.rawValue,
    hub code: String = "AF1",
    targets: [String],
    stepStartedAt: Date = Date(timeIntervalSince1970: 9_900),
    theatreDepot: String? = hubLocation
) -> Directive {
    Directive(
        id: "R1", kind: .restockRun, status: .running, deviceCode: code,
        controllerCode: nil, roamCentre: nil, fleetTag: nil, sourceRelayCode: nil,
        targets: targets, targetIndex: 0, step: step, stepStartedAt: stepStartedAt,
        returnToOrigin: false, originDesignation: hubSystem, attentionReason: nil,
        createdAt: Date(timeIntervalSince1970: 9_000), updatedAt: now, theatreDepot: theatreDepot
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
        let directive = relayRun(step: RelayRun.Step.settling.rawValue, returnToOrigin: true)
        let snapshot = world(devices: [
            carrier(location: "VEGA-1-L4"), hub(), liveRelay("REL0", at: hubLocation),
            liveRelay("RLY1", at: "VEGA-1-L4"),
        ])

        #expect(RelayRun().nextAction(directive: directive, world: snapshot)
                == .advanceStep(nextStep: RelayRun.Step.returning.rawValue))
    }

    /// …and ONLY when it was asked. `returnToOrigin` is a per-directive
    /// instruction, not a policy baked into the machine: an operator-launched
    /// run that deliberately chains onward must still be able to.
    @Test("a run that was not asked to come home finishes where it stands")
    func settlingIsDoneWithoutReturnToOrigin() {
        let directive = relayRun(step: RelayRun.Step.settling.rawValue, returnToOrigin: false)
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
        let directive = relayRun(step: RelayRun.Step.returning.rawValue, returnToOrigin: true)
        let snapshot = world(devices: [
            carrier(location: "VEGA-1-L4"), hub(), liveRelay("REL0", at: hubLocation),
        ])

        let action = RelayRun().nextAction(directive: directive, world: snapshot)

        #expect(action == .dispatch(
            kind: .travel, deviceCode: "V1",
            params: CommandParams(destination: hubLocation),
            nextStep: RelayRun.Step.returning.rawValue
        ))
        #expect(action != .dispatch(
            kind: .travel, deviceCode: "V1",
            params: CommandParams(destination: directive.originDesignation),
            nextStep: RelayRun.Step.returning.rawValue
        ), "the remembered origin is the lossy projection this must not use")
    }

    /// A carrier that never left, or that has arrived, is finished — no command
    /// at all. Mirrors `SurveyRun.returnHome`'s guard.
    @Test("a carrier already standing at the hub skips the leg")
    func alreadyHomeIsDone() {
        let directive = relayRun(step: RelayRun.Step.returning.rawValue, returnToOrigin: true)
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
        let directive = relayRun(step: RelayRun.Step.returning.rawValue, returnToOrigin: true)
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
        let directive = relayRun(step: RelayRun.Step.returning.rawValue, returnToOrigin: true)
        // The printer is present but its location holds NO stock, so it is not a
        // hub — the recognition rule fixed in `d4d46ea`.
        let snapshot = world(
            devices: [carrier(location: "VEGA-1-L4"), hub(), liveRelay("REL0", at: hubLocation)],
            footprints: census(0)
        )

        #expect(RelayRun().nextAction(directive: directive, world: snapshot) == .done)
    }
}

// MARK: - The theatre seam

@Suite("Theatre resolution — one rule, every reader")
struct HubRecognitionSeamTests {

    /// `WorldView.read` and `WorldSnapshot.read` are two INDEPENDENT
    /// `TheatreRegistry.recognise` calls over the same tables — a fixture
    /// built by hand from one shared theatre list cannot exercise that seam.
    @Test("for each directive, WorldView.read and WorldSnapshot.read name the same depot")
    func bothReadPathsAgree() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Device.insert { hub() }.execute(db)
            try Device.insert { liveRelay("REL0", at: hubLocation) }.execute(db)
            try Device.insert { carrier(location: hubLocation) }.execute(db)
            try LocationFootprint.insert { census(
                BrainCeiling.aggregateSpendFloor * 2, at: hubLocation
            )[hubLocation]! }.execute(db)
            // Off any candidate depot: in `WorldSnapshot`'s whole-table read
            // but not `WorldView`'s narrowed query — a real read difference.
            try LocationFootprint.insert {
                LocationFootprint(
                    location: "ELSEWHERE-9", devices: 0, resources: 999_999,
                    resourceSites: 0, locationEvents: 0, replicants: 0, fetchedAt: now
                )
            }.execute(db)
        }

        let view = try await database.read { db in try WorldView.read(from: db, now: now) }

        let directives = [
            relayRun(step: RelayRun.Step.returning.rawValue, returnToOrigin: true, theatreDepot: hubLocation),
            relayRun(step: RelayRun.Step.returning.rawValue, returnToOrigin: true, theatreDepot: nil),
            relayRun(step: RelayRun.Step.returning.rawValue, returnToOrigin: true, theatreDepot: "GONE-BELT-1"),
        ]

        for directive in directives {
            let snapshot = try await WorldSnapshot.read(from: database, now: now, directive: directive)
            let fromMission = snapshot.theatreDepot(for: directive)
            let fromBrain = view.theatres.first { $0.depot == directive.theatreDepot && $0.isOperational }?.depot
            #expect(fromMission == fromBrain, "theatreDepot \(directive.theatreDepot ?? "nil"): mission vs brain")
        }
        // The positive case is worth pinning to a value, not just to agreement.
        let home = try await WorldSnapshot.read(from: database, now: now, directive: directives[0])
        #expect(home.theatreDepot(for: directives[0]) == hubLocation)
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
            nextStep: RestockRun.Step.printing.rawValue
        ))
    }

    /// The headline case's own world, on an unrecognised step: `stocking`
    /// would print here, so a fallback to it cannot pass this alongside
    /// `.wait`.
    @Test("an unknown step waits rather than falling through to stocking")
    func unknownStepWaits() {
        let directive = restockRun(step: "not-a-real-step", targets: ["VEGA", "ALTAIR"])
        let snapshot = world(devices: [hub(), liveRelay("REL0", at: hubLocation)])

        #expect(RestockRun().nextAction(directive: directive, world: snapshot) == .wait)
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

    /// **A stale census buys its own refresh.** Nothing polls
    /// `LocationFootprint` — `refreshFootprint()` has two production callers,
    /// a mission's own action and the Locations screen — so a restock that
    /// merely waited would print only inside the ≤60s window after some other
    /// mission happened to refresh, and be inert the rest of the time.
    @Test("a stale census is refreshed rather than waited out")
    func staleCensusBuysARefresh() {
        let directive = restockRun(targets: ["VEGA", "ALTAIR"])
        let stale = now.addingTimeInterval(-(RelayRun.pollInterval + 60))
        let snapshot = world(
            devices: [hub(), liveRelay("REL0", at: hubLocation)],
            footprints: healthyCensus(fetchedAt: stale)
        )

        #expect(RestockRun().nextAction(directive: directive, world: snapshot)
                == .refreshFootprint(nextStep: RestockRun.Step.stocking.rawValue, thenStall: nil))
    }

    /// **`thenStall` is nil, and that is a contract rather than an omission.** A
    /// top-up nothing is waiting on must never put a human in the loop, so a
    /// census that stays unreadable degrades to idle-calm. `RelayRun.acquire`
    /// passes a REAL reason on the same action for the opposite reason — there
    /// an irreversible resource spend has a carrier standing in front of it.
    @Test("the refresh restock asks for can never escalate to a human")
    func theRefreshNeverEscalates() {
        let directive = restockRun(targets: ["VEGA"])
        let stale = now.addingTimeInterval(-(RelayRun.pollInterval + 60))
        let snapshot = world(
            devices: [hub(), liveRelay("REL0", at: hubLocation)],
            footprints: healthyCensus(fetchedAt: stale)
        )

        guard case let .refreshFootprint(_, thenStall) =
                RestockRun().nextAction(directive: directive, world: snapshot) else {
            Issue.record("expected a footprint refresh")
            return
        }
        #expect(thenStall == nil)
    }

    /// **The read is bought only by a run that actually wants to print.** With
    /// demand met the stale census is never even consulted, so a converged
    /// fleet spends nothing — the bound that makes this affordable is that cost
    /// tracks wanting stock, not existing.
    @Test("a stale census costs nothing when there is nothing to print for", arguments: [
        ("demand met", [String]()),
    ])
    func staleCensusCostsNothingWithoutDemand(_ label: String, targets: [String]) {
        let directive = restockRun(targets: targets)
        let stale = now.addingTimeInterval(-(RelayRun.pollInterval + 60))
        let snapshot = world(
            devices: [hub(), liveRelay("REL0", at: hubLocation)],
            footprints: healthyCensus(fetchedAt: stale)
        )

        #expect(RestockRun().nextAction(directive: directive, world: snapshot) == .wait,
                "\(label) must not buy a census read")
    }

    /// …and neither does a run whose print is already in flight.
    @Test("a stale census costs nothing while a print is already running")
    func staleCensusCostsNothingWithAPrintInFlight() {
        let directive = restockRun(targets: ["VEGA", "ALTAIR"])
        let stale = now.addingTimeInterval(-(RelayRun.pollInterval + 60))
        let snapshot = world(
            devices: [hub(), liveRelay("REL0", at: hubLocation)],
            openOperations: openOp("AF1", kind: .print),
            footprints: healthyCensus(fetchedAt: stale)
        )

        #expect(RestockRun().nextAction(directive: directive, world: snapshot) == .wait)
    }

    /// A refresh that SUCCEEDS but still does not list the hub is positive
    /// evidence, not another refresh: the table-wide gate is satisfied, so it
    /// falls through to the reserve veto, which fails closed on a missing row.
    /// This is what keeps the request from self-looping — the per-location
    /// version of this gate had to be removed for exactly that reason.
    @Test("a fresh census that omits the hub falls through to the veto, not to another read")
    func freshCensusWithoutTheHubVetoes() {
        let directive = restockRun(targets: ["VEGA", "ALTAIR"])
        let snapshot = world(
            devices: [hub(), liveRelay("REL0", at: hubLocation)],
            footprints: census(BrainCeiling.aggregateSpendFloor * 2, at: "SOMEWHERE-ELSE")
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
        let directive = restockRun(step: RestockRun.Step.printing.rawValue, targets: ["VEGA"])
        let snapshot = world(devices: [hub(), liveRelay("REL0", at: hubLocation), spare("RLY1")])

        #expect(RestockRun().nextAction(directive: directive, world: snapshot)
                == .advanceStep(nextStep: RestockRun.Step.stocking.rawValue))
    }

    /// While the print is genuinely in flight the run holds still.
    @Test("waiting on a clone holds while the print op is open")
    func printingWaitsWhileTheOpIsOpen() {
        let directive = restockRun(step: RestockRun.Step.printing.rawValue, targets: ["VEGA"])
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
        let stale = now.addingTimeInterval(-(PrintJob.deadline + 60))
        let directive = restockRun(step: RestockRun.Step.printing.rawValue, targets: ["VEGA"], stepStartedAt: stale)
        let snapshot = world(devices: [hub(), liveRelay("REL0", at: hubLocation)])

        #expect(RestockRun().nextAction(directive: directive, world: snapshot)
                == .advanceStep(nextStep: RestockRun.Step.stocking.rawValue))
    }

    /// Owner-scoped: a co-tenant's print at the hub is invisible to this
    /// guard, so it must never block starting this run's own.
    @Test("a co-tenant's print at the hub does not block starting our own")
    func coTenantPrintDoesNotBlockDispatch() {
        let directive = restockRun(targets: ["VEGA", "ALTAIR"])
        let snapshot = world(
            devices: [hub(), liveRelay("REL0", at: hubLocation)],
            openOperations: openOp("AF1", kind: .print, directiveID: "OTHER")
        )

        #expect(RestockRun().nextAction(directive: directive, world: snapshot) == .dispatch(
            kind: .print, deviceCode: "AF1",
            params: CommandParams(deviceType: RelayRun.relayDeviceType),
            nextStep: RestockRun.Step.printing.rawValue
        ))
    }

    /// Our own print, correctly identified as ours through the owner scope,
    /// still holds the step — owner-scoping must not make the guard toothless.
    @Test("waiting on the clone holds while OUR OWN print op is open")
    func printingWaitsOnOwnOp() {
        let directive = restockRun(step: RestockRun.Step.printing.rawValue, targets: ["VEGA"])
        let snapshot = world(
            devices: [hub(), liveRelay("REL0", at: hubLocation)],
            openOperations: openOp("AF1", kind: .print, directiveID: directive.id)
        )

        #expect(RestockRun().nextAction(directive: directive, world: snapshot) == .wait)
    }

    /// **The load-bearing case.** A co-tenant's op standing open at the hub
    /// must never extend OUR deadline — checking the deadline above the guard
    /// is what makes that true regardless of who else holds the bench.
    @Test("a co-tenant's print past the deadline does not extend the wait")
    func coTenantPrintDoesNotExtendDeadline() {
        let stale = now.addingTimeInterval(-(PrintJob.deadline + 60))
        let directive = restockRun(step: RestockRun.Step.printing.rawValue, targets: ["VEGA"], stepStartedAt: stale)
        let snapshot = world(
            devices: [hub(), liveRelay("REL0", at: hubLocation)],
            openOperations: openOp("AF1", kind: .print, directiveID: "OTHER")
        )

        #expect(RestockRun().nextAction(directive: directive, world: snapshot)
                == .advanceStep(nextStep: RestockRun.Step.stocking.rawValue))
    }

    @Test func stepVocabularyIsFrozen() {
        #expect(RestockRun.Step.allCases.map(\.rawValue) == ["stocking", "printing"])
    }
}

// MARK: - Restock through the real engine

/// **The census refresh, driven through `DirectiveEngineCore` rather than
/// asserted on the pure mission function.**
///
/// `brain-relay-reserve-floor` round 4 records exactly why this suite has to
/// exist: every `RelayRun` test was a pure-function table, NO test drove the
/// machine through the real engine, and the bug that shipped was in the
/// engine's re-ask collapse rather than in the machine. Restock now asks for a
/// census read on a step that names ITSELF as `nextStep`, which is the shape
/// that has already caused one unbounded API hammer in this file's history — so
/// the bound gets proven where it actually lives.
@Suite("Restock Run — the census refresh at the engine", .serialized)
struct RestockEngineTests {

    private static let instant = Date(timeIntervalSince1970: 100_000)

    private func seed(
        _ database: any DatabaseWriter,
        censusFetchedAt: Date?,
        targets: [String] = ["VEGA", "ALTAIR"]
    ) async throws {
        try await database.write { db in
            try Directive.insert {
                Directive(
                    id: "R1", kind: .restockRun, status: .running, deviceCode: "AF1",
                    controllerCode: nil, roamCentre: nil, fleetTag: nil, sourceRelayCode: nil,
                    targets: targets, targetIndex: 0,
                    step: RestockRun.Step.stocking.rawValue,
                    stepStartedAt: Self.instant, returnToOrigin: false,
                    originDesignation: hubSystem, attentionReason: nil,
                    createdAt: Self.instant, updatedAt: Self.instant
                )
            }.execute(db)
            try Device.insert { hub() }.execute(db)
            try Device.insert { liveRelay("REL0", at: hubLocation) }.execute(db)
            if let censusFetchedAt {
                try LocationFootprint.insert {
                    LocationFootprint(
                        location: hubLocation, devices: 1,
                        resources: BrainCeiling.aggregateSpendFloor * 2,
                        resourceSites: 0, locationEvents: 0, replicants: 0,
                        fetchedAt: censusFetchedAt
                    )
                }.execute(db)
            }
        }
    }

    /// **Termination.** The refresh fails outright and keeps failing — an
    /// offline network, an expired token, sustained 5xx. The evaluation must
    /// buy at most ONE census round (`reAsk`'s `paid` set) and then stop, and
    /// the run must be left calm: still running, no attention reason, no
    /// operator summoned for a top-up nobody is waiting on.
    @Test func aPersistentlyFailingRefreshCostsOneReadAndNeverEscalates() async throws {
        let database = try GameDatabase.bootstrap()
        try await seed(database, censusFetchedAt: Self.instant.addingTimeInterval(-3_600))
        struct Boom: Error {}
        let attempts = LockIsolated(0)

        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Self.instant)
            $0.uuid = .incrementing
            $0.locationsClient.footprint = {
                attempts.withValue { $0 += 1 }
                throw Boom()
            }
        } operation: {
            let core = DirectiveEngineCore(machines: [RestockRun()], tick: .seconds(5))
            await core.evaluateOnce(directiveID: "R1")
        }

        #expect(attempts.value == 1, "one census round per evaluation, however stale the reading stays")
        let row = try #require(
            await database.read { db in try Directive.where { $0.id.eq("R1") }.fetchOne(db) }
        )
        #expect(row.status == .running, "a top-up that cannot read the stockpile is not a halt")
        #expect(row.attentionReason == nil, "…and never asks a human to look at it")
        #expect(row.step == RestockRun.Step.stocking.rawValue, "it re-decides next tick rather than parking")
    }

    /// The point of the whole change: with the read landing, the run gets from
    /// a stale census to an actual print inside ONE evaluation. Before this it
    /// waited, and — since nothing polls `LocationFootprint` — waited forever.
    @Test func aSuccessfulRefreshTurnsAStaleCensusIntoAPrint() async throws {
        let database = try GameDatabase.bootstrap()
        try await seed(database, censusFetchedAt: Self.instant.addingTimeInterval(-3_600))
        let attempts = LockIsolated(0)
        let printed = LockIsolated<[String]>([])

        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Self.instant)
            $0.uuid = .incrementing
            $0.commandGovernor = .liveValue
            $0.gameClient = {
                var client = GameClient.testValue
                client.budget = { _ in RateLimitGovernor.Snapshot(limit: 60, remaining: 60, resetAt: nil) }
                return client
            }()
            $0.commandClient = {
                var client = CommandClient.testValue
                let body: @Sendable (OperationKind, String, CommandParams) async -> CommandOutcome = { kind, deviceCode, _ in
                    printed.withValue { $0.append("\(kind.rawValue)→\(deviceCode)") }
                    return .accepted(operationID: "OP-1")
                }
                client.dispatch = body
                client.dispatchOwned = { kind, deviceCode, params, _ in await body(kind, deviceCode, params) }
                return client
            }()
            // The real `refreshFootprint()` persistence runs on top of this, so
            // the `fetchedAt` stamp that satisfies the gate is written by
            // production code rather than by the test.
            $0.locationsClient.footprint = {
                attempts.withValue { $0 += 1 }
                return [hubLocation: LocationCounts(
                    locationEvents: 0, devices: 1, resourceSites: 0,
                    resources: BrainCeiling.aggregateSpendFloor * 2, replicants: 0
                )]
            }
        } operation: {
            let core = DirectiveEngineCore(machines: [RestockRun()], tick: .seconds(5))
            await core.evaluateOnce(directiveID: "R1")
        }

        #expect(attempts.value == 1, "one read bought the print")
        #expect(printed.value == ["print→AF1"], "and the print actually went out in the same evaluation")
        let row = try #require(
            await database.read { db in try Directive.where { $0.id.eq("R1") }.fetchOne(db) }
        )
        #expect(row.step == RestockRun.Step.printing.rawValue)
        #expect(row.attentionReason == nil)
    }

    /// **A converged fleet spends nothing.** Demand met, so the stale census is
    /// never consulted and no read is bought — the bound that makes buying the
    /// read affordable at all is that the cost tracks wanting stock rather than
    /// existing.
    @Test func aRunWithNoDemandBuysNoCensusRead() async throws {
        let database = try GameDatabase.bootstrap()
        try await seed(
            database, censusFetchedAt: Self.instant.addingTimeInterval(-3_600), targets: []
        )
        let attempts = LockIsolated(0)

        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Self.instant)
            $0.uuid = .incrementing
            $0.locationsClient.footprint = {
                attempts.withValue { $0 += 1 }
                return [:]
            }
        } operation: {
            let core = DirectiveEngineCore(machines: [RestockRun()], tick: .seconds(5))
            await core.evaluateOnce(directiveID: "R1")
        }

        #expect(attempts.value == 0, "nothing to print for means nothing to read for")
    }
}
