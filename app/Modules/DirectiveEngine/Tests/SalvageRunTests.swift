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
    currentDirective: String? = nil,
    currentDirectiveConfig: [String: JSONValue]? = nil,
    currentDirectiveStatus: String = "active",
    tags: [String] = [],
    updatedAt: Date = fixtureNow,
    arrivesAt: Date? = nil
) -> Device {
    var detail: [String: JSONValue] = [:]
    if let arrivesAt {
        // A drone flying home under recall — a single in-system hop, so both
        // timing fields agree. Gives the row an `activityDeadline`.
        detail["travel"] = .object([
            "arrives_at": .string(arrivesAt.ISO8601Format()),
            "final_arrives_at": .string(arrivesAt.ISO8601Format()),
        ])
    }
    if !controlled.isEmpty {
        detail["controlled_devices"] = .array(controlled.map { drone in
            .object(["device_code": .string(drone), "device_type": .string("mining_drone")])
        })
    }
    if !directives.isEmpty {
        detail["available_directives"] = .array(directives.map(JSONValue.string))
    }
    if let currentDirective {
        detail["ami_directive"] = .object([
            "name": .string(currentDirective),
            "config": .object(currentDirectiveConfig ?? [:]),
        ])
        detail["ami_directive_status"] = .string(currentDirectiveStatus)
    }
    return Device(
        deviceCode: code, deviceType: type, replicantCode: "R1",
        status: arrivesAt == nil ? status : "travelling", location: location, locationName: nil,
        operationalCapacity: 100, queueSize: 0,
        stowedInDeviceCode: stowedIn, controllerDeviceCode: controlledBy,
        attachedToDeviceCode: nil, createdAt: Date(timeIntervalSince1970: 0),
        availableCommands: [], features: features, tags: tags, detail: .object(detail),
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

/// The fully-staged fleet — vessel, controller, drone, relay — all sharing one
/// `updatedAt`, so the freshness tests can age the whole fleet with a single
/// parameter. Mirrors `SurveyRunTests.stagedFleet`.
private func stagedFleet(updatedAt: Date = fixtureNow) -> [Device] {
    [
        device("VESSEL", type: "heaven_vessel", updatedAt: updatedAt),
        device("CTRL", type: "ami_mining_controller", stowedIn: "VESSEL",
               controlled: ["DRONE"], directives: ["gather_salvage"], updatedAt: updatedAt),
        device("DRONE", type: "mining_drone", stowedIn: "VESSEL", controlledBy: "CTRL", updatedAt: updatedAt),
        device("RELAY", type: "ftl_relay", stowedIn: "VESSEL", features: ["relay"], updatedAt: updatedAt),
    ]
}

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
    dispatchedOperations: [String: GameModels.Operation] = [:],
    systems: [String: StarSystem] = [:],
    siteAssays: [String: [String: Double]] = [:],
    now: Date = fixtureNow
) -> WorldSnapshot {
    WorldSnapshot(
        devices: Dictionary(devices.map { ($0.deviceCode, $0) }, uniquingKeysWith: { _, last in last }),
        openOperations: openOperations, log: log, dispatchedOperations: dispatchedOperations,
        systems: systems, siteAssays: siteAssays, now: now
    )
}

/// A `.stepStarted` timeline entry — the row `DirectiveExecutor.move` writes
/// on every step transition.
private func stepStarted(_ step: String, at occurredAt: Date) -> DirectiveLogEntry {
    DirectiveLogEntry(
        id: "S-\(step)-\(occurredAt.timeIntervalSince1970)", directiveID: "D1",
        deviceCode: nil, kind: .stepStarted, summary: "Step: \(step)", step: step,
        operationID: nil, eventID: nil, occurredAt: occurredAt
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

// MARK: - Registration

@Suite("Salvage Run — registration")
struct SalvageRunRegistrationTests {
    /// Until this passes the engine leaves every `salvageRun` row completely
    /// alone — no writes at all (see `MissionRegistry`'s doc comment). This is
    /// the one-line edit that turns the whole run live.
    @Test func isRegisteredWithTheEngine() {
        #expect(MissionRegistry.machine(for: .salvageRun) is SalvageRun)
        #expect(MissionRegistry.firstStep(for: .salvageRun) == SalvageRun.Step.preflight)
    }
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

    /// The inverse of the routing test above, carried forward from Task 5's
    /// review: an already-meshed target needs no relay, so a vessel with none
    /// aboard must still depart rather than detour to base. Without this test
    /// an inverted `!meshed` in the relay guard would pass every other case in
    /// this suite while quietly sending every meshed target home empty-handed.
    @Test func proceedsWithNoRelayAboardWhenTheTargetIsAlreadyMeshed() {
        let up = device("R", location: "TOSLIT-3-L4", features: ["relay"], status: "relaying")
        let snapshot = world(devices: [vessel, controller, drone, up]) // no relay aboard
        #expect(SalvageRun().nextAction(directive: running(step: "preflight"), world: snapshot)
                == .assignController(deviceCode: "CTRL", nextStep: "travelling"))
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

    /// The WIRE READ must send a tag the server actually knows: `GET
    /// devices/tags/auto:salvage:AINALRAM-BELT-1` answers zero devices live,
    /// while `auto:salvage` answers the real fleet.
    @Test func refreshesUsingTheRootTagNotThePerTheatreOne() {
        let snapshot = world(devices: [vessel])
        let directive = running(step: "preflight", fleetTag: "auto:salvage:AINALRAM-BELT-1")
        #expect(SalvageRun().nextAction(directive: directive, world: snapshot)
                == .refreshFleet(tag: "auto:salvage", thenStall: .noMiningControllerAboard))
    }
}

// MARK: - Staging freshness

/// A POSITIVE staging finding is only as trustworthy as the rows under it.
///
/// Mining drones are AMI-adopted the same event-silent way survey drones are,
/// so a drone abandoned elsewhere keeps its local "still aboard" claim until
/// something reads it — the direction that actually loses a fleet (six
/// drones, POLARISUM, 2026-07-26). This mirrors `SurveyRunStagingFreshnessTests`.
@Suite("Salvage Run — staging freshness")
struct SalvageRunStagingFreshnessTests {
    /// Rows stale past `stagingFreshness` earn a tag read before the vessel is
    /// committed to departure, rather than trusting a "still aboard" that could
    /// no longer be true.
    @Test func staleStagingRowsEarnAReadBeforeTheyAreBelieved() {
        let stale = fixtureNow.addingTimeInterval(-SalvageRun.stagingFreshness - 1)
        let snapshot = world(devices: stagedFleet(updatedAt: stale))
        #expect(SalvageRun().nextAction(directive: running(step: "preflight"), world: snapshot)
                == .refreshFleet(tag: "auto:salvage", thenStall: .unreachableDevice))
    }

    /// Freshly synced rows are believed without a read — the demand is paid
    /// only when it could otherwise change the answer, so the happy path costs
    /// nothing.
    @Test func freshStagingRowsAreTrustedWithoutARead() {
        let snapshot = world(devices: stagedFleet())
        #expect(SalvageRun().nextAction(directive: running(step: "preflight"), world: snapshot)
                == .assignController(deviceCode: "CTRL", nextStep: "travelling"))
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
    /// the run skips that step and puts its service bots into the system.
    @Test func skipsStraightToTheBotDeployWhenTheSystemIsAlreadyMeshed() {
        let arrived = device("VESSEL", type: "heaven_vessel", location: "TOSLIT-3")
        let here = device("R", location: "TOSLIT-3-L4", features: ["relay"], status: "relaying")
        let snapshot = world(devices: [arrived, controller, drone, relay, here])
        #expect(SalvageRun().nextAction(directive: running(step: "travelling"), world: snapshot)
                == .advanceStep(nextStep: "deployingBots"))
    }

}

// MARK: - Unrecognised step

@Suite("Salvage Run — unrecognised step")
struct SalvageRunUnknownStepTests {
    /// A genuinely unknown step — one outside this mission's whole vocabulary
    /// — must never dispatch: it waits, same contract as `SurveyRun`. (Every
    /// named step in `SalvageRun.Step` is wired up as of Task 8, so this can
    /// no longer be exercised via a real-but-unimplemented step name; a bogus
    /// string is what's left to hit the `default:` arm.)
    @Test func waitsOnAStepNotYetImplemented() {
        let snapshot = world(devices: [vessel, controller, drone, relay])
        #expect(SalvageRun().nextAction(directive: running(step: "not-a-real-step"), world: snapshot) == .wait)
    }
}

// MARK: - Emplacement fixtures

/// The moment `SalvageRunEmplacementTests` treats as "now" — aliases
/// `fixtureNow` under the shorter name the deadline tests read most naturally.
private let now = fixtureNow

