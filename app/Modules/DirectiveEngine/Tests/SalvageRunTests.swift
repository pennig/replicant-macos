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
    tags: [String] = [],
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
    if let currentDirective {
        detail["ami_directive"] = .object([
            "name": .string(currentDirective),
            "config": .object(currentDirectiveConfig ?? [:]),
        ])
    }
    return Device(
        deviceCode: code, deviceType: type, replicantCode: "R1",
        status: status, location: location, locationName: nil,
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
    systems: [String: StarSystem] = [:],
    siteAssays: [String: [String: Double]] = [:],
    now: Date = fixtureNow
) -> WorldSnapshot {
    WorldSnapshot(
        devices: Dictionary(devices.map { ($0.deviceCode, $0) }, uniquingKeysWith: { _, last in last }),
        openOperations: openOperations, log: log, systems: systems, siteAssays: siteAssays, now: now
    )
}

/// A `.stepStarted` timeline entry — the row `DirectiveExecutor.move` writes on
/// every step transition, and the one `SalvageRun.stepEntryCount` counts to
/// decide whether a re-entering step has already spent its read.
private func stepStarted(_ step: String, at occurredAt: Date) -> DirectiveLogEntry {
    DirectiveLogEntry(
        id: "S-\(step)-\(occurredAt.timeIntervalSince1970)", directiveID: "D1",
        deviceCode: nil, kind: .stepStarted, summary: "Step: \(step)", step: step,
        operationID: nil, eventID: nil, occurredAt: occurredAt
    )
}