/// TOSLIT, with one planet carrying a Lagrange point. Lagrange points hang off
/// each PLANET (`Planet.lagrange: [SpecialSite]`) — there is no
/// `StarSystem.lagrangePoints`.
private let toslit = StarSystem(
    designation: "TOSLIT",
    planets: [
        Planet(designation: "TOSLIT-3", lagrange: [
            SpecialSite(designation: "TOSLIT-3-L4", kind: .lagrange),
        ]),
    ]
)

/// TOSLIT with NO planets at all — the only genuinely unemplaceable case now
/// that `lagrangePoint(in:)` synthesises an L4 from the lowest planet
/// designation when the entry point isn't one. A system WITH a planet always
/// has a synthesisable point, so "no Lagrange point" no longer describes a
/// system that merely lacks a `Planet.lagrange` array.
private let toslitWithNoPlanets = StarSystem(designation: "TOSLIT", planets: [])

// MARK: - Lagrange point resolution

/// `lagrangePoint(in:)` is a pure static function, tested directly rather than
/// only through `emplace`'s dispatch shape.
@Suite("Salvage Run — lagrange point resolution")
struct SalvageRunLagrangePointTests {
    /// The entry point IS an L4 — confirmed live across every system
    /// (`<planet>-N-L4`) — so it is preferred even when a planet is present
    /// and could otherwise supply a synthesised one.
    @Test func prefersTheEntryPointWhenItIsAnL4() {
        let sys = StarSystem(
            designation: "TOSLIT", entryPoint: "TOSLIT-6-L4",
            planets: [Planet(designation: "TOSLIT-3")]
        )
        #expect(SalvageRun.lagrangePoint(in: sys) == "TOSLIT-6-L4")
    }

    /// No entry point at all: every planet has an L4 by construction, so one
    /// is synthesised from the LOWEST planet designation for a reproducible
    /// pick.
    @Test func synthesisesTheLowestPlanetsL4WhenNoEntryPoint() {
        let sys = StarSystem(
            designation: "TOSLIT", entryPoint: nil,
            planets: [Planet(designation: "TOSLIT-6"), Planet(designation: "TOSLIT-3")]
        )
        #expect(SalvageRun.lagrangePoint(in: sys) == "TOSLIT-3-L4")
    }

    /// An entry point IS present but is not an L4 (a station, say) — still
    /// synthesises from the lowest planet rather than trusting a non-L4 point.
    @Test func synthesisesWhenTheEntryPointIsNotAnL4() {
        let sys = StarSystem(
            designation: "TOSLIT", entryPoint: "TOSLIT-STATION",
            planets: [Planet(designation: "TOSLIT-3")]
        )
        #expect(SalvageRun.lagrangePoint(in: sys) == "TOSLIT-3-L4")
    }

    /// No planets at all: the one genuinely unemplaceable case.
    @Test func returnsNilWhenTheSystemHasNoPlanets() {
        let sys = StarSystem(designation: "TOSLIT", planets: [])
        #expect(SalvageRun.lagrangePoint(in: sys) == nil)
    }
}

// MARK: - Emplacement

// MARK: - Mining fixtures

/// The vessel already at the target system, ready to configure and launch —
/// distinct from `vessel` (not yet departed) and `arrived`-style locals used
/// elsewhere in this file, which don't carry a `TOSLIT` location.
private let atSystem = device("VESSEL", type: "heaven_vessel", location: "TOSLIT-3")

/// TOSLIT with two live salvage bodies on two different planets: a moon of
/// TOSLIT-3 holding a modest site, and a moon of TOSLIT-6 holding a richer
/// one. Both sites are roster-sourced (empty `remainingPct`) — the COMMON
/// state per the ranking's own doc comment — so telling them apart requires
/// `miningToslitAssays` below, not the site's own percentages.
private let miningToslit = StarSystem(
    designation: "TOSLIT",
    planets: [
        Planet(designation: "TOSLIT-3", moons: [
            Moon(designation: "TOSLIT-3-2", salvage: [
                SalvageSite(designation: "TOSLIT-3-2-SAL-1", resourcesAvailable: ["ore"]),
            ]),
        ]),
        Planet(designation: "TOSLIT-6", moons: [
            Moon(designation: "TOSLIT-6-5", salvage: [
                SalvageSite(designation: "TOSLIT-6-5-SAL-1", resourcesAvailable: ["ore"]),
            ]),
        ]),
    ]
)

/// Stored assay totals for `miningToslit`'s two sites — TOSLIT-6-5-SAL-1 (500)
/// outweighs TOSLIT-3-2-SAL-1 (100), so `nextBody` must pick TOSLIT-6-5. Both
/// sites carry no live percentage, so this ranking exercises the
/// `discoveredTotal` fallback specifically, not `unitsRemaining`.
private let miningToslitAssays: [String: [String: Double]] = [
    "TOSLIT-3-2-SAL-1": ["ore": 100],
    "TOSLIT-6-5-SAL-1": ["ore": 500],
]

/// TOSLIT with no salvage anywhere — drained, or never held any to begin
/// with. Used by the `verifying` tests, distinct from `miningToslit` (which
/// still holds live bodies) — the pair mirrors `configure`'s own
/// finished-vs-live distinction one step over.
private let drainedToslit = StarSystem(designation: "TOSLIT", planets: [])

/// `miningToslit` after its richest body has drained: TOSLIT-6-5 is gone and
/// only TOSLIT-3-2 is still live. What honest progress through the mining loop
/// looks like from `verifying`'s point of view.
private let partlyDrainedToslit = StarSystem(
    designation: "TOSLIT",
    planets: [
        Planet(designation: "TOSLIT-3", moons: [
            Moon(designation: "TOSLIT-3-2", salvage: [
                SalvageSite(designation: "TOSLIT-3-2-SAL-1", resourcesAvailable: ["ore"]),
            ]),
        ]),
        Planet(designation: "TOSLIT-6"),
    ]
)

private func completion(at occurredAt: Date) -> DirectiveLogEntry {
    DirectiveLogEntry(
        id: "L1", directiveID: "D1", deviceCode: "CTRL", kind: .directiveCompleted,
        summary: "Gather Salvage completed at TOSLIT", step: "awaiting",
        operationID: nil, eventID: "E1", occurredAt: occurredAt
    )
}

private func emptyLaunch(at occurredAt: Date) -> DirectiveLogEntry {
    DirectiveLogEntry(
        id: "L9", directiveID: "D1", deviceCode: "CTRL", kind: .launchDeployedNothing,
        summary: "Launch deployed no devices", step: "awaiting",
        operationID: nil, eventID: "E9", occurredAt: occurredAt
    )
}

// MARK: - Positioning

/// The vessel — not the drones — travels to each salvage body, so the drones
/// deploy locally instead of ferrying from a parked vessel. Keyed off
/// `nextBody` (deterministic) rather than the controller's in-force config,
/// which is written only on command-confirm and would name the previous body
/// right after `configure` re-issues.
@Suite("Salvage Run — positioning")
struct SalvageRunPositioningTests {
    /// The vessel is in the system but not yet at the richest body: fly it there.
    @Test func travelsTheVesselToTheRichestBody() {
        let world = world(devices: [atSystem, controller, drone],
                          systems: ["TOSLIT": miningToslit], siteAssays: miningToslitAssays)
        #expect(SalvageRun().nextAction(directive: running(step: "positioning"), world: world)
            == .dispatch(kind: .travel, deviceCode: "VESSEL",
                         params: CommandParams(destination: "TOSLIT-6-5"), nextStep: "positioning"))
    }

    /// Mid-trip is a wait, never a second travel stacked on the one in flight.
    @Test func waitsWhileTheVesselIsUnderway() {
        let world = world(devices: [atSystem, controller, drone],
                          openOperations: ["VESSEL": operation(kind: .travel)],
                          systems: ["TOSLIT": miningToslit], siteAssays: miningToslitAssays)
        #expect(SalvageRun().nextAction(directive: running(step: "positioning"), world: world) == .wait)
    }

    /// Arrived at the body: hand to `configuring` to set the directive and launch
    /// locally.
    @Test func configuresOnceTheVesselIsAtTheBody() {
        let atBody = device("VESSEL", type: "heaven_vessel", location: "TOSLIT-6-5")
        let world = world(devices: [atBody, controller, drone],
                          systems: ["TOSLIT": miningToslit], siteAssays: miningToslitAssays)
        #expect(SalvageRun().nextAction(directive: running(step: "positioning"), world: world)
            == .advanceStep(nextStep: "configuring"))
    }

    /// No live body left in the system: this target is done. `positioning` owns
    /// the first look now, so it inherits `configure`'s finished handling, and
    /// leaving the system routes through the bot recall.
    @Test func recallsTheBotsWhenNoBodyIsLeft() {
        let drained = StarSystem(designation: "TOSLIT", planets: [])
        let world = world(devices: [atSystem, controller, drone], systems: ["TOSLIT": drained])
        #expect(SalvageRun().nextAction(directive: running(step: "positioning"), world: world)
            == .advanceStep(nextStep: "repairing"))
    }

    /// An uncached system blob must NOT read as "nothing to mine" — wait for it,
    /// same backstop as `configure`/`emplace`/`verify`.
    @Test func waitsWhenTheSystemIsntCachedYet() {
        let world = world(devices: [atSystem, controller, drone]) // no "TOSLIT" entry
        #expect(SalvageRun().nextAction(directive: running(step: "positioning"), world: world) == .wait)
    }
}

// MARK: - Mining loop

@Suite("Salvage Run — mining loop")
struct SalvageRunMiningTests {
    /// `unitsRemaining ?? discoveredTotal ?? 0` — the richest body by that
    /// figure, ties broken on designation. Both sites here are in the common
    /// assayed-but-unhydrated state, so this specifically exercises the
    /// `discoveredTotal` fallback, not `unitsRemaining`.
    @Test func configuresGatherSalvageForTheRichestUnworkedBody() {
        let world = world(devices: [atSystem, controller, drone],
                          systems: ["TOSLIT": miningToslit], siteAssays: miningToslitAssays)
        #expect(SalvageRun().nextAction(directive: running(step: "configuring"), world: world)
            == .dispatch(kind: .setDirective, deviceCode: "CTRL",
                         params: CommandParams(directive: "gather_salvage", configuration: [
                             "location": .string("TOSLIT-6-5"), "recall": .bool(true),
                         ]), nextStep: "launching"))
    }

    /// Re-issuing is the default: a leftover `location` from manual use would
    /// silently work the wrong body. Only an exact field-by-field match on
    /// `location` and `recall` skips the dispatch.
    @Test func skipsSetDirectiveWhenTheInForceConfigAlreadyMatches() {
        let configured = device(
            "CTRL", type: "ami_mining_controller", stowedIn: "VESSEL",
            controlled: ["DRONE"], directives: ["gather_salvage"],
            currentDirective: "gather_salvage",
            currentDirectiveConfig: ["location": .string("TOSLIT-6-5"), "recall": .bool(true)]
        )
        let world = world(devices: [atSystem, configured, drone],
                          systems: ["TOSLIT": miningToslit], siteAssays: miningToslitAssays)
        #expect(SalvageRun().nextAction(directive: running(step: "configuring"), world: world)
            == .advanceStep(nextStep: "launching"))
    }

    @Test func reIssuesWhenTheInForceConfigNamesAnotherBody() {
        let wrong = device(
            "CTRL", type: "ami_mining_controller", stowedIn: "VESSEL",
            controlled: ["DRONE"], directives: ["gather_salvage"],
            currentDirective: "gather_salvage",
            currentDirectiveConfig: ["location": .string("TOSLIT-3-2"), "recall": .bool(true)]
        )
        let world = world(devices: [atSystem, wrong, drone],
                          systems: ["TOSLIT": miningToslit], siteAssays: miningToslitAssays)
        guard case .dispatch(_, _, _, let next) = SalvageRun()
            .nextAction(directive: running(step: "configuring"), world: world) else {
            Issue.record("expected a re-issue"); return
        }
        #expect(next == "launching")
    }

    /// Right directive, right body, but paused: `activate` starts it. Re-sending
    /// the name would be a no-op forever, which is what let a paused controller
    /// survive a Retry.
    @Test func activatesAPausedControllerRatherThanResendingItsName() {
        let paused = device(
            "CTRL", type: "ami_mining_controller", stowedIn: "VESSEL",
            controlled: ["DRONE"], directives: ["gather_salvage"],
            currentDirective: "gather_salvage",
            currentDirectiveConfig: ["location": .string("TOSLIT-6-5"), "recall": .bool(true)],
            currentDirectiveStatus: "paused"
        )
        let world = world(devices: [atSystem, paused, drone],
                          systems: ["TOSLIT": miningToslit], siteAssays: miningToslitAssays)
        #expect(SalvageRun().nextAction(directive: running(step: "configuring"), world: world)
            == .dispatch(kind: OperationKind.simple("activate"), deviceCode: "CTRL",
                         params: CommandParams(), nextStep: "launching"))
    }

    @Test func launchesTheController() {
        let world = world(devices: [atSystem, controller, drone],
                          systems: ["TOSLIT": miningToslit], siteAssays: miningToslitAssays)
        #expect(SalvageRun().nextAction(directive: running(step: "launching"), world: world)
            == .dispatch(kind: OperationKind.simple("launch"), deviceCode: "CTRL",
                         params: CommandParams(), nextStep: "awaiting"))
    }

    /// A controller actively mining (`gather_salvage` in force) with a drone
    /// deployed, well past ten minutes: the run WAITS. This is the core
    /// regression — the old blind ten-minute backstop dumped into `verify` here
    /// and false-stalled `dronesNotRecovered` every long cycle.
    @Test func waitsWhileMiningEvenPastTenMinutes() {
        let mining = device(
            "CTRL", type: "ami_mining_controller", stowedIn: "VESSEL",
            controlled: ["DRONE"], directives: ["gather_salvage"],
            currentDirective: "gather_salvage",
            currentDirectiveConfig: ["location": .string("TOSLIT-6-5"), "recall": .bool(true)]
        )
        let deployed = device("DRONE", type: "mining_drone", location: "TOSLIT-6-5", controlledBy: "CTRL")
        let directive = running(step: "awaiting", stepStartedAt: now.addingTimeInterval(-11 * 60))
        let world = world(devices: [atSystem, mining, deployed], now: now)
        #expect(SalvageRun().nextAction(directive: directive, world: world) == .wait)
    }

    /// The reported live defect: a controller whose `gather_salvage` reads
    /// PAUSED holds the directive name, so a name-only check reads it as "still
    /// mining" and reconciles forever. A paused directive never completes, so
    /// the wait must end in a named stall instead.
    @Test func namesAPausedDirectiveRatherThanWaitingOnACompletionThatCannotCome() {
        let paused = device(
            "CTRL", type: "ami_mining_controller", stowedIn: "VESSEL",
            controlled: ["DRONE"], directives: ["gather_salvage"],
            currentDirective: "gather_salvage",
            currentDirectiveConfig: ["location": .string("TOSLIT-6-5"), "recall": .bool(true)],
            currentDirectiveStatus: "paused",
            updatedAt: now.addingTimeInterval(-3 * 60)
        )
        let deployed = device("DRONE", type: "mining_drone", location: "TOSLIT-6-5", controlledBy: "CTRL",
                              updatedAt: now.addingTimeInterval(-3 * 60))
        let directive = running(step: "awaiting", stepStartedAt: now.addingTimeInterval(-7 * 60 * 60))
        let world = world(devices: [atSystem, paused, deployed], now: now)
        #expect(SalvageRun().nextAction(directive: directive, world: world)
            == .refreshFleet(tag: "auto:salvage", thenStall: .miningDirectivePaused))
    }

    /// The throttle still binds on the paused branch, so a controller that keeps
    /// reading paused cannot buy a read every tick on its way to the stall.
    @Test func throttlesTheReadThatProvesADirectiveIsPaused() {
        let paused = device(
            "CTRL", type: "ami_mining_controller", stowedIn: "VESSEL",
            controlled: ["DRONE"], directives: ["gather_salvage"],
            currentDirective: "gather_salvage",
            currentDirectiveConfig: ["location": .string("TOSLIT-6-5"), "recall": .bool(true)],
            currentDirectiveStatus: "paused", updatedAt: now.addingTimeInterval(-30)
        )
        let deployed = device("DRONE", type: "mining_drone", location: "TOSLIT-6-5", controlledBy: "CTRL",
                              updatedAt: now.addingTimeInterval(-30))
        let directive = running(step: "awaiting", stepStartedAt: now.addingTimeInterval(-60 * 60))
        let world = world(devices: [atSystem, paused, deployed], now: now)
        #expect(SalvageRun().nextAction(directive: directive, world: world) == .wait)
    }

    /// A dropped completion frame: the drones are already home, nothing said so.
    /// A fresh (post-launch) read showing all aboard hands off to `verify`.
    @Test func verifiesWhenAllDronesAreHomeWithoutACompletionFrame() {
        let directive = running(step: "awaiting", stepStartedAt: now.addingTimeInterval(-60))
        // controller + drone are `fixtureNow`, which is >= stepStartedAt: fresh
        // since launch, and the drone is stowed aboard.
        let world = world(devices: [atSystem, controller, drone], now: now)
        #expect(SalvageRun().nextAction(directive: directive, world: world)
            == .advanceStep(nextStep: "verifying"))
    }

    /// Rows not read since launch (pre-launch `updatedAt`) can't be trusted — a
    /// pre-launch drone still shows aboard. Force one fresh read first.
    @Test func readsTheFleetWhenEvidencePredatesLaunch() {
        let staleCtrl = device("CTRL", type: "ami_mining_controller", stowedIn: "VESSEL",
                               controlled: ["DRONE"], directives: ["gather_salvage"],
                               updatedAt: now.addingTimeInterval(-SalvageRun.reconcileInterval - 1))
        let staleDrone = device("DRONE", type: "mining_drone", stowedIn: "VESSEL", controlledBy: "CTRL",
                                updatedAt: now.addingTimeInterval(-SalvageRun.reconcileInterval - 1))
        let directive = running(step: "awaiting", stepStartedAt: now) // launch just now; rows older
        let world = world(devices: [atSystem, staleCtrl, staleDrone], now: now)
        #expect(SalvageRun().nextAction(directive: directive, world: world)
            == .refreshFleet(tag: "auto:salvage", thenStall: nil))
    }

    /// The throttle guard: pre-launch rows read within `reconcileInterval` wait
    /// rather than re-reading every tick, so a failing read can't loop.
    @Test func waitsRatherThanReReadingWithinTheReconcileInterval() {
        let recentCtrl = device("CTRL", type: "ami_mining_controller", stowedIn: "VESSEL",
                                controlled: ["DRONE"], directives: ["gather_salvage"],
                                updatedAt: now.addingTimeInterval(-30))
        let recentDrone = device("DRONE", type: "mining_drone", stowedIn: "VESSEL", controlledBy: "CTRL",
                                 updatedAt: now.addingTimeInterval(-30))
        let directive = running(step: "awaiting", stepStartedAt: now) // rows (-30s) predate launch (now)
        let world = world(devices: [atSystem, recentCtrl, recentDrone], now: now)
        #expect(SalvageRun().nextAction(directive: directive, world: world) == .wait)
    }

    /// Mining done (controller idle), a straggler still flying home with a future
    /// ETA: wait it out rather than handing to `verify`'s single-read stall.
    @Test func waitsForAStragglerStillFlyingHome() {
        let idle = device("CTRL", type: "ami_mining_controller", stowedIn: "VESSEL",
                          controlled: ["DRONE"], directives: ["gather_salvage"]) // no currentDirective
        let flying = device("DRONE", type: "mining_drone", controlledBy: "CTRL",
                            arrivesAt: now.addingTimeInterval(30))
        let directive = running(step: "awaiting", stepStartedAt: now.addingTimeInterval(-60))
        let world = world(devices: [atSystem, idle, flying], now: now)
        #expect(SalvageRun().nextAction(directive: directive, world: world) == .wait)
    }

    /// Mining done, a drone not aboard and NOT travelling (no ETA): it isn't
    /// coming on its own. Hand to `verify`, which refreshes once and raises
    /// `dronesNotRecovered` if the fresh rows agree.
    @Test func handsToVerifyWhenAStrandedDroneIsntComing() {
        let idle = device("CTRL", type: "ami_mining_controller", stowedIn: "VESSEL",
                          controlled: ["DRONE"], directives: ["gather_salvage"])
        let stuck = device("DRONE", type: "mining_drone", location: "TOSLIT-6-5", controlledBy: "CTRL")
        let directive = running(step: "awaiting", stepStartedAt: now.addingTimeInterval(-60))
        let world = world(devices: [atSystem, idle, stuck], now: now)
        #expect(SalvageRun().nextAction(directive: directive, world: world)
            == .advanceStep(nextStep: "verifying"))
    }

    /// A fresh controller row must NOT vouch for a stale DRONE row. AMI drones
    /// are event-silent, so the controller's own digest churn keeps its row
    /// fresh right after launch while the drone row is still the pre-launch,
    /// "stowed aboard" one. The freshness gate keys off the drones (min), so it
    /// forces a real drone read here rather than reading the stale row as
    /// "recovered" and advancing to verify — the very false `dronesNotRecovered`
    /// this step exists to prevent.
    @Test func doesNotTrustAStaleDroneRowVouchedForByAFreshController() {
        let freshCtrl = device("CTRL", type: "ami_mining_controller", stowedIn: "VESSEL",
                               controlled: ["DRONE"], directives: ["gather_salvage"],
                               currentDirective: "gather_salvage",
                               currentDirectiveConfig: ["location": .string("TOSLIT-6-5"), "recall": .bool(true)],
                               updatedAt: now) // fresh: digest churn
        let staleDrone = device("DRONE", type: "mining_drone", stowedIn: "VESSEL", controlledBy: "CTRL",
                                updatedAt: now.addingTimeInterval(-SalvageRun.reconcileInterval - 1)) // pre-launch, looks aboard
        let directive = running(step: "awaiting", stepStartedAt: now.addingTimeInterval(-60))
        let world = world(devices: [atSystem, freshCtrl, staleDrone], now: now)
        #expect(SalvageRun().nextAction(directive: directive, world: world)
            == .refreshFleet(tag: "auto:salvage", thenStall: nil))
    }

    /// Still mining and the throttle allows a read: reconcile the fleet (catch a
    /// dropped completion / the controller going idle). Pins the still-mining
    /// POSITIVE branch — `waitsWhileMiningEvenPastTenMinutes` only covers the
    /// throttle-negative wait.
    @Test func reconcilesTheFleetWhileMiningWhenTheThrottleAllows() {
        let mining = device("CTRL", type: "ami_mining_controller", stowedIn: "VESSEL",
                            controlled: ["DRONE"], directives: ["gather_salvage"],
                            currentDirective: "gather_salvage",
                            currentDirectiveConfig: ["location": .string("TOSLIT-6-5"), "recall": .bool(true)],
                            updatedAt: now.addingTimeInterval(-3 * 60))
        let deployed = device("DRONE", type: "mining_drone", location: "TOSLIT-6-5", controlledBy: "CTRL",
                              updatedAt: now.addingTimeInterval(-3 * 60)) // fresh since launch, older than reconcileInterval
        let directive = running(step: "awaiting", stepStartedAt: now.addingTimeInterval(-10 * 60))
        let world = world(devices: [atSystem, mining, deployed], now: now)
        #expect(SalvageRun().nextAction(directive: directive, world: world)
            == .refreshFleet(tag: "auto:salvage", thenStall: nil))
    }

    /// `awaitCompletion`'s reconcile read carries the same wire-tag rule as
    /// `preflight`'s — a per-theatre directive must still ask the server for
    /// the tag it actually recognises.
    @Test func reconcileRefreshesUsingTheRootTagNotThePerTheatreOne() {
        let mining = device("CTRL", type: "ami_mining_controller", stowedIn: "VESSEL",
                            controlled: ["DRONE"], directives: ["gather_salvage"],
                            currentDirective: "gather_salvage",
                            currentDirectiveConfig: ["location": .string("TOSLIT-6-5"), "recall": .bool(true)],
                            updatedAt: now.addingTimeInterval(-3 * 60))
        let deployed = device("DRONE", type: "mining_drone", location: "TOSLIT-6-5", controlledBy: "CTRL",
                              updatedAt: now.addingTimeInterval(-3 * 60))
        let directive = running(
            step: "awaiting", fleetTag: "auto:salvage:AINALRAM-BELT-1",
            stepStartedAt: now.addingTimeInterval(-10 * 60)
        )
        let world = world(devices: [atSystem, mining, deployed], now: now)
        #expect(SalvageRun().nextAction(directive: directive, world: world)
            == .refreshFleet(tag: "auto:salvage", thenStall: nil))
    }

    /// Mining done, a straggler whose ETA has already passed and the throttle
    /// allows: re-read just that drone rather than waiting or handing off. Pins
    /// the recall-branch POSITIVE `refreshDevices` — `waitsForAStragglerStillFlyingHome`
    /// only covers the future-ETA wait, and `handsToVerifyWhenAStrandedDroneIsntComing`
    /// has no travel block at all.
    @Test func reReadsAStragglerWhoseEtaHasPassed() {
        let idle = device("CTRL", type: "ami_mining_controller", stowedIn: "VESSEL",
                          controlled: ["DRONE"], directives: ["gather_salvage"],
                          updatedAt: now.addingTimeInterval(-3 * 60))
        let overdue = device("DRONE", type: "mining_drone", controlledBy: "CTRL",
                             updatedAt: now.addingTimeInterval(-3 * 60),
                             arrivesAt: now.addingTimeInterval(-10)) // travel block, ETA already passed
        let directive = running(step: "awaiting", stepStartedAt: now.addingTimeInterval(-10 * 60))
        let world = world(devices: [atSystem, idle, overdue], now: now)
        #expect(SalvageRun().nextAction(directive: directive, world: world)
            == .refreshDevices(deviceCodes: ["DRONE"], thenStall: nil))
    }

    /// Issue-time relative: a completion delivered by catch-up after the app
    /// was closed still counts, while one predating this step is a replay.
    @Test func advancesToVerifyingWhenCompletionLands() {
        let directive = running(step: "awaiting", stepStartedAt: now)
        let world = world(devices: [atSystem, controller, drone],
                          log: [completion(at: now.addingTimeInterval(1))], now: now)
        #expect(SalvageRun().nextAction(directive: directive, world: world)
            == .advanceStep(nextStep: "verifying"))
    }

    /// No drones out means no completion is ever coming — surface it rather
    /// than waiting forever.
    @Test func stallsWhenALaunchDeployedNothing() {
        let directive = running(step: "awaiting", stepStartedAt: now)
        let world = world(devices: [atSystem, controller, drone],
                          log: [emptyLaunch(at: now.addingTimeInterval(1))], now: now)
        #expect(SalvageRun().nextAction(directive: directive, world: world)
            == .stall(.launchDeployedNothing))
    }

    /// A system with no live salvage body left — drained, or never held one to
    /// begin with — has nothing for `configuring` to configure toward. This is
    /// also the seam Task 8's `verifying` step will hand back into once it
    /// exists: it recognises "nothing left" identically whether this is the
    /// first evaluation after arrival or a return trip after a body just
    /// finished, so no separate finished-system check is needed there.
    @Test func recallsTheBotsWhenNoBodyIsLeftToWork() {
        let drained = StarSystem(designation: "TOSLIT", planets: [])
        let world = world(devices: [atSystem, controller, drone], systems: ["TOSLIT": drained])
        #expect(SalvageRun().nextAction(directive: running(step: "configuring"), world: world)
            == .advanceStep(nextStep: "repairing"))
    }

    /// CRITICAL fix from review: a system that hasn't been cached yet (its
    /// `SystemDetail` row hasn't landed, or failed to decode) must NOT read as
    /// "nothing left to mine" — the two collapsed to the same outcome before
    /// this fix, and `configure` advanced past a system it had never actually
    /// looked at. Since `.advanceTarget` is irreversible (`targetIndex` only
    /// grows, and `SalvageTargetPlanner` excludes every already-attempted
    /// system from ever being offered again), that silently and permanently
    /// skipped a system that might hold real, assayed salvage. Distinct from
    /// `advancesTheTargetWhenNoBodyIsLeftToWork` above: there the system IS
    /// present in `world.systems`, just empty of live bodies; here `"TOSLIT"`
    /// has no entry in `systems` at all.
    @Test func waitsWhenTheTargetSystemIsntCachedYet() {
        let world = world(devices: [atSystem, controller, drone]) // no "TOSLIT" entry in `systems`
        #expect(SalvageRun().nextAction(directive: running(step: "configuring"), world: world) == .wait)
    }

    /// The bound on that wait: `.wait` never re-stamps `stepStartedAt`, so this
    /// deadline genuinely accumulates now. Past it, the run reads while
    /// `systemUnresolvedRetryWindow` still allows it.
    @Test func readsTheSystemWhileTheRetryWindowAllowsIt() {
        let directive = running(
            step: "configuring",
            stepStartedAt: now.addingTimeInterval(-SalvageRun.systemResolutionDeadline - 1)
        )
        let world = world(devices: [atSystem, controller, drone], now: now) // still no "TOSLIT" entry
        #expect(SalvageRun().nextAction(directive: directive, world: world)
            == .refreshSystem(designation: "TOSLIT", nextStep: "configuring"))
    }

    /// The read is spent ONCE, not on every tick of `systemUnresolvedRetryWindow`
    /// — walks the whole span at the engine's 5s cadence and counts, so a
    /// regression back to "one read per tick" fails this test, not a human.
    @Test func readsOnlyOnceAcrossTheWholeRetryWindow() {
        let stepStartedAt = Date(timeIntervalSince1970: 0)
        let span = SalvageRun.systemResolutionDeadline + SalvageRun.systemUnresolvedRetryWindow
        var reads = 0
        var sawTheStall = false
        var elapsed = SalvageRun.systemResolutionDeadline - 10
        while elapsed <= span + 10 {
            let world = world(
                devices: [atSystem, controller, drone], // still no "TOSLIT" entry
                now: stepStartedAt.addingTimeInterval(elapsed)
            )
            switch SalvageRun().nextAction(directive: running(step: "configuring", stepStartedAt: stepStartedAt), world: world) {
            case .refreshSystem: reads += 1
            case .stall(.salvageSystemUnresolved, nil): sawTheStall = true
            case .wait: break
            default: Issue.record("unexpected action at elapsed \(elapsed)")
            }
            elapsed += 5
        }
        #expect(reads == 1)
        #expect(sawTheStall)
    }

    /// Past `systemUnresolvedRetryWindow` too, the run surfaces rather than
    /// reading forever. `stepStartedAt` alone governs — no log fixture needed —
    /// since a same-step `.refreshSystem` leaves it untouched.
    @Test func stallsWhenTheTargetSystemNeverResolves() {
        let directive = running(
            step: "configuring",
            stepStartedAt: now.addingTimeInterval(
                -(SalvageRun.systemResolutionDeadline + SalvageRun.systemUnresolvedRetryWindow + 1)
            )
        )
        let world = world(devices: [atSystem, controller, drone], now: now) // still no "TOSLIT" entry
        #expect(SalvageRun().nextAction(directive: directive, world: world)
            == .stall(.salvageSystemUnresolved))
    }

    /// And the operator's Retry re-arms it — `DirectiveResolutionClient.retry`
    /// stamps `stepStartedAt = now` directly. Old `.stepStarted` log history
    /// (nothing clears it) must not count against the reset deadline.
    @Test func aRetryStartsTheDeadlineOverRatherThanReplayingTheStall() {
        let directive = running(step: "configuring", stepStartedAt: now)
        let world = world(
            devices: [atSystem, controller, drone],
            log: [stepStarted("configuring", at: now.addingTimeInterval(-3_600)),
                  stepStarted("configuring", at: now.addingTimeInterval(-1_800))],
            now: now
        )
        #expect(SalvageRun().nextAction(directive: directive, world: world) == .wait)
    }
}