/// The entry `DirectiveResolutionClient` writes when the operator resolves a
/// stall. It re-arms the read budget: a Retry has to be able to buy a genuinely
/// new look, or it is a no-op over an unchanged snapshot.
private func resolvedEntry(_ step: String, at occurredAt: Date) -> DirectiveLogEntry {
    DirectiveLogEntry(
        id: "R-\(occurredAt.timeIntervalSince1970)", directiveID: "D1",
        deviceCode: nil, kind: .resolved, summary: "Retried \(step)", step: step,
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

    /// The relay is an ENABLER, not an optional extra: without one the run
    /// would have to park at the target for the whole haul, which is exactly
    /// what the two-machine split exists to avoid. Out of relays and the
    /// target needs one, so the vessel routes to base rather than departing.
    @Test func routesToBaseWhenOutOfRelaysAndTheTargetNeedsOne() {
        let snapshot = world(devices: [vessel, controller, drone]) // no relay aboard
        #expect(SalvageRun().nextAction(directive: running(step: "preflight"), world: snapshot)
                == .advanceStep(nextStep: "restocking"))
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

    /// The fix for the Important finding from review: re-deriving
    /// `relay(aboard:in:)` at `emplace` time only re-reads these same cached
    /// local rows — it forces no live read, so it cannot catch a claim that
    /// was already stale before departure. The relay row is folded into THIS
    /// check instead, alongside `[vessel, controller] + drones`, so a stale
    /// relay alone — with the rest of the fleet perfectly fresh — still earns
    /// a read before the vessel commits to a trip it might not actually be
    /// equipped for.
    @Test func aStaleRelayRowEarnsAReadBeforeDepartureEvenWhenTheRestOfTheFleetIsFresh() {
        let staleRelay = device(
            "RELAY", type: "ftl_relay", stowedIn: "VESSEL", features: ["relay"],
            updatedAt: fixtureNow.addingTimeInterval(-SalvageRun.stagingFreshness - 1)
        )
        let snapshot = world(devices: [vessel, controller, drone, staleRelay]) // vessel/controller/drone fresh
        #expect(SalvageRun().nextAction(directive: running(step: "preflight"), world: snapshot)
                == .refreshFleet(tag: "auto:salvage", thenStall: .unreachableDevice))
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
                == .advanceStep(nextStep: "positioning"))
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

/// TOSLIT with a planet but no Lagrange point anywhere — cannot host a relay.
private let toslitWithNoLagrangePoint = StarSystem(
    designation: "TOSLIT",
    planets: [Planet(designation: "TOSLIT-3")]
)

// MARK: - Emplacement

@Suite("Salvage Run — emplacement")
struct SalvageRunEmplacementTests {
    @Test func travelsToALagrangePointBeforeDeploying() {
        // Relays only work at L4/L5 — the vessel must actually be there, not
        // merely in the system.
        let arrived = device("VESSEL", type: "heaven_vessel", location: "TOSLIT-3")
        let world = world(devices: [arrived, controller, drone, relay], systems: ["TOSLIT": toslit])
        #expect(SalvageRun().nextAction(directive: running(step: "emplacing"), world: world)
            == .dispatch(kind: .travel, deviceCode: "VESSEL",
                         params: CommandParams(destination: "TOSLIT-3-L4"), nextStep: "emplacing"))
    }

    @Test func deploysTheRelayOnceAtTheLagrangePoint() {
        let atL4 = device("VESSEL", type: "heaven_vessel", location: "TOSLIT-3-L4")
        let world = world(devices: [atL4, controller, drone, relay], systems: ["TOSLIT": toslit])
        #expect(SalvageRun().nextAction(directive: running(step: "emplacing"), world: world)
            == .dispatch(kind: .simple("deploy"), deviceCode: "RELAY",
                         params: CommandParams(), nextStep: "activating"))
    }

    @Test func activatesTheDeployedRelayOnceAndMovesToThePollingStep() {
        // `deploy` does NOT activate — that is a separate command, verified
        // live against the API. `activating` is dispatch-only: the poll (and
        // its backstop deadline) live entirely in `confirmingRelay` — see
        // the reasoning pinned by `waitsRatherThanRedispatchingWhileWithinTheDeadline`.
        let atL4 = device("VESSEL", type: "heaven_vessel", location: "TOSLIT-3-L4")
        let deployed = device("RELAY", type: "ftl_relay", location: "TOSLIT-3-L4", features: ["relay"], status: "idle")
        let world = world(devices: [atL4, controller, drone, deployed], systems: ["TOSLIT": toslit])
        #expect(SalvageRun().nextAction(directive: running(step: "activating"), world: world)
            == .dispatch(kind: .simple("activate"), deviceCode: "RELAY",
                         params: CommandParams(), nextStep: "confirmingRelay"))
    }

    @Test func advancesToConfiguringOnceTheRelayIsRelaying() {
        let atL4 = device("VESSEL", type: "heaven_vessel", location: "TOSLIT-3-L4")
        let up = device("RELAY", type: "ftl_relay", location: "TOSLIT-3-L4", features: ["relay"], status: "relaying")
        let world = world(devices: [atL4, controller, drone, up], systems: ["TOSLIT": toslit])
        #expect(SalvageRun().nextAction(directive: running(step: "confirmingRelay"), world: world)
            == .advanceStep(nextStep: "positioning"))
    }

    /// The relay is now planted infrastructure, not cargo: `auto:salvage`
    /// earned its place while the relay was stowed (it's how `preflight`'s
    /// `.refreshFleet` found it), but leaving it tagged means every future tag
    /// read drags back a growing tail of relays this run planted and will
    /// never touch again. Confirmed `relaying`, carrying the tag → untag it,
    /// then move on.
    @Test func untagsTheRelayOnceItStartsRelaying() {
        let atL4 = device("VESSEL", type: "heaven_vessel", location: "TOSLIT-3-L4")
        let up = device("RELAY", type: "ftl_relay", location: "TOSLIT-3-L4",
                        features: ["relay"], status: "relaying", tags: ["auto:salvage"])
        let world = world(devices: [atL4, controller, drone, up], systems: ["TOSLIT": toslit])
        #expect(SalvageRun().nextAction(directive: running(step: "confirmingRelay"), world: world)
            == .setDeviceTags(deviceCode: "RELAY", tags: [], nextStep: "positioning"))
    }

    /// `updateTags` is declarative — it replaces the WHOLE set — so untagging
    /// must send the relay's remaining tags, never a bare `[]` that would wipe
    /// anything else the operator put on it.
    @Test func preservesTheRelaysOtherTagsWhenUntagging() {
        let atL4 = device("VESSEL", type: "heaven_vessel", location: "TOSLIT-3-L4")
        let up = device("RELAY", type: "ftl_relay", location: "TOSLIT-3-L4", features: ["relay"],
                        status: "relaying", tags: ["operator:keep", "auto:salvage", "operator:also-keep"])
        let world = world(devices: [atL4, controller, drone, up], systems: ["TOSLIT": toslit])
        #expect(SalvageRun().nextAction(directive: running(step: "confirmingRelay"), world: world)
            == .setDeviceTags(
                deviceCode: "RELAY", tags: ["operator:keep", "operator:also-keep"], nextStep: "positioning"
            ))
    }

    /// A non-default `fleetTag` is the tag that must be dropped — the same
    /// rule `preflight`'s `.refreshFleet` follows via `SalvageRun.fleetTag`.
    @Test func untagsAgainstTheRowsOwnFleetTagRatherThanTheDefault() {
        let atL4 = device("VESSEL", type: "heaven_vessel", location: "TOSLIT-3-L4")
        let up = device("RELAY", type: "ftl_relay", location: "TOSLIT-3-L4",
                        features: ["relay"], status: "relaying", tags: ["auto:salvage-2"])
        let directive = running(step: "confirmingRelay", fleetTag: "auto:salvage-2")
        let world = world(devices: [atL4, controller, drone, up], systems: ["TOSLIT": toslit])
        #expect(SalvageRun().nextAction(directive: directive, world: world)
            == .setDeviceTags(deviceCode: "RELAY", tags: [], nextStep: "positioning"))
    }

    /// Idempotent: a relay that no longer carries the fleet tag — the run
    /// relaunched after untagging landed, or the operator removed it by hand —
    /// must not re-issue a redundant PATCH. `advancesToConfiguringOnceTheRelayIsRelaying`
    /// above already covers this (its fixture carries no tags at all); this
    /// test pins the property explicitly against a relay that has OTHER tags
    /// but not this run's own.
    @Test func advancesPlainlyWhenTheRelayNoLongerCarriesTheFleetTag() {
        let atL4 = device("VESSEL", type: "heaven_vessel", location: "TOSLIT-3-L4")
        let up = device("RELAY", type: "ftl_relay", location: "TOSLIT-3-L4",
                        features: ["relay"], status: "relaying", tags: ["operator:keep"])
        let world = world(devices: [atL4, controller, drone, up], systems: ["TOSLIT": toslit])
        #expect(SalvageRun().nextAction(directive: running(step: "confirmingRelay"), world: world)
            == .advanceStep(nextStep: "positioning"))
    }

    /// The property that pins the Critical fix from review: from the polling
    /// step, a relay that is not yet `relaying` and is still inside the
    /// deadline must `.wait` — it must NEVER dispatch. The original
    /// single-step design dispatched `activate` again here, which (per
    /// `DirectiveExecutor.apply`) re-stamps `stepStartedAt` on every accepted
    /// dispatch, so the deadline below could never accumulate and this
    /// assertion would have failed against that shape (it would have seen a
    /// `.dispatch`, not `.wait`). This is exactly the regression guard the
    /// review asked for.
    @Test func waitsRatherThanRedispatchingWhileWithinTheDeadline() {
        let atL4 = device("VESSEL", type: "heaven_vessel", location: "TOSLIT-3-L4")
        let deployed = device("RELAY", type: "ftl_relay", location: "TOSLIT-3-L4", features: ["relay"], status: "idle")
        let recent = running(step: "confirmingRelay", stepStartedAt: now.addingTimeInterval(-60))
        let world = world(devices: [atL4, controller, drone, deployed],
                          systems: ["TOSLIT": toslit], now: now)
        #expect(SalvageRun().nextAction(directive: recent, world: world) == .wait)
    }

    @Test func stallsWhenTheRelayNeverComesUp() {
        // The backstop. A relay that deployed but never started relaying is a
        // dead run — the whole point of the trip was the mesh membership.
        let atL4 = device("VESSEL", type: "heaven_vessel", location: "TOSLIT-3-L4")
        let deployed = device("RELAY", type: "ftl_relay", location: "TOSLIT-3-L4", features: ["relay"], status: "idle")
        let stale = running(step: "confirmingRelay", stepStartedAt: now.addingTimeInterval(-11 * 60))
        let world = world(devices: [atL4, controller, drone, deployed],
                          systems: ["TOSLIT": toslit], now: now)
        #expect(SalvageRun().nextAction(directive: stale, world: world)
            == .stall(.relayActivationFailed))
    }

    /// Nothing else moves the relay row while this step polls: the `relay.*` SSE
    /// route only invalidates FTL-mesh freshness, and the confirm-read that
    /// follows `activate` fires before the server has necessarily flipped the
    /// status. A bare wait could therefore sit on a stale row for the whole ten
    /// minutes and then stall on a relay that came up fine, so a row that has
    /// gone unread past `relayPollInterval` earns an authoritative look.
    @Test func readsTheRelayRowRatherThanWaitingOnAStaleOne() {
        let atL4 = device("VESSEL", type: "heaven_vessel", location: "TOSLIT-3-L4")
        let stale = device(
            "RELAY", type: "ftl_relay", location: "TOSLIT-3-L4", features: ["relay"],
            status: "idle", updatedAt: now.addingTimeInterval(-SalvageRun.relayPollInterval - 1)
        )
        let directive = running(step: "confirmingRelay", stepStartedAt: now.addingTimeInterval(-120))
        let world = world(devices: [atL4, controller, drone, stale],
                          systems: ["TOSLIT": toslit], now: now)
        // `thenStall: nil` — a relay still coming up is expected, not a fault,
        // so a re-ask that still wants a read collapses to a wait rather than
        // demanding a human.
        #expect(SalvageRun().nextAction(directive: directive, world: world)
            == .refreshDevices(deviceCodes: ["RELAY"], thenStall: nil))
    }

    /// The backend appends a parenthetical parameter to some statuses, so a raw
    /// `status == "relaying"` reads a live relay as dead — a false
    /// `relayActivationFailed` on a relay that is up and meshing.
    /// `Device.statusBase` is the established form.
    @Test func acceptsARelayingStatusCarryingAParameter() {
        let atL4 = device("VESSEL", type: "heaven_vessel", location: "TOSLIT-3-L4")
        let up = device("RELAY", type: "ftl_relay", location: "TOSLIT-3-L4",
                        features: ["relay"], status: "relaying (TOSLIT)")
        let world = world(devices: [atL4, controller, drone, up], systems: ["TOSLIT": toslit])
        #expect(SalvageRun().nextAction(directive: running(step: "confirmingRelay"), world: world)
            == .advanceStep(nextStep: "positioning"))
    }

    /// A `system_hub` carries the `relay` FEATURE — it contains an integrated
    /// relay, which is why `SalvageTargetPlanner.meshSystems` is right to match
    /// on the feature. These are dispatch queries though, and a stowed hub
    /// matched by feature would have had `deploy` issued at it.
    @Test func neverMistakesAStowedSystemHubForARelay() {
        let atL4 = device("VESSEL", type: "heaven_vessel", location: "TOSLIT-3-L4")
        let hub = device("HUB", type: "system_hub", stowedIn: "VESSEL", features: ["relay", "hub"])
        let world = world(devices: [atL4, controller, drone, hub], systems: ["TOSLIT": toslit])
        #expect(SalvageRun.relay(aboard: atL4, in: world) == nil)
        // No relay aboard at all, so emplacement reroutes to restocking rather
        // than deploying the hub.
        #expect(SalvageRun().nextAction(directive: running(step: "emplacing"), world: world)
            == .advanceStep(nextStep: "restocking"))
    }

    /// The same narrowing on the co-location query `activate` and `confirmRelay`
    /// resolve through: a hub parked at the vessel's own Lagrange point is not
    /// the relay this run just deployed.
    @Test func neverMistakesACoLocatedSystemHubForTheDeployedRelay() {
        let atL4 = device("VESSEL", type: "heaven_vessel", location: "TOSLIT-3-L4")
        let hub = device("HUB", type: "system_hub", location: "TOSLIT-3-L4",
                         features: ["relay", "hub"], status: "relaying")
        let world = world(devices: [atL4, controller, drone, hub], systems: ["TOSLIT": toslit])
        #expect(SalvageRun.deployedRelay(near: atL4, in: world) == nil)
    }

    /// A system with no Lagrange point anywhere cannot host a relay — a
    /// degraded outcome (the salvage is still worth taking), not an error, so
    /// the run mines it unmeshed instead of stalling.
    @Test func minesUnmeshedWhenTheSystemHasNoLagrangePoint() {
        let arrived = device("VESSEL", type: "heaven_vessel", location: "TOSLIT-3")
        let world = world(devices: [arrived, controller, drone, relay],
                          systems: ["TOSLIT": toslitWithNoLagrangePoint])
        #expect(SalvageRun().nextAction(directive: running(step: "emplacing"), world: world)
            == .advanceStep(nextStep: "positioning"))
    }

    /// `emplace`'s relay-aboard guard is a backstop for the relay being
    /// genuinely absent — not a staleness fix (that lives in `preflight`, see
    /// `aStaleRelayRowEarnsAReadBeforeDepartureEvenWhenTheRestOfTheFleetIsFresh`).
    /// This pins the backstop itself: no relay anywhere in the world reroutes
    /// to `restocking` rather than dispatching `deploy` at nothing.
    @Test func routesToRestockingWhenNoRelayIsAboardAtAll() {
        let atL4 = device("VESSEL", type: "heaven_vessel", location: "TOSLIT-3-L4")
        let world = world(devices: [atL4, controller, drone], systems: ["TOSLIT": toslit]) // no relay anywhere
        #expect(SalvageRun().nextAction(directive: running(step: "emplacing"), world: world)
            == .advanceStep(nextStep: "restocking"))
    }

    /// The Important fix carried in from Task 7's review: the target's
    /// `SystemDetail` blob not being cached yet must NOT read as "this system
    /// has no Lagrange point" — that conflation used to route straight to
    /// `configuring`, silently and permanently forfeiting relay emplacement
    /// for the target (nothing routes `configuring` back to `emplacing`).
    /// Distinct from `minesUnmeshedWhenTheSystemHasNoLagrangePoint` above:
    /// there `"TOSLIT"` IS present in `world.systems`, just genuinely without
    /// a point; here it has no entry in `systems` at all.
    @Test func waitsRatherThanForfeitingEmplacementWhenTheBlobIsntCachedYet() {
        let arrived = device("VESSEL", type: "heaven_vessel", location: "TOSLIT-3")
        let world = world(devices: [arrived, controller, drone, relay]) // no "TOSLIT" entry in `systems`
        #expect(SalvageRun().nextAction(directive: running(step: "emplacing"), world: world) == .wait)
    }

    /// The bound on that wait, mirroring `configure`'s
    /// `readsTheSystemOnceBeforeGivingUpOnIt`: past `systemResolutionDeadline`
    /// the run spends ONE authoritative read rather than waiting forever — or
    /// stalling on a snapshot that Retry could never change.
    @Test func readsTheSystemOnceBeforeGivingUpDuringEmplacement() {
        let arrived = device("VESSEL", type: "heaven_vessel", location: "TOSLIT-3")
        let directive = running(
            step: "emplacing",
            stepStartedAt: now.addingTimeInterval(-SalvageRun.systemResolutionDeadline - 1)
        )
        let world = world(devices: [arrived, controller, drone, relay], now: now) // still no "TOSLIT" entry
        #expect(SalvageRun().nextAction(directive: directive, world: world)
            == .refreshSystem(designation: "TOSLIT", nextStep: "emplacing"))
    }

    /// And once that read has been spent, it surfaces.
    @Test func stallsWhenTheBlobNeverResolvesDuringEmplacement() {
        let arrived = device("VESSEL", type: "heaven_vessel", location: "TOSLIT-3")
        let directive = running(
            step: "emplacing",
            stepStartedAt: now.addingTimeInterval(-SalvageRun.systemResolutionDeadline - 1)
        )
        let world = world(
            devices: [arrived, controller, drone, relay],
            log: [stepStarted("emplacing", at: now.addingTimeInterval(-1_200)),
                  stepStarted("emplacing", at: now.addingTimeInterval(-601))],
            now: now
        )
        #expect(SalvageRun().nextAction(directive: directive, world: world)
            == .stall(.salvageSystemUnresolved))
    }
}

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
    /// the first look now, so it inherits `configure`'s finished handling.
    @Test func advancesTheTargetWhenNoBodyIsLeft() {
        let drained = StarSystem(designation: "TOSLIT", planets: [])
        let world = world(devices: [atSystem, controller, drone], systems: ["TOSLIT": drained])
        #expect(SalvageRun().nextAction(directive: running(step: "positioning"), world: world)
            == .advanceTarget)
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

    @Test func launchesTheController() {
        let world = world(devices: [atSystem, controller, drone],
                          systems: ["TOSLIT": miningToslit], siteAssays: miningToslitAssays)
        #expect(SalvageRun().nextAction(directive: running(step: "launching"), world: world)
            == .dispatch(kind: OperationKind.simple("launch"), deviceCode: "CTRL",
                         params: CommandParams(), nextStep: "awaiting"))
    }

    @Test func waitsForCompletionThenVerifies() {
        let world = world(devices: [atSystem, controller, drone])
        #expect(SalvageRun().nextAction(directive: running(step: "awaiting"), world: world) == .wait)
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
    @Test func advancesTheTargetWhenNoBodyIsLeftToWork() {
        let drained = StarSystem(designation: "TOSLIT", planets: [])
        let world = world(devices: [atSystem, controller, drone], systems: ["TOSLIT": drained])
        #expect(SalvageRun().nextAction(directive: running(step: "configuring"), world: world)
            == .advanceTarget)
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

    /// The bound on that wait: `.wait` is the only `MissionAction` that never
    /// re-stamps `stepStartedAt` (`DirectiveExecutor.apply`'s `.wait` case is
    /// a pure no-op — every other case, including `.refreshSystem`, commits
    /// through `move()`), so it's the only way this backstop can genuinely
    /// accumulate. Past `systemResolutionDeadline` the run spends ONE
    /// authoritative read — the fix for an Important review finding: the stall
    /// this used to raise told the operator to "retry to fetch it again", but
    /// nothing on this path ever fetched anything and `retry` only re-stamps the
    /// clock, so Retry re-ran a pure function over the identical snapshot and
    /// re-stalled forever. The only real exit was Skip, which permanently
    /// forfeits a system that may hold real salvage.
    @Test func readsTheSystemOnceBeforeGivingUpOnIt() {
        let directive = running(
            step: "configuring",
            stepStartedAt: now.addingTimeInterval(-SalvageRun.systemResolutionDeadline - 1)
        )
        let world = world(devices: [atSystem, controller, drone], now: now) // still no "TOSLIT" entry
        #expect(SalvageRun().nextAction(directive: directive, world: world)
            == .refreshSystem(designation: "TOSLIT", nextStep: "configuring"))
    }

    /// Once that read has been spent — the step has been entered twice with no
    /// resolution in between — the run surfaces rather than refreshing forever.
    @Test func stallsWhenTheTargetSystemNeverResolves() {
        let directive = running(
            step: "configuring",
            stepStartedAt: now.addingTimeInterval(-SalvageRun.systemResolutionDeadline - 1)
        )
        let world = world(
            devices: [atSystem, controller, drone],
            log: [stepStarted("configuring", at: now.addingTimeInterval(-1_200)),
                  stepStarted("configuring", at: now.addingTimeInterval(-601))],
            now: now
        )
        #expect(SalvageRun().nextAction(directive: directive, world: world)
            == .stall(.salvageSystemUnresolved))
    }

    /// And the operator's Retry re-arms it. This is what makes the stall's
    /// guidance true: `DirectiveResolutionClient.retry` writes a `.resolved`
    /// entry, which ends the budget walk, so the very next deadline buys a fresh
    /// authoritative read rather than replaying the stale snapshot.
    @Test func aRetryBuysAnotherReadRatherThanReplayingTheStall() {
        let directive = running(
            step: "configuring",
            stepStartedAt: now.addingTimeInterval(-SalvageRun.systemResolutionDeadline - 1)
        )
        let world = world(
            devices: [atSystem, controller, drone],
            log: [stepStarted("configuring", at: now.addingTimeInterval(-1_200)),
                  stepStarted("configuring", at: now.addingTimeInterval(-900)),
                  resolvedEntry("configuring", at: now.addingTimeInterval(-601))],
            now: now
        )
        #expect(SalvageRun().nextAction(directive: directive, world: world)
            == .refreshSystem(designation: "TOSLIT", nextStep: "configuring"))
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

    /// No salvage left anywhere in the system: this target is finished.
    @Test func advancesTheTargetOnceTheSystemIsDrained() {
        let world = world(devices: [atSystem, controller, drone], systems: ["TOSLIT": drainedToslit])
        #expect(SalvageRun().nextAction(directive: running(step: "verifying"), world: world)
            == .advanceTarget)
    }

    /// A vanished controller is preflight's diagnosis to make, not
    /// verifying's — holding here would stall on a reason that doesn't name
    /// the real problem. Mirrors `SurveyRun.recover`'s identical handling.
    @Test func advancesTheTargetWhenTheControllerHasVanished() {
        let world = world(devices: [atSystem, drone], systems: ["TOSLIT": miningToslit])
        #expect(SalvageRun().nextAction(directive: running(step: "verifying"), world: world)
            == .advanceTarget)
    }

    /// The same Critical-class fix as `configure`/`emplace`, one step over:
    /// once recovery is confirmed, an uncached system must not read as
    /// "finished" — it must wait for the blob rather than silently advancing
    /// the target past salvage it never actually looked at.
    @Test func waitsWhenTheSystemIsntCachedYet() {
        let world = world(devices: [atSystem, controller, drone]) // no "TOSLIT" entry
        #expect(SalvageRun().nextAction(directive: running(step: "verifying"), world: world) == .wait)
    }

    /// The bound on that wait, same shape, deadline and one-read budget as
    /// `configure`'s.
    @Test func stallsWhenTheSystemNeverResolves() {
        let directive = running(
            step: "verifying",
            stepStartedAt: fixtureNow.addingTimeInterval(-SalvageRun.systemResolutionDeadline - 1)
        )
        let world = world(
            devices: [atSystem, controller, drone], // still no "TOSLIT" entry
            log: [stepStarted("verifying", at: fixtureNow.addingTimeInterval(-1_200)),
                  stepStarted("verifying", at: fixtureNow.addingTimeInterval(-601))]
        )
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

    /// The body just worked is still the richest live one. Rather than
    /// re-launching at it — which is what the loop did forever — read the system
    /// authoritatively: the common cause is a stale `depleted` flag, and the
    /// read repairs it.
    @Test func readsTheSystemWhenTheBodyJustWorkedComesBackAgain() {
        let world = world(devices: [atSystem, worked("TOSLIT-6-5"), drone],
                          systems: ["TOSLIT": miningToslit], siteAssays: miningToslitAssays)
        #expect(SalvageRun().nextAction(directive: running(step: "verifying"), world: world)
            == .refreshSystem(designation: "TOSLIT", nextStep: "verifying"))
    }

    /// Once that read has been spent and the body is STILL on offer, the run
    /// surfaces instead of looping. A stall the operator can Skip past beats an
    /// invisible command loop against the live API.
    @Test func stallsWhenAWorkedBodyNeverDrains() {
        let world = world(
            devices: [atSystem, worked("TOSLIT-6-5"), drone],
            log: [stepStarted("verifying", at: fixtureNow.addingTimeInterval(-120)),
                  stepStarted("verifying", at: fixtureNow.addingTimeInterval(-60))],
            systems: ["TOSLIT": miningToslit], siteAssays: miningToslitAssays
        )
        #expect(SalvageRun().nextAction(directive: running(step: "verifying"), world: world)
            == .stall(.salvageBodyNotDepleted))
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