// MARK: - Verification

/// This step exists because a Survey Run once lost its entire drone
/// complement: `directive.completed` meant the SURVEY had finished, not the
/// RECALL, and the run read completion as clearance to depart, stranding
/// drones behind. Since v2.3.3 the server holds `directive.completed` for a
/// recall-configured directive until the drones finish travelling, so a
/// stranded-looking drone here is far more likely a stale local row than a
/// real loss — hence one confirming read, not `SurveyRun.recover`'s
/// elaborate ETA-driven polling.
@Suite("Salvage Run — verification")
struct SalvageRunVerificationTests {
    /// Every adopted drone is back aboard, and the system still holds live
    /// salvage: route back to `configuring` to work the next body.
    @Test func advancesToConfiguringWhenDronesAreHomeAndBodiesRemain() {
        let world = world(devices: [atSystem, controller, drone],
                          systems: ["TOSLIT": miningToslit], siteAssays: miningToslitAssays)
        #expect(SalvageRun().nextAction(directive: running(step: "verifying"), world: world)
            == .advanceStep(nextStep: "positioning"))
    }

    /// "Just in case": completion now implies recall, so a stranded-looking
    /// drone is far more likely a stale row than a real loss. One
    /// authoritative read decides — and only if it AGREES does the run stall.
    @Test func readsTheFleetOnceBeforeBelievingADroneIsStranded() {
        let stranded = device("DRONE", type: "mining_drone", location: "TOSLIT-6-5", controlledBy: "CTRL")
        let world = world(devices: [atSystem, controller, stranded], systems: ["TOSLIT": miningToslit])
        #expect(SalvageRun().nextAction(directive: running(step: "verifying"), world: world)
            == .refreshFleet(tag: "auto:salvage", thenStall: .dronesNotRecovered))
    }

    /// `verify`'s recovery read carries the same wire-tag rule: a per-theatre
    /// directive must still ask the server for the tag it actually knows.
    @Test func refreshesUsingTheRootTagNotThePerTheatreOne() {
        let stranded = device("DRONE", type: "mining_drone", location: "TOSLIT-6-5", controlledBy: "CTRL")
        let world = world(devices: [atSystem, controller, stranded], systems: ["TOSLIT": miningToslit])
        let directive = running(step: "verifying", fleetTag: "auto:salvage:AINALRAM-BELT-1")
        #expect(SalvageRun().nextAction(directive: directive, world: world)
            == .refreshFleet(tag: "auto:salvage", thenStall: .dronesNotRecovered))
    }

    /// The root of the live soft-stall: `directive.completed` tracks the DRONES,
    /// and the controller then flies its OWN leg back. Releasing the vessel here
    /// leaves it chasing, and the stow ending that chase pauses the directive
    /// `configure`/`launch` set meanwhile.
    @Test func waitsForTheControllerStillFlyingBackToTheVessel() {
        let flying = device(
            "CTRL", type: "ami_mining_controller", controlled: ["DRONE"],
            directives: ["gather_salvage"], arrivesAt: now.addingTimeInterval(90)
        )
        let world = world(devices: [atSystem, flying, drone],
                          systems: ["TOSLIT": miningToslit], siteAssays: miningToslitAssays, now: now)
        // Resolved by code: a controller out of the vessel is invisible to the
        // stowed-aboard fallback, which reads it as vanished instead.
        let directive = running(step: "verifying", controllerCode: "CTRL")
        #expect(SalvageRun().nextAction(directive: directive, world: world) == .wait)
    }

    /// A controller out of the vessel with no ETA and a stale row buys one
    /// throttled read rather than departing on rows nothing has confirmed.
    @Test func readsTheControllerRowBeforeConcludingItIsHome() {
        let ashore = device(
            "CTRL", type: "ami_mining_controller", location: "TOSLIT-6-5",
            controlled: ["DRONE"], directives: ["gather_salvage"],
            updatedAt: now.addingTimeInterval(-SalvageRun.arrivalReadInterval - 1)
        )
        let world = world(devices: [atSystem, ashore, drone],
                          systems: ["TOSLIT": miningToslit], siteAssays: miningToslitAssays, now: now)
        let directive = running(step: "verifying", controllerCode: "CTRL")
        #expect(SalvageRun().nextAction(directive: directive, world: world)
            == .refreshDevices(deviceCodes: ["CTRL"], thenStall: nil))
    }

    /// The escape: a controller that never gets back aboard must surface rather
    /// than hold the run forever. Checked BEFORE the staleness guard, so a row
    /// whose reads keep failing still reaches it.
    @Test func surfacesAControllerThatNeverComesBackAboard() {
        let ashore = device(
            "CTRL", type: "ami_mining_controller", location: "TOSLIT-6-5",
            controlled: ["DRONE"], directives: ["gather_salvage"], updatedAt: now
        )
        let directive = running(
            step: "verifying", controllerCode: "CTRL",
            stepStartedAt: now.addingTimeInterval(-SalvageRun.controllerRecallDeadline - 1)
        )
        let world = world(devices: [atSystem, ashore, drone],
                          systems: ["TOSLIT": miningToslit], siteAssays: miningToslitAssays, now: now)
        #expect(SalvageRun().nextAction(directive: directive, world: world)
            == .stall(.miningControllerNotRecovered))
    }

    /// No salvage left anywhere in the system: this target is finished, and the
    /// service bots come home before the vessel leaves.
    @Test func recallsTheBotsOnceTheSystemIsDrained() {
        let world = world(devices: [atSystem, controller, drone], systems: ["TOSLIT": drainedToslit])
        #expect(SalvageRun().nextAction(directive: running(step: "verifying"), world: world)
            == .advanceStep(nextStep: "repairing"))
    }

    /// A vanished controller is preflight's diagnosis to make, not
    /// verifying's — holding here would stall on a reason that doesn't name
    /// the real problem. Mirrors `SurveyRun.recover`'s identical handling.
    @Test func recallsTheBotsWhenTheControllerHasVanished() {
        let world = world(devices: [atSystem, drone], systems: ["TOSLIT": miningToslit])
        #expect(SalvageRun().nextAction(directive: running(step: "verifying"), world: world)
            == .advanceStep(nextStep: "repairing"))
    }

    /// The same Critical-class fix as `configure`/`emplace`, one step over:
    /// once recovery is confirmed, an uncached system must not read as
    /// "finished" — it must wait for the blob rather than silently advancing
    /// the target past salvage it never actually looked at.
    @Test func waitsWhenTheSystemIsntCachedYet() {
        let world = world(devices: [atSystem, controller, drone]) // no "TOSLIT" entry
        #expect(SalvageRun().nextAction(directive: running(step: "verifying"), world: world) == .wait)
    }

    /// The bound on that wait, same shape and deadline as `configure`'s.
    @Test func stallsWhenTheSystemNeverResolves() {
        let directive = running(
            step: "verifying",
            stepStartedAt: fixtureNow.addingTimeInterval(
                -(SalvageRun.systemResolutionDeadline + SalvageRun.systemUnresolvedRetryWindow + 1)
            )
        )
        let world = world(devices: [atSystem, controller, drone]) // still no "TOSLIT" entry
        #expect(SalvageRun().nextAction(directive: directive, world: world)
            == .stall(.salvageSystemUnresolved))
    }
}