@Suite("Salvage Run — restock")
struct SalvageRunRestockTests {
    /// Out of relays: travel to base.
    @Test func travelsToBaseWhenOutOfRelays() {
        let world = world(devices: [vessel, controller, drone])
        #expect(SalvageRun().nextAction(directive: running(step: "restocking"), world: world)
            == .dispatch(kind: .travel, deviceCode: "VESSEL",
                         params: CommandParams(destination: "AINALRAM-BELT-1"), nextStep: "restocking"))
    }

    /// Mid-travel is a wait, never a second travel command stacked on the one
    /// already in flight — the same tracked-op guard `travel()` uses. Safe as
    /// a same-step dispatch precisely because `.travel` IS a tracked op kind
    /// (see the same-step-dispatch-needs-tracked-op memory note).
    @Test func waitsWhileTheTripToBaseIsUnderway() {
        let world = world(devices: [vessel, controller, drone],
                          openOperations: ["VESSEL": operation(kind: .travel)])
        #expect(SalvageRun().nextAction(directive: running(step: "restocking"), world: world) == .wait)
    }

    /// The engine does NOT stow — that would loosen the never-stow contract,
    /// which is its own future design. It parks and asks.
    ///
    /// But it reads the fleet first, and that is not decoration: this is the one
    /// step whose whole purpose is waiting on an operator action that changes a
    /// stow column, and nothing else refreshes those rows while the run sits
    /// here. A bare stall made Retry a structural no-op — the operator stows
    /// relays, hits Retry, and the same stale rows still say none are aboard. A
    /// tag read is also the only scope that can SEE a freshly stowed device,
    /// since stowing clears `location`.
    @Test func readsTheFleetBeforeStallingForRestockAtBase() {
        let atBase = device("VESSEL", location: "AINALRAM-BELT-1")
        let world = world(devices: [atBase, controller, drone])
        #expect(SalvageRun().nextAction(directive: running(step: "restocking"), world: world)
            == .refreshFleet(tag: "auto:salvage", thenStall: .awaitingRelayRestock))
    }

    @Test func resumesWhenRelaysAreStowedAndTheRunIsRetried() {
        let atBase = device("VESSEL", location: "AINALRAM-BELT-1")
        let world = world(devices: [atBase, controller, drone, relay])
        #expect(SalvageRun().nextAction(directive: running(step: "restocking"), world: world)
            == .advanceStep(nextStep: "preflight"))
    }

    /// A relay found aboard short-circuits the detour immediately, whether or
    /// not the vessel has physically reached `AINALRAM-BELT-1` yet — staging
    /// one mid-flight shouldn't force a pointless wait for arrival.
    @Test func resumesAsSoonAsARelayIsAboardEvenBeforeReachingBase() {
        let midTrip = device("VESSEL") // no location: still travelling
        let world = world(devices: [midTrip, controller, drone, relay])
        #expect(SalvageRun().nextAction(directive: running(step: "restocking"), world: world)
            == .advanceStep(nextStep: "preflight"))
    }
}