// MARK: - Mining-loop progress

/// The mining loop's only terminator used to be one SSE frame.
///
/// `configuring → launching → awaiting → verifying → configuring` re-derives
/// `nextBody` on every pass, and a body leaves the candidate set only when its
/// site's `depleted` flag flips — written solely by the `salvage.depleted`
/// route. Nothing refreshed the system and nothing recorded which body had just
/// been worked, so a single dropped frame meant a real `launch` POST every
/// cycle, unbounded, with no deadline and no stall.
@Suite("Salvage Run — mining-loop progress")
struct SalvageRunLoopProgressTests {
    /// The controller carrying an in-force `gather_salvage` config — the
    /// server's own record of the body the finished cycle was working, which is
    /// what lets the loop notice it is not progressing without a new column.
    private func worked(_ body: String) -> Device {
        device(
            "CTRL", type: "ami_mining_controller", stowedIn: "VESSEL",
            controlled: ["DRONE"], directives: ["gather_salvage"],
            currentDirective: "gather_salvage",
            currentDirectiveConfig: ["location": .string(body), "recall": .bool(true)]
        )
    }

    /// Moments after a cycle ends, a still-on-offer worked body is lag, not
    /// evidence — the `salvage.depleted` frame and the roster both run minutes
    /// behind the drones' real finish. Wait, spend nothing.
    @Test func waitsOutPropagationLagBeforeSpendingTheRead() {
        let world = world(devices: [atSystem, worked("TOSLIT-6-5"), drone],
                          systems: ["TOSLIT": miningToslit], siteAssays: miningToslitAssays)
        #expect(SalvageRun().nextAction(directive: running(step: "verifying"), world: world)
            == .wait)
    }

    /// The body just worked is still the richest live one past the grace.
    /// Rather than re-launching at it — which is what the loop did forever —
    /// read the BODY authoritatively: the server delists a depleted site, and
    /// only the per-body endpoint can observe the absence (`.refreshSystem`'s
    /// star-level payload carries no salvage arrays for these bodies at all).
    @Test func readsTheBodyWhenTheBodyJustWorkedComesBackAgain() {
        let directive = running(
            step: "verifying",
            stepStartedAt: fixtureNow.addingTimeInterval(-SalvageRun.depletionPropagationGrace - 1)
        )
        let world = world(devices: [atSystem, worked("TOSLIT-6-5"), drone],
                          systems: ["TOSLIT": miningToslit], siteAssays: miningToslitAssays)
        #expect(SalvageRun().nextAction(directive: directive, world: world)
            == .refreshBody(system: "TOSLIT", body: "TOSLIT-6-5", nextStep: "verifying"))
    }

    /// Same invariant as the system backstop's: the body read is spent ONCE,
    /// not on every tick of `bodyUnresolvedRetryWindow` — walked at the
    /// engine's 5s cadence.
    @Test func readsTheBodyOnlyOnceAcrossTheWholeRetryWindow() {
        let stepStartedAt = Date(timeIntervalSince1970: 0)
        let span = SalvageRun.depletionPropagationGrace + SalvageRun.bodyUnresolvedRetryWindow
        var reads = 0
        var sawTheStall = false
        var elapsed = SalvageRun.depletionPropagationGrace - 10
        while elapsed <= span + 10 {
            let world = world(
                devices: [atSystem, worked("TOSLIT-6-5"), drone],
                systems: ["TOSLIT": miningToslit], siteAssays: miningToslitAssays,
                now: stepStartedAt.addingTimeInterval(elapsed)
            )
            let directive = running(step: "verifying", stepStartedAt: stepStartedAt)
            switch SalvageRun().nextAction(directive: directive, world: world) {
            case .refreshBody: reads += 1
            case .stall(.salvageBodyNotDepleted, _): sawTheStall = true
            case .wait: break
            default: Issue.record("unexpected action at elapsed \(elapsed)")
            }
            elapsed += 5
        }
        #expect(reads == 1)
        #expect(sawTheStall)
    }

    /// Past `bodyUnresolvedRetryWindow` too, and the body is STILL on offer,
    /// the run surfaces instead of looping — naming the body, so the operator
    /// can tell WHICH site the run means without touring the system by hand.
    @Test func stallsWhenAWorkedBodyNeverDrains() {
        let directive = running(
            step: "verifying",
            stepStartedAt: fixtureNow.addingTimeInterval(
                -(SalvageRun.depletionPropagationGrace + SalvageRun.bodyUnresolvedRetryWindow + 1)
            )
        )
        let world = world(
            devices: [atSystem, worked("TOSLIT-6-5"), drone],
            systems: ["TOSLIT": miningToslit], siteAssays: miningToslitAssays
        )
        #expect(SalvageRun().nextAction(directive: directive, world: world)
            == .stall(.salvageBodyNotDepleted, detail: "TOSLIT-6-5"))
    }

    /// Progress looks like this: the body just worked has dropped out, and the
    /// next-richest one is offered. The loop continues with no read spent.
    @Test func continuesWhenTheNextBodyIsADifferentOne() {
        let world = world(devices: [atSystem, worked("TOSLIT-6-5"), drone],
                          systems: ["TOSLIT": partlyDrainedToslit],
                          siteAssays: miningToslitAssays)
        #expect(SalvageRun().nextAction(directive: running(step: "verifying"), world: world)
            == .advanceStep(nextStep: "positioning"))
    }

    /// A controller running something else — or nothing — names no worked body,
    /// so there is nothing to compare against and the loop proceeds normally.
    /// This is the first pass through a fresh system, before any cycle has run.
    @Test func proceedsWhenTheControllerNamesNoWorkedBody() {
        let world = world(devices: [atSystem, controller, drone],
                          systems: ["TOSLIT": miningToslit], siteAssays: miningToslitAssays)
        #expect(SalvageRun().nextAction(directive: running(step: "verifying"), world: world)
            == .advanceStep(nextStep: "positioning"))
    }
}

// MARK: - Restock

// MARK: - Arrival freshness fixtures

/// The instant the incident's travel op closed, on `fixtureNow`'s clock.
///
/// Salvage Run `BCC18F1C`, 2026-08-01: vessel `C7836770` arrived at
/// ALZEPHINA-7-4, its travel op `1F616245` closed `lastConfirmedAt = 01:37:33.000`,
/// and the tick that re-commanded travel landed **139 ms later** — inside the
/// window between `Reconciler.applyOperationEvent` closing the op and
/// `Reconciler.applyEventFields` writing `device.location`. `fixtureNow` plays
/// the part of that tick, so every fixture below is 139 ms after the arrival,
/// exactly as it was live.
private let arrivalClosedAt = fixtureNow.addingTimeInterval(-0.139)

/// A vessel row written 5 s BEFORE the arrival closed: it still names the
/// origin, and it is recent enough that the throttled read has not come due, so
/// the gate's answer is a plain `.wait`.
private let rowLaggingArrival = arrivalClosedAt.addingTimeInterval(-5)

/// The incident's own vessel-row age: `updatedAt ≈ 01:35:30` against an arrival
/// at `01:37:33` — 123 s behind, well past `arrivalReadInterval`.
private let rowLaggingArrivalBy123s = arrivalClosedAt.addingTimeInterval(-123)

/// One CLOSED travel op belonging to this directive, keyed by id the way
/// `WorldSnapshot.dispatchedOperations` is.
///
/// Deliberately NOT `operation(kind:)` above: that one is the single OPEN op
/// per device that the `openOperation` guard reads, and these are two different
/// maps on purpose — a finished op must never read as in-flight. The arrival
/// watermark lives only in this one.
private func dispatchedTravel(
    id: String = "1F616245",
    entityCode: String = "VESSEL",
    kind: OperationKind = .travel,
    status: OperationStatus = .completed,
    completedAt: Date = arrivalClosedAt
) -> GameModels.Operation {
    GameModels.Operation(
        id: id, entityCode: entityCode, kind: kind.rawValue,
        status: status, source: .event,
        startedAt: completedAt.addingTimeInterval(-120), completesAt: nil,
        lastConfirmedAt: completedAt, detail: .object([:])
    )
}

/// The `dispatchedOperations` map for a single closed travel — the shape all
/// four dispatch sites are gated against.
private func afterArrival(
    kind: OperationKind = .travel,
    status: OperationStatus = .completed,
    completedAt: Date = arrivalClosedAt
) -> [String: GameModels.Operation] {
    let op = dispatchedTravel(kind: kind, status: status, completedAt: completedAt)
    return [op.id: op]
}

/// The vessel still claiming the place it departed from, with an `updatedAt`
/// that predates the arrival — the exact row the incident decided from.
private func laggingVessel(at origin: String?, updatedAt: Date = rowLaggingArrival) -> Device {
    device("VESSEL", type: "heaven_vessel", location: origin, updatedAt: updatedAt)
}

// MARK: - Arrival freshness

/// The 2026-08-01 `Already at destination` incident, one dispatch site at a time.
///
/// `GameSync.deviceRoute` settles a `travel.arrived` event in TWO transactions
/// with awaits between them: the op closes first, `device.location` is written
/// second. All four travel dispatch sites read exactly those two facts and used
/// to guard only on the first, so a tick landing in the gap saw "op finished,
/// vessel still at the origin" and re-commanded travel to where the vessel
/// already was. The server rejected it and the run stalled `.commandRejected`.
///
/// Every fixture here therefore carries the PRIOR state the memory note
/// demands — a closed travel op AND a vessel row older than it — because a
/// world with no completed travel takes the gate's cold-run arm and proves
/// nothing. Before these tests, every fixture in this file was that empty one.
@Suite("Salvage Run — arrival freshness")
struct SalvageRunArrivalFreshnessTests {
    // MARK: Site 1 — travel (destination = the target system)

    /// Site 1 of 4. Without the gate this re-commands `travel TOSLIT` at a
    /// vessel whose op says it has already finished travelling.
    @Test func travelWaitsWhenTheVesselRowStillLagsTheArrival() {
        let snapshot = world(
            devices: [laggingVessel(at: "AINALRAM-BELT-1"), controller, drone, relay],
            dispatchedOperations: afterArrival()
        )
        #expect(SalvageRun().nextAction(directive: running(step: "travelling"), world: snapshot) == .wait)
    }

    /// The no-regression half: the same fixture with a row written AT the
    /// arrival still departs. If this fails the gate has become a brake on
    /// every legitimate travel, which is worse than the bug it fixes.
    @Test func travelStillDispatchesWhenTheRowPostDatesTheArrival() {
        let snapshot = world(
            devices: [laggingVessel(at: "AINALRAM-BELT-1", updatedAt: arrivalClosedAt), controller, drone, relay],
            dispatchedOperations: afterArrival()
        )
        #expect(SalvageRun().nextAction(directive: running(step: "travelling"), world: snapshot)
                == .dispatch(kind: .travel, deviceCode: "VESSEL",
                             params: CommandParams(destination: "TOSLIT"), nextStep: "travelling"))
    }

    // MARK: Site 2 — emplace (destination = the Lagrange point)

    // MARK: Site 3 — position (destination = the salvage body)

    /// Site 3 of 4 — the site the live incident actually fired at. The hop from
    /// the entry point to the first body is short, so the tick after the arrival
    /// op closes lands well inside the two-transaction window.
    @Test func positionWaitsWhenTheVesselRowStillLagsTheArrival() {
        let snapshot = world(
            devices: [laggingVessel(at: "TOSLIT-3"), controller, drone],
            dispatchedOperations: afterArrival(),
            systems: ["TOSLIT": miningToslit], siteAssays: miningToslitAssays
        )
        #expect(SalvageRun().nextAction(directive: running(step: "positioning"), world: snapshot) == .wait)
    }

    @Test func positionStillDispatchesWhenTheRowPostDatesTheArrival() {
        let snapshot = world(
            devices: [laggingVessel(at: "TOSLIT-3", updatedAt: arrivalClosedAt), controller, drone],
            dispatchedOperations: afterArrival(),
            systems: ["TOSLIT": miningToslit], siteAssays: miningToslitAssays
        )
        #expect(SalvageRun().nextAction(directive: running(step: "positioning"), world: snapshot)
                == .dispatch(kind: .travel, deviceCode: "VESSEL",
                             params: CommandParams(destination: "TOSLIT-6-5"), nextStep: "positioning"))
    }

    /// Where the gate is allowed to sit, not just whether it fires.
    ///
    /// The gate must stay AFTER the location-equality check, and every other
    /// stale fixture in this suite has `location != destination`, so they all
    /// pass equally well against a gate hoisted above it. This is the fixture
    /// that does not: the row is just as stale, but it happens to already name
    /// the destination — the BENIGN direction, because the vessel is where it
    /// needs to be and the step should advance to work the body. Hoisting the
    /// gate turns that into a wait (then a read, then
    /// `.vesselPositionUnconfirmed`) on every single arrival, which is a worse
    /// bug than the one the gate fixes: it stalls the happy path.
    @Test func positionAdvancesOnAStaleRowThatAlreadyNamesTheDestination() {
        let snapshot = world(
            devices: [laggingVessel(at: "TOSLIT-6-5"), controller, drone], // stale, but already at the body
            dispatchedOperations: afterArrival(),
            systems: ["TOSLIT": miningToslit], siteAssays: miningToslitAssays
        )
        #expect(SalvageRun().nextAction(directive: running(step: "positioning"), world: snapshot)
                == .advanceStep(nextStep: "configuring"))
    }

    // MARK: Site 4 — restock (destination = base)

    // MARK: The cold run

    /// A run that has never completed a travel has no watermark for the row to
    /// post-date, so it must depart on the very first evaluation. Getting this
    /// wrong is why the watermark is the ARRIVAL and not `stepStartedAt`: that
    /// gate would have delayed every first travel by a whole deadline.
    @Test func dispatchesImmediatelyOnAColdRunWithNoCompletedTravel() {
        let snapshot = world(devices: [laggingVessel(at: "TOSLIT-3"), controller, drone],
                             systems: ["TOSLIT": miningToslit], siteAssays: miningToslitAssays)
        #expect(SalvageRun.lastTravelCompletion(for: laggingVessel(at: "TOSLIT-3"), snapshot) == nil)
        #expect(SalvageRun().nextAction(directive: running(step: "positioning"), world: snapshot)
                == .dispatch(kind: .travel, deviceCode: "VESSEL",
                             params: CommandParams(destination: "TOSLIT-6-5"), nextStep: "positioning"))
    }

    // MARK: The escalation ladder

    /// Ordering is mandated by the confirm-steps-need-fresh-evidence note, half
    /// two: the DEADLINE outranks the throttled read. The row here is stale on
    /// both counts, and the deadline is what must answer — otherwise a vessel
    /// whose reads never land (offline, 429, a device the server 404s) never
    /// reaches its deadline, never stalls, and buys a `.high` read every tick
    /// forever at ~12 reads a minute.
    @Test func surfacesVesselPositionUnconfirmedOnceTheArrivalDeadlinePasses() {
        let longAgo = fixtureNow.addingTimeInterval(-SalvageRun.arrivalConfirmDeadline)
        let snapshot = world(
            devices: [laggingVessel(at: "TOSLIT-3", updatedAt: longAgo.addingTimeInterval(-5)), controller, drone],
            dispatchedOperations: afterArrival(completedAt: longAgo),
            systems: ["TOSLIT": miningToslit], siteAssays: miningToslitAssays
        )
        #expect(SalvageRun().nextAction(directive: running(step: "positioning"), world: snapshot)
                == .refreshDevices(deviceCodes: ["VESSEL"], thenStall: .vesselPositionUnconfirmed))
    }

    /// The incident's own numbers: the arrival closed 139 ms ago (nowhere near
    /// the deadline) but the vessel row is 123 s old (past
    /// `arrivalReadInterval`), so the run buys ONE authoritative read.
    /// `thenStall: nil` is what keeps it bounded — `DirectiveEngine.reAsk`
    /// collapses a repeat request into `.wait` rather than looping.
    @Test func readsTheVesselRowOnceTheThrottleAllowsRatherThanWaitingBlind() {
        let snapshot = world(
            devices: [laggingVessel(at: "TOSLIT-3", updatedAt: rowLaggingArrivalBy123s), controller, drone],
            dispatchedOperations: afterArrival(),
            systems: ["TOSLIT": miningToslit], siteAssays: miningToslitAssays
        )
        #expect(SalvageRun().nextAction(directive: running(step: "positioning"), world: snapshot)
                == .refreshDevices(deviceCodes: ["VESSEL"], thenStall: nil))
    }

    /// The bottom rung, pinned at the boundary: a row read exactly
    /// `arrivalReadInterval` ago still waits. The ordinary case is the gap
    /// closing on its own within a tick or two, and paying for a read every
    /// time would spend the budget on a race that resolves itself.
    @Test func waitsRatherThanReadingWithinTheArrivalReadInterval() {
        let atTheBoundary = fixtureNow.addingTimeInterval(-SalvageRun.arrivalReadInterval)
        let snapshot = world(
            devices: [laggingVessel(at: "TOSLIT-3", updatedAt: atTheBoundary), controller, drone],
            dispatchedOperations: afterArrival(),
            systems: ["TOSLIT": miningToslit], siteAssays: miningToslitAssays
        )
        #expect(SalvageRun().nextAction(directive: running(step: "positioning"), world: snapshot) == .wait)
    }

    // MARK: Which ops count as an arrival

    /// `.superseded` is stamped on an op when a NEWER command lands on the same
    /// device, and it stamps `lastConfirmedAt` when it does. Counting it would
    /// install a watermark for a trip that never finished — gating a real
    /// dispatch behind an arrival that never happened, this bug inverted — so a
    /// superseded travel must leave the dispatch path completely open.
    @Test func aSupersededTravelIsNotAnArrivalWatermark() {
        let snapshot = world(
            devices: [laggingVessel(at: "TOSLIT-3"), controller, drone],
            dispatchedOperations: afterArrival(status: .superseded),
            systems: ["TOSLIT": miningToslit], siteAssays: miningToslitAssays
        )
        #expect(SalvageRun.lastTravelCompletion(for: laggingVessel(at: "TOSLIT-3"), snapshot) == nil)
        #expect(SalvageRun().nextAction(directive: running(step: "positioning"), world: snapshot)
                == .dispatch(kind: .travel, deviceCode: "VESSEL",
                             params: CommandParams(destination: "TOSLIT-6-5"), nextStep: "positioning"))
    }

    /// `.unknown` is what `DeadlineScheduler` marks an op whose deadline passed
    /// with nothing confirming it — the clearest case of a trip that did NOT
    /// arrive, and it stamps `lastConfirmedAt` too.
    @Test func anUnknownTravelIsNotAnArrivalWatermark() {
        let snapshot = world(
            devices: [laggingVessel(at: "TOSLIT-3"), controller, drone],
            dispatchedOperations: afterArrival(status: .unknown),
            systems: ["TOSLIT": miningToslit], siteAssays: miningToslitAssays
        )
        #expect(SalvageRun.lastTravelCompletion(for: laggingVessel(at: "TOSLIT-3"), snapshot) == nil)
        #expect(SalvageRun().nextAction(directive: running(step: "positioning"), world: snapshot)
                == .dispatch(kind: .travel, deviceCode: "VESSEL",
                             params: CommandParams(destination: "TOSLIT-6-5"), nextStep: "positioning"))
    }

    /// A completed op of another KIND is not an arrival either: a finished
    /// `mine` says nothing about where the vessel is, and treating it as a
    /// watermark would gate travel behind mining.
    @Test func aCompletedNonTravelOpIsNotAnArrivalWatermark() {
        let snapshot = world(
            devices: [laggingVessel(at: "TOSLIT-3"), controller, drone],
            dispatchedOperations: afterArrival(kind: .mine),
            systems: ["TOSLIT": miningToslit], siteAssays: miningToslitAssays
        )
        #expect(SalvageRun.lastTravelCompletion(for: laggingVessel(at: "TOSLIT-3"), snapshot) == nil)
        #expect(SalvageRun().nextAction(directive: running(step: "positioning"), world: snapshot)
                == .dispatch(kind: .travel, deviceCode: "VESSEL",
                             params: CommandParams(destination: "TOSLIT-6-5"), nextStep: "positioning"))
    }

    /// The watermark is the LATEST completed travel for THIS vessel: another
    /// device's arrival is not evidence about ours, and an older leg of the same
    /// route must not be mistaken for the one just finished.
    @Test func theWatermarkIsTheLatestCompletedTravelForThisVessel() {
        let earlier = dispatchedTravel(id: "303BFBAB", completedAt: arrivalClosedAt.addingTimeInterval(-857))
        let latest = dispatchedTravel(id: "1F616245", completedAt: arrivalClosedAt)
        let someoneElse = dispatchedTravel(
            id: "OTHER", entityCode: "DRONE", completedAt: arrivalClosedAt.addingTimeInterval(60)
        )
        let mining = dispatchedTravel(id: "MINE", kind: .mine, completedAt: arrivalClosedAt.addingTimeInterval(90))
        let snapshot = world(
            devices: [laggingVessel(at: "TOSLIT-3"), controller, drone],
            dispatchedOperations: [
                earlier.id: earlier, latest.id: latest,
                someoneElse.id: someoneElse, mining.id: mining,
            ]
        )
        #expect(SalvageRun.lastTravelCompletion(for: laggingVessel(at: "TOSLIT-3"), snapshot) == arrivalClosedAt)
    }
}
