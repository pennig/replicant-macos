//
//  RelayRunTests.swift
//  Replicould — DirectiveEngine
//
//  The Relay Run step machine as a pure function table, following the same
//  pattern as `SalvageRunTests`. The run acquires a relay — printing one at the
//  hub, or reclaiming an existing useless one where it stands — gets it aboard
//  the carrier, flies it to the target's Lagrange point, deploys it, activates
//  it, and confirms the mesh actually grew.
//
//  Two things get specific attention here because they are where this machine
//  can hurt a live account:
//    • every `.simple` verb dispatch must advance to a DISTINCT poll step (a
//      `.simple` verb carries no `Operation` row, so a same-step redispatch
//      re-stamps `stepStartedAt` on every tick and hammers the API forever);
//    • the print is a real resource spend, so the reserve rail's veto must sit
//      BEFORE the `enqueue_print`, never after it.
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

/// Where the autofactory and the carrier both sit. A BELT designation on
/// purpose: the live print hub (`43C9B54A`) is at `AINALRAM-BELT-1`, not at a
/// planet, and a fixture that quietly used a planet would hide any code that
/// assumed one.
private let hubLocation = "HUB-BELT-1"

private func device(
    _ code: String,
    type: String = "generic_device",
    location: String? = nil,
    stowedIn: String? = nil,
    status: String = "idle",
    features: [String] = [],
    availableCommands: [String] = [],
    updatedAt: Date = fixtureNow
) -> Device {
    Device(
        deviceCode: code, deviceType: type, replicantCode: "R1", status: status,
        location: location, locationName: nil, operationalCapacity: 100, queueSize: 0,
        stowedInDeviceCode: stowedIn, controllerDeviceCode: nil, attachedToDeviceCode: nil,
        createdAt: Date(timeIntervalSince1970: 0), availableCommands: availableCommands,
        features: features, tags: [], detail: .object([:]),
        updatedAt: updatedAt, firstSeenAt: Date(timeIntervalSince1970: 0)
    )
}

/// The carrier this run leases — a HEAVEN vessel parked at the hub's location,
/// which is what makes the autofactory-carrier composition work at all.
private func carrier(
    location: String? = hubLocation,
    updatedAt: Date = fixtureNow,
    controlRange: Bool? = nil
) -> Device {
    var vessel = device("V1", type: "heaven_vessel", location: location, updatedAt: updatedAt)
    // `in_control_range` lives in the device's detail tail, which is where
    // `Device.inControlRange` reads it from. Absent by default, matching the
    // payloads that do not report it.
    if let controlRange { vessel.detail = .object(["in_control_range": .bool(controlRange)]) }
    return vessel
}

/// The autofactory. `Device.isPrintHub` keys off `enqueue_print` in
/// `availableCommands`, never on `device_type`.
private func hub(location: String = hubLocation, updatedAt: Date = fixtureNow) -> Device {
    device(
        "AF1", type: "autofactory", location: location,
        availableCommands: ["enqueue_print"], updatedAt: updatedAt
    )
}

/// A relay, in whatever state a test needs. `features` matches the live fleet's
/// `["cruise","relay","stow"]` so `Device.isActiveRelay` and
/// `SalvageTargetPlanner.meshSystems(in:)` both key off it correctly.
private func relay(
    _ code: String = "RLY1",
    location: String? = nil,
    stowedIn: String? = nil,
    status: String = "inactive",
    updatedAt: Date = fixtureNow
) -> Device {
    device(
        code, type: "ftl_relay", location: location, stowedIn: stowedIn,
        status: status, features: ["cruise", "relay", "stow"], updatedAt: updatedAt
    )
}

/// The completed `enqueue_print` operation, carrying the printed clone's code
/// under `detail.result.new_device_code` — exactly where
/// `Reconciler.completeOpenOperation` files a completion event's result, and
/// exactly the key `GameSync.deviceRoute` reads to fold the clone into the fleet.
private func printOp(
    id: String = "OP-PRINT",
    on hubCode: String = "AF1",
    status: OperationStatus = .completed,
    newDeviceCode: String? = "RLY1",
    lastConfirmedAt: Date = fixtureNow
) -> GameModels.Operation {
    var detail: [String: JSONValue] = ["device_type": .string("ftl_relay")]
    if let newDeviceCode {
        detail["result"] = .object(["new_device_code": .string(newDeviceCode)])
    }
    return GameModels.Operation(
        id: id, entityCode: hubCode, kind: OperationKind.print.rawValue,
        status: status, source: .event, startedAt: Date(timeIntervalSince1970: 0),
        completesAt: nil, lastConfirmedAt: lastConfirmedAt, detail: .object(detail)
    )
}

private func world(
    devices: [Device],
    openOperations: [String: GameModels.Operation] = [:],
    dispatchedOperations: [String: GameModels.Operation] = [:],
    systems: [String: StarSystem] = [:],
    footprints: [String: LocationFootprint] = [:],
    now: Date = fixtureNow
) -> WorldSnapshot {
    WorldSnapshot(
        devices: Dictionary(devices.map { ($0.deviceCode, $0) }, uniquingKeysWith: { _, last in last }),
        openOperations: openOperations, log: [], dispatchedOperations: dispatchedOperations,
        systems: systems, siteAssays: [:], footprints: footprints, now: now
    )
}

private func footprint(_ location: String, resources: Int, fetchedAt: Date = fixtureNow) -> LocationFootprint {
    LocationFootprint(
        location: location, devices: 1, resources: resources, resourceSites: 0,
        locationEvents: 0, replicants: 0, fetchedAt: fetchedAt
    )
}

/// The target system. Its entry point IS an L4 (true of every system live), so
/// `SalvageRun.lagrangePoint(in:)` resolves to it.
private func targetSystem(_ designation: String = "VEGA") -> StarSystem {
    StarSystem(designation: designation, systemScanned: true, entryPoint: "\(designation)-1-L4")
}

private func running(
    step: String = RelayRun.Step.acquire.rawValue,
    targets: [String] = ["VEGA"],
    targetIndex: Int = 0,
    sourceRelayCode: String? = nil,
    stepStartedAt: Date = Date(timeIntervalSince1970: 900)
) -> Directive {
    Directive(
        id: "D1", kind: .relayRun, status: .running, deviceCode: "V1",
        controllerCode: nil, roamCentre: nil, fleetTag: nil,
        sourceRelayCode: sourceRelayCode, targets: targets, targetIndex: targetIndex,
        step: step, stepStartedAt: stepStartedAt, returnToOrigin: false,
        originDesignation: nil, attentionReason: nil,
        createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0)
    )
}

// MARK: - Registration

@Suite("Relay Run — registration")
struct RelayRunRegistrationTests {
    /// Until this passes the engine leaves every `relayRun` row completely alone
    /// — no writes at all (see `MissionRegistry`'s doc comment). This is the
    /// one-line edit that turns the whole run live.
    @Test func isRegisteredWithTheEngine() {
        #expect(MissionRegistry.machine(for: .relayRun) is RelayRun)
        #expect(MissionRegistry.firstStep(for: .relayRun) == RelayRun.Step.acquire.rawValue)
    }

    @Test func stepVocabularyIsFrozen() {
        #expect(RelayRun.Step.allCases.map(\.rawValue) == [
            "acquire", "printing", "fetching", "deactivating", "confirmingIdle", "stowing",
            "confirmingStow", "travelling", "emplacing", "activating", "confirmingRelay",
            "settling", "returning",
        ])
    }
}

// MARK: - Acquire

@Suite("Relay Run — acquire")
struct RelayRunAcquireTests {
    /// The v1 composition: the print goes to the AUTOFACTORY (a co-located
    /// HEAVEN carrier then takes the clone aboard), so the dispatch names the
    /// hub's device code — not the carrier's.
    @Test func acquireStepEnqueuesAPrintAtTheHub() {
        // The rail is armed by default (`BrainCeiling.aggregateSpendFloor`), so
        // this fixture must clear it with real stock — otherwise the test
        // would be exercising the veto, not the dispatch shape it names.
        let action = RelayRun().nextAction(
            directive: running(step: RelayRun.Step.acquire.rawValue),
            world: world(
                devices: [carrier(), hub()],
                footprints: [hubLocation: footprint(hubLocation, resources: 999_999)]
            )
        )
        guard case let .dispatch(kind, deviceCode, params, next) = action else {
            Issue.record("expected a print dispatch, got \(action)")
            return
        }
        #expect(kind == .print)
        #expect(deviceCode == "AF1")
        #expect(params.deviceType == "ftl_relay")
        // No location and no resource bill ride the call — `enqueue_print`
        // takes a device type and nothing else.
        #expect(params.destination == nil)
        #expect(params.resources == nil)
        #expect(next == RelayRun.Step.printing.rawValue)
    }

    /// A step whose precondition isn't met stalls rather than proceeding: with
    /// no print-capable device where the carrier is, there is nothing to print
    /// at and dispatching anywhere would be a guess.
    @Test func stallsWhenNoPrintHubIsCoLocatedWithTheCarrier() {
        // The hub exists, but somewhere else entirely.
        let snapshot = world(devices: [carrier(), hub(location: "ELSEWHERE-BELT-1")])
        #expect(RelayRun().nextAction(directive: running(), world: snapshot)
                == .stall(.unreachableDevice))
    }

    /// The carrier row itself missing from the fleet is the one stall every
    /// mission shares.
    @Test func stallsWhenTheCarrierIsMissing() {
        #expect(RelayRun().nextAction(directive: running(), world: world(devices: [hub()]))
                == .stall(.unreachableDevice))
    }

    /// The reserve rail is a VETO: it has to run before the command it vetoes,
    /// or the resources are already committed by the time it fires.
    @Test func printStockShortStallsRetry() {
        let snapshot = world(
            devices: [carrier(), hub()],
            footprints: [hubLocation: footprint(hubLocation, resources: 100)]
        )
        // The floor is injected because the calibrated constant is a later
        // task; production ships it unarmed (nil).
        #expect(RelayRun(reserveFloor: 500).nextAction(directive: running(), world: snapshot)
                == .stall(.printStockShort))
        // …and the same world with stock above the floor prints, so the stall
        // is the floor's doing and not the fixture's.
        let stocked = world(
            devices: [carrier(), hub()],
            footprints: [hubLocation: footprint(hubLocation, resources: 900)]
        )
        guard case .dispatch(_, _, _, RelayRun.Step.printing.rawValue) =
                RelayRun(reserveFloor: 500).nextAction(directive: running(), world: stocked)
        else {
            Issue.record("stock above the floor must still print")
            return
        }
    }

    /// Once armed, a hub location with NO census row at all no longer vetoes
    /// immediately — it requests a refresh first (mirroring `HaulRun.survey`'s
    /// gate on the WHOLE table, not just this one row — see
    /// `footprintCensusIsStale`'s doc), because "we couldn't read the stock"
    /// is not evidence either way, and one GET may well clear it. Only once a
    /// reading is actually in hand does the rail form an opinion — see
    /// `printStockShortStallsRetry` for the veto itself,
    /// `printStockIsShortFailsClosedOnAMissingFootprintDirectly` for why the
    /// old "missing → veto" behaviour still exists as the function's own
    /// defense-in-depth contract, and
    /// `persistentlyMissingFootprintEscalatesRatherThanRefreshingForever` for
    /// the proof that a row which never arrives still terminates rather than
    /// refreshing forever. (An *unarmed* rail is a separate case, covered by
    /// `unarmedRailNeverVetoesEvenOnUnknownStock` below — it has no opinion
    /// at all, by design, so it does not even ask for a refresh.)
    @Test func missingFootprintTriggersARefreshRatherThanAnImmediateVeto() {
        let snapshot = world(devices: [carrier(), hub()])
        // thenStall: .printStockShort — this gate MUST escalate rather than
        // retry forever if the census never resolves (round 3's fix). Proven
        // end to end (through the real engine resolver, since "the refresh
        // request itself keeps failing" can only be observed there, not from
        // this pure function) by
        // `RefreshFootprintTests.persistentlyFailingFootprintRefreshEscalatesAfterOneRound`
        // in `DirectiveEngineTests.swift`.
        #expect(RelayRun(reserveFloor: 500).nextAction(directive: running(), world: snapshot)
                == .refreshFootprint(nextStep: RelayRun.Step.acquire.rawValue, thenStall: .printStockShort))
    }

    /// A footprint that IS present but older than the shared poll interval is
    /// treated the same as a missing one — refreshed, not trusted — even
    /// though its stale reading looks comfortably abundant. Old evidence of
    /// abundance is not current evidence of abundance.
    @Test func staleFootprintTriggersARefreshEvenWhenItLooksAbundant() {
        let snapshot = world(
            devices: [carrier(), hub()],
            footprints: [hubLocation: footprint(
                hubLocation, resources: 999_999,
                fetchedAt: fixtureNow.addingTimeInterval(-(RelayRun.pollInterval + 1))
            )]
        )
        #expect(RelayRun(reserveFloor: 500).nextAction(directive: running(), world: snapshot)
                == .refreshFootprint(nextStep: RelayRun.Step.acquire.rawValue, thenStall: .printStockShort))
    }

    /// **The stale-hub-row Minor from review round 3.** A hub whose OWN row
    /// has gone silent — arbitrarily old — while some OTHER location keeps
    /// refreshing (so the table-wide gate above sees a recent `fetchedAt`
    /// and does not retrigger) must NOT have its ancient `resources` reading
    /// trusted as "abundant." `printStockIsShort`'s separate `hubFreshness`
    /// bound catches exactly this, failing closed rather than reopening the
    /// refresh-trigger gate (which would risk the self-loop
    /// `footprintCensusIsStale`'s doc describes).
    @Test func staleHubRowIsNotTrustedEvenWhenTheCensusAsAWholeLooksFresh() {
        let snapshot = world(
            devices: [carrier(), hub()],
            footprints: [
                hubLocation: footprint(
                    hubLocation, resources: 999_999,
                    fetchedAt: fixtureNow.addingTimeInterval(-(RelayRun.hubFreshness + 1))
                ),
                "SOME-OTHER-BELT-1": footprint("SOME-OTHER-BELT-1", resources: 1),
            ]
        )
        #expect(RelayRun(reserveFloor: 500).nextAction(directive: running(), world: snapshot)
                == .stall(.printStockShort))
    }

    /// `printStockIsShort` fails closed on a missing footprint as ITS OWN
    /// contract, independent of `acquire`'s freshness gate — called directly
    /// here (bypassing `nextAction` entirely) so that guarantee stays covered
    /// even though `acquire` no longer reaches it in practice.
    @Test func printStockIsShortFailsClosedOnAMissingFootprintDirectly() {
        let armed = PrintRail(reserveFloor: 500)
        #expect(armed.printStockIsShort(at: hubLocation, world(devices: [carrier(), hub()])))
    }

    /// The stall's log line must name the condition that ACTUALLY fired.
    ///
    /// It used to say `stock <n> below floor <f>` on all three branches, which
    /// is false on two of them — most damagingly on the stale-row branch, where
    /// it printed a reading (999,999) sitting far ABOVE the floor (35,078) as
    /// though it were beneath it, pointing an operator at an imaginary resource
    /// shortage instead of at a census that had stopped listing the hub.
    ///
    /// Asserted on the diagnosis string rather than on the emitted log line
    /// because `os.Logger` output is not readable from a test; the branch
    /// selection — the part that was wrong — is entirely in this function, and
    /// it shares its branch order with `printStockIsShort` by construction.
    @Test func theVetoLogNamesWhichConditionFired() {
        let armed = PrintRail(reserveFloor: 500)

        // Branch 1: no row at all — there is no reading to be "below" anything.
        let missing = armed.printStockShortDiagnosis(at: hubLocation, world(devices: [carrier(), hub()]))
        #expect(missing.contains("no census row"))
        #expect(!missing.contains("below floor"))

        // Branch 2: a present row, abundant, but too old to believe. The AGE is
        // what vetoed, and the line must say so rather than claim a shortage.
        let staleWorld = world(
            devices: [carrier(), hub()],
            footprints: [hubLocation: footprint(
                hubLocation, resources: 999_999,
                fetchedAt: fixtureNow.addingTimeInterval(-(RelayRun.hubFreshness + 60))
            )]
        )
        let stale = armed.printStockShortDiagnosis(at: hubLocation, staleWorld)
        #expect(stale.contains("freshness bound"))
        #expect(stale.contains("360s old"))
        #expect(!stale.contains("below floor"), "an abundant-but-stale reading is not a shortage")

        // Branch 3: the genuine shortage — the only case the old line described
        // correctly, and it must keep describing it.
        let shortWorld = world(
            devices: [carrier(), hub()],
            footprints: [hubLocation: footprint(hubLocation, resources: 12)]
        )
        #expect(armed.printStockShortDiagnosis(at: hubLocation, shortWorld) == "stock 12 below floor 500")

        // The three branches agree with the predicate they explain: each of
        // these worlds really does veto.
        #expect(armed.printStockIsShort(at: hubLocation, staleWorld))
        #expect(armed.printStockIsShort(at: hubLocation, shortWorld))
    }

    /// **Termination proof for the table-wide gate.** A per-location gate
    /// (the shape review round 2 caught) would issue `.refreshFootprint`
    /// forever against a row that never arrives, at the engine's 5s tick —
    /// unthrottled, since `.refreshFootprint(nextStep: .acquire)` self-loops
    /// and `stepStartedAt` can never accumulate against it. Drives `acquire`
    /// across several evaluations, applying the engine's real effect after
    /// each `.refreshFootprint` — the census refresh lands for every OTHER
    /// known location, never this hub's, the pathological case under test —
    /// and asserts the run reaches the terminal `.stall(.printStockShort)`
    /// (positive evidence: the census is fresh and STILL doesn't list the
    /// hub) rather than refreshing without end.
    @Test func persistentlyMissingFootprintEscalatesRatherThanRefreshingForever() {
        var footprints: [String: LocationFootprint] = [:]
        var action: MissionAction = .wait
        for _ in 0..<5 {
            let snapshot = world(devices: [carrier(), hub()], footprints: footprints)
            action = RelayRun(reserveFloor: 500).nextAction(directive: running(), world: snapshot)
            if case .stall = action { break }
            guard case .refreshFootprint = action else {
                Issue.record("expected a refresh or a terminal stall, got \(action)")
                return
            }
            // The census refresh's real effect: EVERY OTHER location the API
            // knows about goes fresh — never the hub's own, since that is
            // exactly the pathological case this test drives.
            footprints["SOME-OTHER-BELT-1"] = footprint("SOME-OTHER-BELT-1", resources: 1)
        }
        #expect(action == .stall(.printStockShort))
    }

    /// Production ships the rail ARMED with `BrainCeiling.aggregateSpendFloor`
    /// — the conservative TOTAL-stock proxy, the closest today's total-only
    /// `LocationFootprint` can get to the true per-type check. This pins that
    /// as a deliberate, live state (not the earlier `nil`-unarmed placeholder)
    /// and proves stock below it actually vetoes end to end, via a FRESH
    /// footprint (a stale/missing one would refresh instead — see the tests
    /// above).
    @Test func theReserveRailIsArmedWithTheCalibratedFloor() {
        // Absolute pin, not a comparison against itself: any future
        // recalibration of `BrainCeiling`'s `K` or reference snapshot must
        // show up here as a diff.
        #expect(BrainCeiling.aggregateSpendFloor == 35_078)
        #expect(RelayRun().reserveFloor == BrainCeiling.aggregateSpendFloor)
        let broke = world(
            devices: [carrier(), hub()],
            footprints: [hubLocation: footprint(hubLocation, resources: 0)]
        )
        #expect(RelayRun().nextAction(directive: running(), world: broke) == .stall(.printStockShort))
    }

    /// The injection seam still lets a caller explicitly disarm the rail (e.g.
    /// a fixture that wants to isolate a different code path from the reserve
    /// check entirely) — and an explicitly unarmed rail keeps its original,
    /// permissive behaviour: no opinion at all, including on stock it never
    /// even managed to read, and no freshness gate either (there is nothing
    /// to refresh FOR). This is the one place "unknown is never short" still
    /// holds, and only because the rail itself is off.
    @Test func unarmedRailNeverVetoesEvenOnUnknownStock() {
        let snapshot = world(devices: [carrier(), hub()])
        guard case .dispatch(.print, "AF1", _, RelayRun.Step.printing.rawValue) =
                RelayRun(reserveFloor: nil).nextAction(directive: running(), world: snapshot)
        else {
            Issue.record("an explicitly unarmed rail must not veto, even on unknown stock")
            return
        }
    }

    /// A positive stock finding is only worth as much as the row behind it. A
    /// hub row nobody has looked at in a while buys one authoritative read
    /// first, carrying a stall so a read that keeps failing surfaces instead of
    /// re-firing forever.
    @Test func refreshesAStaleHubRowBeforePrinting() {
        let stale = world(devices: [carrier(), hub(updatedAt: fixtureNow.addingTimeInterval(-600))])
        #expect(RelayRun().nextAction(directive: running(), world: stale)
                == .refreshDevices(deviceCodes: ["AF1"], thenStall: .unreachableDevice))
    }

    /// A relay already aboard the carrier is a relay this run does not have to
    /// print — 370 units and ~800 s saved, and the shape that makes a relaunch
    /// mid-run idempotent.
    @Test func skipsPrintingWhenARelayIsAlreadyAboard() {
        let snapshot = world(devices: [carrier(), hub(), relay(stowedIn: "V1")])
        #expect(RelayRun().nextAction(directive: running(), world: snapshot)
                == .claimRelay(deviceCode: "RLY1", nextStep: RelayRun.Step.travelling.rawValue))
    }

    /// A row carrying `sourceRelayCode` must never fall through into the print
    /// path and silently spend 370 units printing a relay the plan intended to
    /// RECLAIM for free — the mistake the field exists to prevent.
    @Test func aReclaimSourcedRunNeverPrints() {
        let snapshot = world(
            devices: [carrier(), hub(), relay("OLD", location: "SOMEWHERE-1-L4", status: "relaying")],
            footprints: [hubLocation: footprint(hubLocation, resources: 999_999)]
        )
        let action = RelayRun().nextAction(directive: running(sourceRelayCode: "OLD"), world: snapshot)
        if case let .dispatch(kind, _, _, _) = action {
            #expect(kind != .print, "a reclaim-sourced run must not enqueue a print")
        }
        // …and it is not merely inert either: it routes into the reclaim
        // sub-sequence.
        #expect(action == .advanceStep(nextStep: RelayRun.Step.fetching.rawValue))
    }
}

// MARK: - Acquire, reclaim source

/// The second source a Relay Run may draw from: an existing, useless relay,
/// deactivated where it stands and redeployed at the plant target. Costs no
/// resources at all, which is why the reserve rail must not touch it.
@Suite("Relay Run — reclaim source")
struct RelayRunReclaimTests {
    /// The source relay as the plan found it: deployed, relaying, at an L4 in
    /// a system prune judged useless.
    private static func source(
        _ code: String = "R9",
        location: String? = "DEAD-1-L4",
        status: String = "relaying",
        type: String = "ftl_relay",
        stowedIn: String? = nil,
        updatedAt: Date = fixtureNow
    ) -> Device {
        device(
            code, type: type, location: location, stowedIn: stowedIn, status: status,
            features: ["cruise", "relay", "stow"], updatedAt: updatedAt
        )
    }

    /// **The brief's test, filled in.** Evidence before an irreversible act: a
    /// stale row must never authorise tearing a relay down, so the FIRST thing
    /// a reclaim-sourced `acquire` does is buy one authoritative read of the
    /// source. Only once that read is in hand does the run commit — and what it
    /// commits to is `deactivate` at the source, never `enqueue_print`.
    @Test func reclaimSourceConfirmsThenDeactivates() {
        // A row nobody has looked at since before the freshness bound.
        let stale = world(
            devices: [
                Self.source(updatedAt: fixtureNow.addingTimeInterval(-(RelayRun.reclaimFreshness + 1))),
                carrier(location: "DEAD-1-L4"),
            ]
        )
        #expect(RelayRun().nextAction(directive: running(sourceRelayCode: "R9"), world: stale)
                == .refreshDevices(deviceCodes: ["R9"], thenStall: .unreachableDevice))

        // Once fresh, the run commits — through the fetch leg (the carrier is
        // already standing with the relay here) to the `deactivate` dispatch.
        let fresh = world(devices: [Self.source(), carrier(location: "DEAD-1-L4")])
        #expect(RelayRun().nextAction(directive: running(sourceRelayCode: "R9"), world: fresh)
                == .advanceStep(nextStep: RelayRun.Step.fetching.rawValue))
        #expect(RelayRun().nextAction(
            directive: running(step: RelayRun.Step.fetching.rawValue, sourceRelayCode: "R9"), world: fresh
        ) == .advanceStep(nextStep: RelayRun.Step.deactivating.rawValue))
        #expect(RelayRun().nextAction(
            directive: running(step: RelayRun.Step.deactivating.rawValue, sourceRelayCode: "R9"), world: fresh
        ) == .dispatch(
            kind: OperationKind.simple("deactivate"), deviceCode: "R9",
            params: CommandParams(), nextStep: RelayRun.Step.confirmingIdle.rawValue
        ))
    }

    /// `decommission` destroys the device for its blueprint with no refund
    /// (automation-brain ticket 10). Reclaim must PRESERVE the relay, so the
    /// verb is pinned rather than left to a later edit's judgement.
    @Test func reclaimUsesDeactivateAndNeverDecommission() {
        let fresh = world(devices: [Self.source(), carrier(location: "DEAD-1-L4")])
        guard case let .dispatch(kind, _, _, _) = RelayRun().nextAction(
            directive: running(step: RelayRun.Step.deactivating.rawValue, sourceRelayCode: "R9"), world: fresh
        ) else {
            Issue.record("expected a dispatch")
            return
        }
        #expect(kind.rawValue == "deactivate")
        #expect(kind.rawValue != "decommission")
    }

    /// **The reserve rail must not veto a reclaim.** Reclaim spends nothing, so
    /// a hub whose census reads bone dry — or is missing entirely — has no
    /// bearing on it. Driven with the rail ARMED at its production floor and a
    /// completely empty census, the worst case for the print path.
    @Test func theReserveRailDoesNotVetoAReclaim() {
        // The carrier stands at the hub, so the print path's own preconditions
        // (a co-located, freshly-read hub) are all met — the ONLY thing left to
        // stop it is the rail.
        let broke = world(devices: [Self.source(), carrier(), hub()])
        #expect(RelayRun().nextAction(directive: running(sourceRelayCode: "R9"), world: broke)
                == .advanceStep(nextStep: RelayRun.Step.fetching.rawValue))

        // The SAME world, differing only in the plan hint, does veto — so the
        // bypass above is the source's doing and not the fixture's.
        #expect(RelayRun().nextAction(directive: running(sourceRelayCode: nil), world: broke)
                == .refreshFootprint(nextStep: RelayRun.Step.acquire.rawValue, thenStall: .printStockShort))
    }

    /// A source the confirm-read DISQUALIFIES must not proceed and must not
    /// fall through to printing — it stalls, legibly. `.unreachableDevice`
    /// carries `BrainDisposition.retry`, so the brain re-derives its prune
    /// analysis and this clears itself when a different source is the answer.
    @Test func aDisqualifiedSourceStallsRatherThanProceeding() {
        let cases: [(String, Device)] = [
            // Already inactive — somebody else got there first, or the plan
            // read a stale row.
            ("already inactive", Self.source(status: "inactive")),
            // Stowed aboard something: another run has taken it.
            ("taken aboard", Self.source(location: nil, stowedIn: "V7")),
            // In transit — no location, so nothing to fly to and nothing to
            // stand beside.
            ("in transit", Self.source(location: nil)),
            // The code names something that is not a relay at all.
            ("not a relay", Self.source(type: "mining_drone")),
            // …including one that happens to be stowed aboard our own carrier,
            // which must NOT take the "already aboard" shortcut past the
            // confirm and commit the run to hauling somebody's drone.
            ("a non-relay aboard the carrier", Self.source(location: nil, type: "mining_drone", stowedIn: "V1")),
        ]
        for (label, device) in cases {
            let snapshot = world(devices: [device, carrier(location: "DEAD-1-L4"), hub()])
            let action = RelayRun().nextAction(directive: running(sourceRelayCode: "R9"), world: snapshot)
            #expect(action == .stall(.unreachableDevice), Comment(rawValue: "\(label) must stall"))
        }
        // The same disqualification stops the DISPATCH step too — the gate
        // immediately before the irreversible act, not only the one that
        // committed the trip.
        let moved = world(devices: [Self.source(status: "inactive"), carrier(location: "DEAD-1-L4")])
        #expect(RelayRun().nextAction(
            directive: running(step: RelayRun.Step.deactivating.rawValue, sourceRelayCode: "R9"), world: moved
        ) == .stall(.unreachableDevice))
    }

    /// A source whose row never arrived at all buys ONE authoritative read
    /// carrying a stall, rather than looping or guessing.
    @Test func anAbsentSourceRowIsReadOnceThenStalls() {
        let snapshot = world(devices: [carrier(location: "DEAD-1-L4"), hub()])
        #expect(RelayRun().nextAction(directive: running(sourceRelayCode: "R9"), world: snapshot)
                == .refreshDevices(deviceCodes: ["R9"], thenStall: .unreachableDevice))
    }

    /// The stall's log line must name which condition disqualified the source —
    /// the same rule `printDiagnosis` and `printStockShortDiagnosis` already
    /// follow, and for the same reason: "Device unreachable" describes neither
    /// cause nor remedy. Asserted on the pure diagnosis function, since
    /// `os.Logger` output is not readable from a test.
    @Test func theReclaimRefusalNamesWhichConditionFired() {
        func diagnose(_ devices: [Device]) -> String {
            RelayRun.reclaimDiagnosis("R9", world(devices: devices))
        }
        #expect(diagnose([]).contains("no row"))
        #expect(diagnose([Self.source(type: "mining_drone")]).contains("mining_drone"))
        #expect(diagnose([Self.source(location: nil, stowedIn: "V7")]).contains("V7"))
        #expect(diagnose([Self.source(location: nil)]).contains("no location"))
        #expect(diagnose([Self.source(status: "inactive")]).contains("inactive"))

        // The diagnosis agrees with the predicate it explains: each of those
        // really is disqualified, and the healthy one really is not.
        #expect(RelayRun.sourceIsReclaimable(Self.source()))
        #expect(!RelayRun.sourceIsReclaimable(Self.source(status: "inactive")))
        #expect(!RelayRun.sourceIsReclaimable(Self.source(type: "mining_drone")))
        #expect(!RelayRun.sourceIsReclaimable(Self.source(location: nil, stowedIn: "V7")))
        #expect(!RelayRun.sourceIsReclaimable(Self.source(location: nil)))
    }

    /// **The carrier fetches the relay before anything is done to it.** A relay
    /// deactivated out of reach cannot be stowed, and deactivating it drops its
    /// system out of the mesh — which is how the reclaim's own subject becomes
    /// uncommandable. So the trip happens first, and it is a TRACKED travel, so
    /// re-entering its own step is the safe shape.
    @Test func fliesToTheSourceRelayBeforeDeactivatingIt() {
        let away = world(devices: [Self.source(), carrier(location: hubLocation)])
        #expect(RelayRun().nextAction(
            directive: running(step: RelayRun.Step.fetching.rawValue, sourceRelayCode: "R9"), world: away
        ) == .dispatch(
            kind: .travel, deviceCode: "V1", params: CommandParams(destination: "DEAD-1-L4"),
            nextStep: RelayRun.Step.fetching.rawValue
        ))
        // And the dispatch step refuses to act on a relay the carrier is not
        // standing with, whatever step it is entered from.
        #expect(RelayRun().nextAction(
            directive: running(step: RelayRun.Step.deactivating.rawValue, sourceRelayCode: "R9"), world: away
        ) == .advanceStep(nextStep: RelayRun.Step.fetching.rawValue))
    }

    /// Travel is tracked, so the open op is the guard that stops a second trip
    /// landing on top of the first.
    @Test func waitsWhileTheFetchTripIsUnderWay() {
        let trip = GameModels.Operation(
            id: "OP-T", entityCode: "V1", kind: OperationKind.travel.rawValue,
            status: .active, source: .optimistic, startedAt: Date(timeIntervalSince1970: 0),
            completesAt: nil, lastConfirmedAt: Date(timeIntervalSince1970: 0), detail: .object([:])
        )
        let snapshot = world(
            devices: [Self.source(), carrier(location: hubLocation)], openOperations: ["V1": trip]
        )
        #expect(RelayRun().nextAction(
            directive: running(step: RelayRun.Step.fetching.rawValue, sourceRelayCode: "R9"), world: snapshot
        ) == .wait)
    }

    /// The poll half of the `deactivate` split. Nothing else moves this row —
    /// `deactivate` emits no operation — so a bare wait would sit on a stale
    /// row for the whole deadline and then stall on a relay that is actually
    /// down. Throttled on the row's own `updatedAt`.
    @Test func confirmingIdlePollsAdvancesAndBacksStops() {
        let idle = running(step: RelayRun.Step.confirmingIdle.rawValue, sourceRelayCode: "R9")

        // Down: the relay has stopped relaying, so it may be stowed.
        let down = world(devices: [Self.source(status: "inactive"), carrier(location: "DEAD-1-L4")])
        #expect(RelayRun().nextAction(directive: idle, world: down)
                == .advanceStep(nextStep: RelayRun.Step.stowing.rawValue))

        // Still relaying and the row is fresh: wait.
        let up = world(devices: [Self.source(), carrier(location: "DEAD-1-L4")])
        #expect(RelayRun().nextAction(directive: idle, world: up) == .wait)

        // Still relaying and the row is old: force the read.
        let unread = world(devices: [
            Self.source(updatedAt: fixtureNow.addingTimeInterval(-(RelayRun.pollInterval + 1))),
            carrier(location: "DEAD-1-L4"),
        ])
        #expect(RelayRun().nextAction(directive: idle, world: unread)
                == .refreshDevices(deviceCodes: ["R9"], thenStall: nil))

        // …and a `deactivate` that never takes is backstopped rather than
        // waited on forever.
        let overdue = running(
            step: RelayRun.Step.confirmingIdle.rawValue, sourceRelayCode: "R9",
            stepStartedAt: fixtureNow.addingTimeInterval(-RelayRun.reclaimDeadline - 1)
        )
        #expect(RelayRun().nextAction(directive: overdue, world: up) == .stall(.unreachableDevice))
    }

    /// **The safety precondition the whole reclaim path rests on, made
    /// checkable.** Deactivating the source de-meshes its system `S`, so the
    /// authority to then issue `stow` at `S` comes from the CARRIER being
    /// there — and only because the carrier hosts a replicant (authority rule
    /// (1), a replicant physically present). Nothing in `Directive`,
    /// `WorldSnapshot` or `WorldView` carries replicants, so that precondition
    /// cannot be asserted directly. `in_control_range` is the server's own
    /// answer to the same question and IS on every device row, so the gate
    /// reads that instead — the shape `brain-primitive-contracts` already
    /// mandates for `deliver`'s tail.
    @Test func refusesToStowWhenTheCarrierIsOutOfControlRangeAfterTheDeactivate() {
        let idle = running(step: RelayRun.Step.confirmingIdle.rawValue, sourceRelayCode: "R9")
        let down = Self.source(status: "inactive")

        // Out of range: `stow` would be dispatched into the void, stranding
        // both the relay and the carrier. Refuse, loudly.
        #expect(RelayRun().nextAction(
            directive: idle,
            world: world(devices: [down, carrier(location: "DEAD-1-L4", controlRange: false)])
        ) == .stall(.unreachableDevice))

        // In range: proceed.
        #expect(RelayRun().nextAction(
            directive: idle,
            world: world(devices: [down, carrier(location: "DEAD-1-L4", controlRange: true)])
        ) == .advanceStep(nextStep: RelayRun.Step.stowing.rawValue))

        // Field absent: `Device.isOutOfControlRange` treats a missing field as
        // "not out of range" — a device type that never reports it must not be
        // read as stranded — so the gate is permissive here by construction.
        #expect(RelayRun().nextAction(
            directive: idle, world: world(devices: [down, carrier(location: "DEAD-1-L4")])
        ) == .advanceStep(nextStep: RelayRun.Step.stowing.rawValue))
    }

    /// The gate is only worth as much as the row behind it, and this is the
    /// last moment before a command issued at a system the mesh no longer
    /// reaches. A carrier row nobody has looked at recently buys ONE
    /// authoritative read, carrying a stall so a read that keeps failing
    /// surfaces instead of re-firing.
    @Test func readsAStaleCarrierRowBeforeTrustingTheAuthorityGate() {
        let snapshot = world(devices: [
            Self.source(status: "inactive"),
            carrier(
                location: "DEAD-1-L4",
                updatedAt: fixtureNow.addingTimeInterval(-(RelayRun.reclaimFreshness + 1)),
                controlRange: true
            ),
        ])
        #expect(RelayRun().nextAction(
            directive: running(step: RelayRun.Step.confirmingIdle.rawValue, sourceRelayCode: "R9"),
            world: snapshot
        ) == .refreshDevices(deviceCodes: ["V1"], thenStall: .unreachableDevice))
    }

    /// **The discriminating case: young is not the same as AFTER.**
    ///
    /// A wall-clock freshness bound alone is the wrong key for this gate, and
    /// on the NORMAL timeline it reads exactly the wrong row. The carrier's row
    /// is written on arrival at `fetching`, while the mesh is still up — so it
    /// reports `in_control_range: true` even for a carrier that would lose
    /// authority the moment the relay goes down. `deactivating` then dispatches
    /// at the RELAY, and `CommandClient`'s `.immediate` path confirm-reads only
    /// the commanded device, so nothing reads the carrier at all. `deactivate`
    /// is immediate server-side, so `confirmingIdle` typically sees the relay
    /// non-relaying seconds later — with a carrier row that is seconds old,
    /// comfortably inside the 5-minute bound, and entirely PRE-deactivate.
    ///
    /// So the gate must key on the watermark, not the age:
    /// `carrier.updatedAt >= directive.stepStartedAt`. `stepStartedAt` for
    /// `confirmingIdle` IS the deactivate dispatch instant, because
    /// `DirectiveExecutor` re-stamps it on every accepted dispatch — the
    /// watermark is free. This is the same rule
    /// `confirm-steps-need-fresh-evidence` states and that this file already
    /// applies two lines above the gate's call site.
    ///
    /// This fixture is the one that tells the two keys apart: the carrier row
    /// is 200 s old — well inside `reclaimFreshness` — but predates
    /// `stepStartedAt`, so it is pre-deactivate evidence. A wall-clock-only
    /// gate advances to `stowing` here; a watermark gate buys the read.
    @Test func aFreshButPreDeactivateCarrierRowIsNotEvidence() {
        let directive = running(step: RelayRun.Step.confirmingIdle.rawValue, sourceRelayCode: "R9")
        // Sanity-pin the fixture's own premise, so this test cannot quietly
        // stop discriminating if the shared fixtures move.
        let carrierRow = carrier(
            location: "DEAD-1-L4",
            updatedAt: directive.stepStartedAt.addingTimeInterval(-100),
            controlRange: true
        )
        #expect(carrierRow.updatedAt < directive.stepStartedAt, "the row must predate the deactivate")
        #expect(fixtureNow.timeIntervalSince(carrierRow.updatedAt) < RelayRun.reclaimFreshness,
                "…while still being young enough that a wall-clock gate would accept it")

        #expect(RelayRun().nextAction(
            directive: directive,
            world: world(devices: [Self.source(status: "inactive"), carrierRow])
        ) == .refreshDevices(deviceCodes: ["V1"], thenStall: .unreachableDevice))

        // And the same row moved to just AFTER the deactivate is accepted — so
        // the refusal above is the watermark's doing, not the fixture's.
        let after = carrier(
            location: "DEAD-1-L4",
            updatedAt: directive.stepStartedAt.addingTimeInterval(1),
            controlRange: true
        )
        #expect(RelayRun().nextAction(
            directive: directive,
            world: world(devices: [Self.source(status: "inactive"), after])
        ) == .advanceStep(nextStep: RelayRun.Step.stowing.rawValue))
    }

    /// **The mesh race, which costs a RECLAIM run something it costs a print
    /// run nothing.** If the target gets meshed by somebody else while the
    /// carrier is in flight, `travelling` skips straight to `settling` and the
    /// run reports `.done`. On the print path that is a pure saving. On the
    /// reclaim path the run has ALREADY de-meshed the source's system, so
    /// finishing here leaves the fleet one mesh node down and calls it success.
    /// It stays `.done` — the deliverable really is met and the relay is
    /// preserved in the hold for the next run — but it must not be silent.
    @Test func aReclaimThatLosesTheMeshRaceIsNotReportedAsAPlainSuccess() {
        // VEGA is meshed by somebody else's relay; ours is aboard the carrier.
        let snapshot = world(devices: [
            carrier(location: "VEGA"),
            Self.source(location: nil, status: "inactive", stowedIn: "V1"),
            relay("OTHER", location: "VEGA-1-L4", status: "relaying"),
        ])
        #expect(RelayRun().nextAction(
            directive: running(step: RelayRun.Step.travelling.rawValue, sourceRelayCode: "R9"), world: snapshot
        ) == .advanceStep(nextStep: RelayRun.Step.settling.rawValue))

        // The outcome is named rather than passed over…
        let loss = RelayRun.meshRaceLoss(running(sourceRelayCode: "R9"), target: "VEGA")
        #expect(loss?.contains("VEGA") == true)
        #expect(loss?.contains("net") == true)
        // …and a PRINT-sourced run, which loses nothing at all, says nothing.
        #expect(RelayRun.meshRaceLoss(running(sourceRelayCode: nil), target: "VEGA") == nil)

        // WHAT THIS TEST DOES NOT COVER, stated so it does not look covered:
        // the two assertions above pin the diagnosis (its inputs and its
        // message) and the `.settling` advance, but NOT the `logger.warning`
        // emission that sits between them in `travel`. `logger` is a
        // file-private `os.Logger`, as in every mission machine, with no seam
        // to intercept — deleting the call site leaves this suite green. The
        // call site carries the same note.
    }

    /// Re-entering `acquire` after the relay is already aboard must not start
    /// the reclaim over — the same idempotence the print path gets from its
    /// "a relay already aboard" check.
    @Test func reEnteringAcquireWithTheRelayAboardSkipsStraightToTravel() {
        let snapshot = world(devices: [Self.source(location: nil, stowedIn: "V1"), carrier()])
        #expect(RelayRun().nextAction(directive: running(sourceRelayCode: "R9"), world: snapshot)
                == .advanceStep(nextStep: RelayRun.Step.travelling.rawValue))
    }

    /// **The shared tail is REUSED, not forked.** Every step after the stow is
    /// the print path's own, which only works because the relay lookup resolves
    /// the plan-named source by CODE — through stowed, in-transit, deployed and
    /// relaying, exactly as the printed clone's code-first lookup does.
    @Test func theSharedTailResolvesThePlanNamedRelayInEveryState() {
        let reclaim = running(sourceRelayCode: "R9")
        let states: [(String, Device)] = [
            ("aboard", Self.source(location: nil, stowedIn: "V1")),
            ("deployed", Self.source(location: "VEGA-1-L4", status: "inactive")),
            ("relaying", Self.source(location: "VEGA-1-L4")),
        ]
        for (label, device) in states {
            let snapshot = world(devices: [device, carrier(location: "VEGA-1-L4")])
            #expect(
                RelayRun.relay(for: reclaim, carrier: carrier(location: "VEGA-1-L4"), in: snapshot)?
                    .deviceCode == "R9",
                Comment(rawValue: "the \(label) source must stay resolvable")
            )
        }
        // A `sourceRelayCode` naming something that is not a relay is never
        // adopted — the same type filter every other lookup in this file applies,
        // because whatever this returns gets a command issued at it.
        let wrong = world(devices: [
            Self.source(type: "mining_drone", stowedIn: "V1"), carrier(),
        ])
        #expect(RelayRun.relay(for: reclaim, carrier: carrier(), in: wrong) == nil)
    }

    /// A PRINT-sourced run is completely unaffected by any of this: the same
    /// world that would resolve a reclaim's source leaves the print path
    /// resolving its clone and enqueuing its print exactly as before.
    @Test func aPrintSourcedRunIsUnaffected() {
        let snapshot = world(
            devices: [carrier(), hub(), Self.source()],
            footprints: [hubLocation: footprint(hubLocation, resources: 999_999)]
        )
        #expect(RelayRun().nextAction(directive: running(sourceRelayCode: nil), world: snapshot)
                == .dispatch(
                    kind: .print, deviceCode: "AF1",
                    params: CommandParams(deviceType: "ftl_relay"), nextStep: RelayRun.Step.printing.rawValue
                ))
        // …and its relay lookup still ignores the deployed relay standing
        // elsewhere, exactly as it did before the reclaim branch existed.
        #expect(RelayRun.relay(for: running(), carrier: carrier(), in: snapshot) == nil)
    }

    /// The reclaim steps belong to a reclaim run. A row that reaches one with
    /// no `sourceRelayCode` re-derives its branch from `acquire` rather than
    /// acting on a source it does not have.
    @Test func reclaimStepsWithoutASourceReturnToAcquire() {
        let snapshot = world(devices: [carrier(), hub()])
        for step in [RelayRun.Step.fetching.rawValue, RelayRun.Step.deactivating.rawValue, RelayRun.Step.confirmingIdle.rawValue] {
            #expect(RelayRun().nextAction(directive: running(step: step), world: snapshot)
                    == .advanceStep(nextStep: RelayRun.Step.acquire.rawValue),
                    Comment(rawValue: "step \(step) without a source must return to acquire"))
        }
    }
}

// MARK: - Printing

@Suite("Relay Run — printing")
struct RelayRunPrintingTests {
    @Test func waitsWhileThePrintJobIsStillOpen() {
        let open = printOp(status: .enqueued, newDeviceCode: nil)
        let snapshot = world(
            devices: [carrier(), hub()],
            dispatchedOperations: [open.id: open]
        )
        #expect(RelayRun().nextAction(directive: running(step: RelayRun.Step.printing.rawValue), world: snapshot) == .wait)
    }

    /// Completion is detected off the print op's `new_device_code` result, not
    /// off "a relay appeared at the hub" — the live hub already has two idle
    /// relays parked at it, and a presence check would read one of those as this
    /// run's clone and skip the print entirely.
    @Test func advancesOnceThePrintedCloneIsInTheFleet() {
        let done = printOp()
        let snapshot = world(
            devices: [carrier(), hub(), relay(location: hubLocation)],
            dispatchedOperations: [done.id: done]
        )
        #expect(RelayRun().nextAction(directive: running(step: RelayRun.Step.printing.rawValue), world: snapshot)
                == .advanceStep(nextStep: RelayRun.Step.stowing.rawValue))
    }

    /// The clone's row arrives by a `.high` read that `GameSync` fires off
    /// `print.completed`. If that read hasn't landed, the code is known but the
    /// row isn't — buy the read here rather than treating it as a failed print.
    /// It carries a stall so a read that keeps failing surfaces after ONE round
    /// instead of re-firing every tick for the whole print deadline.
    @Test func readsTheCloneWhenItsCodeIsKnownButItsRowIsNot() {
        let done = printOp()
        let snapshot = world(devices: [carrier(), hub()], dispatchedOperations: [done.id: done])
        #expect(RelayRun().nextAction(directive: running(step: RelayRun.Step.printing.rawValue), world: snapshot)
                == .refreshDevices(deviceCodes: ["RLY1"], thenStall: .noRelayCoLocated))
    }

    /// **The shared-queue mix-up.** The hub's print queue is never leased and
    /// `acquire` deliberately queues behind whatever is in it. When the job
    /// AHEAD of ours finishes, `Reconciler.completeOpenOperation` closes the
    /// single open op on the hub — OURS — and stamps ITS `new_device_code` onto
    /// it. Unfiltered, that code gets adopted: `stow` at a foreign live device,
    /// hauled to another system, and only the eventual `deploy` rejection stops
    /// it. So the clone must be type-checked before it is adopted.
    @Test func doesNotAdoptANonRelayCloneFromTheSharedQueue() {
        let foreign = printOp(newDeviceCode: "DRONE9")
        let snapshot = world(
            devices: [carrier(), hub(), device("DRONE9", type: "mining_drone", location: hubLocation)],
            dispatchedOperations: [foreign.id: foreign]
        )
        // Inside the deadline it keeps waiting — it does NOT advance to stowing.
        #expect(RelayRun().nextAction(directive: running(step: RelayRun.Step.printing.rawValue), world: snapshot) == .wait)
        // And it does not burn reads on a row that is present and simply is not
        // ours: re-reading a mining drone will never make it a relay.
        #expect(RelayRun.printedRelay(in: snapshot) == nil)
    }

    /// The same mix-up seen from the step that would issue the command. With no
    /// relay aboard and none co-located, nothing may be dispatched at the
    /// foreign device the print named.
    @Test func neverDispatchesStowAtANonRelayClone() {
        let foreign = printOp(newDeviceCode: "DRONE9")
        let snapshot = world(
            devices: [carrier(), hub(), device("DRONE9", type: "mining_drone", location: hubLocation)],
            dispatchedOperations: [foreign.id: foreign]
        )
        #expect(RelayRun().nextAction(directive: running(step: RelayRun.Step.stowing.rawValue), world: snapshot)
                == .stall(.noRelayCoLocated))
    }

    /// …and when a genuine relay IS aboard, the type filter must fall through to
    /// it rather than returning the foreign device — the parity with the two
    /// fallback lookups, which have always filtered on type.
    @Test func fallsThroughToTheRealRelayWhenThePrintNamedSomethingElse() {
        let foreign = printOp(newDeviceCode: "DRONE9")
        let snapshot = world(
            devices: [
                carrier(), hub(),
                device("DRONE9", type: "mining_drone", location: hubLocation),
                relay(stowedIn: "V1"),
            ],
            dispatchedOperations: [foreign.id: foreign]
        )
        #expect(RelayRun.relay(for: running(), carrier: carrier(), in: snapshot)?.deviceCode == "RLY1")
    }

    /// A print that never produces a relay is a dead run: the whole trip exists
    /// to plant one. Backstopped rather than waited on forever.
    @Test func stallsWhenThePrintDeadlinePasses() {
        let snapshot = world(devices: [carrier(), hub()], now: fixtureNow)
        let overdue = running(
            step: RelayRun.Step.printing.rawValue,
            stepStartedAt: fixtureNow.addingTimeInterval(-PrintJob.deadline - 1)
        )
        #expect(RelayRun().nextAction(directive: overdue, world: snapshot) == .stall(.noRelayCoLocated))
    }

    /// …and inside the deadline the same barren world merely waits, so the
    /// stall above is the deadline's doing.
    @Test func waitsInsideThePrintDeadline() {
        let snapshot = world(devices: [carrier(), hub()])
        #expect(RelayRun().nextAction(directive: running(step: RelayRun.Step.printing.rawValue), world: snapshot) == .wait)
    }

    /// A superseded print op is fail-safe — no loop, no spend — but it is
    /// otherwise INVISIBLE: `.superseded` is neither `.completed` nor open, so
    /// the run degrades to a silent 30-minute wait and then stalls with a reason
    /// whose display name ("No relay aboard") names neither cause nor remedy.
    /// The stall carries a diagnosis so the shared-queue cause is recoverable
    /// from the log. Asserted as a pure function rather than by scraping logs.
    @Test func namesTheCauseWhenThePrintProducesNothing() {
        let superseded = printOp(status: .superseded, newDeviceCode: nil)
        let world1 = world(devices: [carrier(), hub()], dispatchedOperations: [superseded.id: superseded])
        #expect(RelayRun.printDiagnosis(in: world1).contains("superseded"))

        let foreign = printOp(newDeviceCode: "DRONE9")
        let world2 = world(
            devices: [carrier(), hub(), device("DRONE9", type: "mining_drone", location: hubLocation)],
            dispatchedOperations: [foreign.id: foreign]
        )
        #expect(RelayRun.printDiagnosis(in: world2).contains("mining_drone"))

        let missing = printOp(newDeviceCode: "GHOST")
        let world3 = world(devices: [carrier(), hub()], dispatchedOperations: [missing.id: missing])
        #expect(RelayRun.printDiagnosis(in: world3).contains("GHOST"))

        #expect(RelayRun.printDiagnosis(in: world(devices: [carrier(), hub()]))
                    .contains("no print was ever dispatched"))
    }

    /// A superseded op still reaches the deadline stall rather than looping or
    /// re-spending — the fail-safe half of the behaviour above.
    @Test func stallsOnASupersededPrintRatherThanReprinting() {
        let superseded = printOp(status: .superseded, newDeviceCode: nil)
        let snapshot = world(devices: [carrier(), hub()], dispatchedOperations: [superseded.id: superseded])
        let overdue = running(
            step: RelayRun.Step.printing.rawValue,
            stepStartedAt: fixtureNow.addingTimeInterval(-PrintJob.deadline - 1)
        )
        #expect(RelayRun().nextAction(directive: overdue, world: snapshot) == .stall(.noRelayCoLocated))
    }
}

// MARK: - Stowing

@Suite("Relay Run — stowing")
struct RelayRunStowingTests {
    @Test func dispatchesStowAtTheRelayNamingTheCarrier() {
        let done = printOp()
        let snapshot = world(
            devices: [carrier(), hub(), relay(location: hubLocation)],
            dispatchedOperations: [done.id: done]
        )
        let action = RelayRun().nextAction(directive: running(step: RelayRun.Step.stowing.rawValue), world: snapshot)
        guard case let .dispatch(kind, deviceCode, params, next) = action else {
            Issue.record("expected a stow dispatch, got \(action)")
            return
        }
        #expect(kind == .stow)
        // The command is issued ON the device being stowed, with the carrier as
        // its `target` — the inverse would stow the vessel into the relay.
        #expect(deviceCode == "RLY1")
        #expect(params.target == "V1")
        #expect(next == RelayRun.Step.confirmingStow.rawValue)
    }

    /// The composition's premise: a co-located HEAVEN carrier may take the clone
    /// aboard on its own. If it already has, re-issuing `stow` is a pointless
    /// POST at a device that is already where it belongs.
    @Test func skipsTheStowWhenTheCarrierAlreadyTookTheCloneAboard() {
        let done = printOp()
        let snapshot = world(
            devices: [carrier(), hub(), relay(stowedIn: "V1")],
            dispatchedOperations: [done.id: done]
        )
        #expect(RelayRun().nextAction(directive: running(step: RelayRun.Step.stowing.rawValue), world: snapshot)
                == .claimRelay(deviceCode: "RLY1", nextStep: RelayRun.Step.travelling.rawValue))
    }

    /// A relay that is neither aboard nor anywhere near the carrier cannot be
    /// stowed onto it; surfacing beats POSTing a command that must be rejected.
    @Test func stallsWhenTheRelayIsNotCoLocatedWithTheCarrier() {
        let done = printOp()
        let snapshot = world(
            devices: [carrier(), hub(), relay(location: "FAR-BELT-9")],
            dispatchedOperations: [done.id: done]
        )
        #expect(RelayRun().nextAction(directive: running(step: RelayRun.Step.stowing.rawValue), world: snapshot)
                == .stall(.noRelayCoLocated))
    }
}

// MARK: - Confirming the stow

@Suite("Relay Run — confirmingStow")
struct RelayRunConfirmStowTests {
    /// The poll reads the RELAY's own `stowedInDeviceCode` column. A carrier's
    /// `stowed_devices` blob is not a reliable inverse of it (a live vessel's
    /// blob listed one unrelated device while six drones claimed to be aboard).
    @Test func advancesOnceTheRelayReportsItselfAboard() {
        let done = printOp()
        let snapshot = world(
            devices: [carrier(), hub(), relay(stowedIn: "V1")],
            dispatchedOperations: [done.id: done]
        )
        #expect(RelayRun().nextAction(directive: running(step: RelayRun.Step.confirmingStow.rawValue), world: snapshot)
                == .claimRelay(deviceCode: "RLY1", nextStep: RelayRun.Step.travelling.rawValue))
    }

    /// Nothing else moves this row: `stow` is immediate and emits no operation,
    /// so a bare wait would sit on a stale row until the deadline and then stall
    /// on a relay that is actually aboard. Force the read, throttled on the
    /// row's own `updatedAt`.
    @Test func readsTheRelayRowWhileItPolls() {
        let done = printOp()
        let snapshot = world(
            devices: [
                carrier(), hub(),
                relay(location: hubLocation, updatedAt: fixtureNow.addingTimeInterval(-120)),
            ],
            dispatchedOperations: [done.id: done]
        )
        #expect(RelayRun().nextAction(directive: running(step: RelayRun.Step.confirmingStow.rawValue), world: snapshot)
                == .refreshDevices(deviceCodes: ["RLY1"], thenStall: nil))
    }

    @Test func stallsWhenTheStowNeverTakes() {
        let done = printOp()
        let snapshot = world(
            devices: [carrier(), hub(), relay(location: hubLocation)],
            dispatchedOperations: [done.id: done]
        )
        let overdue = running(
            step: RelayRun.Step.confirmingStow.rawValue,
            stepStartedAt: fixtureNow.addingTimeInterval(-RelayRun.stowDeadline - 1)
        )
        #expect(RelayRun().nextAction(directive: overdue, world: snapshot) == .stall(.noRelayCoLocated))
    }
}

// MARK: - Travelling

@Suite("Relay Run — travelling")
struct RelayRunTravelTests {
    @Test func dispatchesTravelToTheTargetSystem() {
        let snapshot = world(devices: [carrier(), hub(), relay(stowedIn: "V1")])
        let action = RelayRun().nextAction(directive: running(step: RelayRun.Step.travelling.rawValue), world: snapshot)
        #expect(action == .dispatch(
            kind: .travel, deviceCode: "V1", params: CommandParams(destination: "VEGA"),
            nextStep: RelayRun.Step.travelling.rawValue
        ))
    }

    /// Travel is a TRACKED kind, so an open op is the guard that stops a second
    /// trip landing on top of the first — the reason a same-step travel
    /// redispatch is safe where a `.simple` one never is.
    @Test func waitsWhileTheTripIsUnderWay() {
        let travelling = GameModels.Operation(
            id: "OP-T", entityCode: "V1", kind: OperationKind.travel.rawValue,
            status: .active, source: .optimistic, startedAt: Date(timeIntervalSince1970: 0),
            completesAt: nil, lastConfirmedAt: Date(timeIntervalSince1970: 0), detail: .object([:])
        )
        let snapshot = world(
            devices: [carrier(), hub(), relay(stowedIn: "V1")],
            openOperations: ["V1": travelling]
        )
        #expect(RelayRun().nextAction(directive: running(step: RelayRun.Step.travelling.rawValue), world: snapshot) == .wait)
    }

    @Test func advancesToEmplacingOnArrival() {
        let snapshot = world(devices: [carrier(location: "VEGA"), relay(stowedIn: "V1")])
        #expect(RelayRun().nextAction(directive: running(step: RelayRun.Step.travelling.rawValue), world: snapshot)
                == .advanceStep(nextStep: RelayRun.Step.emplacing.rawValue))
    }
}

// MARK: - Emplacing

@Suite("Relay Run — emplacing")
struct RelayRunEmplaceTests {
    @Test func fliesToTheTargetsLagrangePointFirst() {
        let snapshot = world(
            devices: [carrier(location: "VEGA"), relay(stowedIn: "V1")],
            systems: ["VEGA": targetSystem()]
        )
        #expect(RelayRun().nextAction(directive: running(step: RelayRun.Step.emplacing.rawValue), world: snapshot)
                == .dispatch(
                    kind: .travel, deviceCode: "V1",
                    params: CommandParams(destination: "VEGA-1-L4"),
                    nextStep: RelayRun.Step.emplacing.rawValue
                ))
    }

    @Test func deploysTheRelayOnceAtThePoint() {
        let snapshot = world(
            devices: [carrier(location: "VEGA-1-L4"), relay(stowedIn: "V1")],
            systems: ["VEGA": targetSystem()]
        )
        #expect(RelayRun().nextAction(directive: running(step: RelayRun.Step.emplacing.rawValue), world: snapshot)
                == .dispatch(
                    kind: OperationKind.simple("deploy"), deviceCode: "RLY1",
                    params: CommandParams(), nextStep: RelayRun.Step.activating.rawValue
                ))
    }

    /// An uncached catalogue blob is "we don't know yet", never "this system has
    /// no Lagrange point" — the two collapse to the same nil if left
    /// unstructured, and acting on the second would silently forfeit the mesh.
    @Test func waitsWhenTheTargetSystemIsNotCachedYet() {
        let snapshot = world(devices: [carrier(location: "VEGA"), relay(stowedIn: "V1")])
        #expect(RelayRun().nextAction(directive: running(step: RelayRun.Step.emplacing.rawValue), world: snapshot) == .wait)
    }

    /// Past the deadline the backstop reads the catalogue while
    /// `systemUnresolvedRetryWindow` still allows it, so the stall's own
    /// guidance ("Retry to fetch it again") is true rather than a dead end.
    @Test func readsTheCatalogueOnceTheResolutionDeadlinePasses() {
        let snapshot = world(devices: [carrier(location: "VEGA"), relay(stowedIn: "V1")])
        let overdue = running(
            step: RelayRun.Step.emplacing.rawValue,
            stepStartedAt: fixtureNow.addingTimeInterval(-SalvageRun.systemResolutionDeadline - 1)
        )
        #expect(RelayRun().nextAction(directive: overdue, world: snapshot)
                == .refreshSystem(designation: "VEGA", nextStep: RelayRun.Step.emplacing.rawValue))
    }

    /// Past `systemUnresolvedRetryWindow` too, the run surfaces rather than
    /// reading forever — `stepStartedAt` alone bounds it, since a same-step
    /// `.refreshSystem` leaves it untouched every tick.
    @Test func stallsWhenTheTargetSystemNeverResolves() {
        let snapshot = world(devices: [carrier(location: "VEGA"), relay(stowedIn: "V1")])
        let overdue = running(
            step: RelayRun.Step.emplacing.rawValue,
            stepStartedAt: fixtureNow.addingTimeInterval(
                -(SalvageRun.systemResolutionDeadline + SalvageRun.systemUnresolvedRetryWindow + 1)
            )
        )
        #expect(RelayRun().nextAction(directive: overdue, world: snapshot) == .stall(.salvageSystemUnresolved))
    }

    /// Same invariant as `SalvageRun`'s own copy: the read is confined to
    /// `unresolvedReadBand`, not spent on every tick of
    /// `systemUnresolvedRetryWindow` — walked at the engine's 5s cadence.
    @Test func readsOnlyInsideTheBandAcrossTheWholeRetryWindow() {
        let stepStartedAt = Date(timeIntervalSince1970: 0)
        let span = SalvageRun.systemResolutionDeadline + SalvageRun.systemUnresolvedRetryWindow
        var reads = 0
        var sawTheStall = false
        var elapsed = SalvageRun.systemResolutionDeadline - 10
        while elapsed <= span + 10 {
            let snapshot = world(
                devices: [carrier(location: "VEGA"), relay(stowedIn: "V1")],
                now: stepStartedAt.addingTimeInterval(elapsed)
            )
            let directive = running(step: RelayRun.Step.emplacing.rawValue, stepStartedAt: stepStartedAt)
            switch RelayRun().nextAction(directive: directive, world: snapshot) {
            case .refreshSystem: reads += 1
            case .stall(.salvageSystemUnresolved, nil): sawTheStall = true
            case .wait: break
            default: Issue.record("unexpected action at elapsed \(elapsed)")
            }
            elapsed += 5
        }
        #expect(reads >= 1)
        #expect(reads <= Int(SalvageRun.unresolvedReadBand / 5))
        #expect(sawTheStall)
    }

    /// An engine tick is `5s + evaluation`, so two evaluations can straddle the
    /// band. Whatever the phase, the read must still fire — a skipped band
    /// stalls the run without ever spending the read that could clear it.
    @Test func readsEvenWhenTheTickPeriodStraddlesTheBand() {
        let stepStartedAt = Date(timeIntervalSince1970: 0)
        let span = SalvageRun.systemResolutionDeadline + SalvageRun.systemUnresolvedRetryWindow
        for phase in stride(from: 0.0, to: 5.0, by: 0.5) {
            var reads = 0
            var elapsed = SalvageRun.systemResolutionDeadline - 10 + phase
            while elapsed <= span {
                let snapshot = world(
                    devices: [carrier(location: "VEGA"), relay(stowedIn: "V1")],
                    now: stepStartedAt.addingTimeInterval(elapsed)
                )
                let directive = running(step: RelayRun.Step.emplacing.rawValue, stepStartedAt: stepStartedAt)
                if case .refreshSystem = RelayRun().nextAction(directive: directive, world: snapshot) {
                    reads += 1
                }
                elapsed += 6.5   // a 5s tick plus a slow evaluation
            }
            #expect(reads >= 1, "phase \(phase) skipped the band entirely")
        }
    }
}

// MARK: - Activating and confirming

@Suite("Relay Run — activating")
struct RelayRunActivateTests {
    /// `deploy` clears `stowedInDeviceCode` the instant it lands, so the relay
    /// must be resolved by where it now IS — resolving it by what is stowed
    /// stops working at exactly the point this step needs it.
    @Test func dispatchesActivateAtTheDeployedRelay() {
        let snapshot = world(devices: [carrier(location: "VEGA-1-L4"), relay(location: "VEGA-1-L4")])
        #expect(RelayRun().nextAction(directive: running(step: RelayRun.Step.activating.rawValue), world: snapshot)
                == .dispatch(
                    kind: OperationKind.simple("activate"), deviceCode: "RLY1",
                    params: CommandParams(), nextStep: RelayRun.Step.confirmingRelay.rawValue
                ))
    }

    @Test func stallsWhenTheDeployedRelayCannotBeFound() {
        let snapshot = world(devices: [carrier(location: "VEGA-1-L4")])
        #expect(RelayRun().nextAction(directive: running(step: RelayRun.Step.activating.rawValue), world: snapshot)
                == .stall(.relayActivationFailed))
    }

    /// `SalvageRun.activate` gets this proof for free: it resolves through
    /// `deployedRelay(near:)`, which requires the relay's location to equal the
    /// vessel's, and a stowed device has no location — so a `deploy` that never
    /// took cannot reach the dispatch. Resolving by printed code is right for
    /// other reasons but loses that, so it is restored explicitly: activating
    /// cargo is not a thing this run may do.
    @Test func refusesToActivateARelayStillAboardTheCarrier() {
        let done = printOp()
        let snapshot = world(
            devices: [carrier(location: "VEGA-1-L4"), relay(stowedIn: "V1")],
            dispatchedOperations: [done.id: done]
        )
        #expect(RelayRun().nextAction(directive: running(step: RelayRun.Step.activating.rawValue), world: snapshot)
                == .stall(.relayActivationFailed))
    }

    /// **The live stall of 2026-08-05, and the mirror of
    /// `emplacingHandsOffWhenTheDeployAlreadyTook` that was missing.**
    ///
    /// A relay run to ACRUB dispatched `activate`; the network dropped before
    /// the response came back, but the command had already reached the server.
    /// The run stalled `commandRejected`, the brain retried, `activating`
    /// re-dispatched blind, and the server answered — correctly — "Relay is
    /// already active". That is not a failure: it is the run's own work,
    /// reported back to it. The loop was closed and permanent: retry →
    /// dispatch → reject → stall → retry, five times over seven hours, beside
    /// a relay that was `relaying` at `ACRUB-3-L4` the whole time.
    ///
    /// `deploy` has had this guard since the emplace path was written. Its
    /// twin one command later did not.
    @Test func activatingHandsOffWhenTheRelayIsAlreadyUp() {
        let snapshot = world(devices: [
            carrier(location: "VEGA-1-L4"), relay(location: "VEGA-1-L4", status: "relaying"),
        ])
        #expect(RelayRun().nextAction(directive: running(step: RelayRun.Step.activating.rawValue), world: snapshot)
                == .advanceStep(nextStep: RelayRun.Step.confirmingRelay.rawValue),
                "an active relay must be handed to the step that verifies it, never re-commanded")
    }

    /// `statusBase`, so the backend's parenthetical status tail cannot make a
    /// live relay read as dead here any more than it can in `confirmingRelay`.
    @Test func activatingReadsThroughTheStatusTail() {
        let snapshot = world(devices: [
            carrier(location: "VEGA-1-L4"), relay(location: "VEGA-1-L4", status: "relaying (ACRUB)"),
        ])
        #expect(RelayRun().nextAction(directive: running(step: RelayRun.Step.activating.rawValue), world: snapshot)
                == .advanceStep(nextStep: RelayRun.Step.confirmingRelay.rawValue))
    }

    /// **The race the status check alone cannot close.** The command lands, the
    /// client never learns, and the local row still says `inactive` — so the
    /// truth is only readable by asking. Reading beats re-commanding: a read is
    /// free to be wrong, a duplicate `activate` is not.
    ///
    /// Bounded by `reAsk`'s `paid` set to one devices-refresh round per
    /// evaluation, after which the fresh row either hands off above or falls
    /// through to the dispatch below.
    @Test func activatingReadsAStaleRowRatherThanCommandingBlind() {
        let stale = fixtureNow.addingTimeInterval(-(RelayRun.pollInterval + 60))
        let snapshot = world(devices: [
            carrier(location: "VEGA-1-L4"),
            relay(location: "VEGA-1-L4", status: "inactive", updatedAt: stale),
        ])
        #expect(RelayRun().nextAction(directive: running(step: RelayRun.Step.activating.rawValue), world: snapshot)
                == .refreshDevices(deviceCodes: ["RLY1"], thenStall: nil))
    }

    /// The mirror on the other side of the same command: a re-entered
    /// `emplacing` whose `deploy` already took must hand off rather than
    /// re-issue a command that has to be rejected.
    @Test func emplacingHandsOffWhenTheDeployAlreadyTook() {
        let done = printOp()
        let snapshot = world(
            devices: [carrier(location: "VEGA-1-L4"), relay(location: "VEGA-1-L4")],
            dispatchedOperations: [done.id: done],
            systems: ["VEGA": targetSystem()]
        )
        #expect(RelayRun().nextAction(directive: running(step: RelayRun.Step.emplacing.rawValue), world: snapshot)
                == .advanceStep(nextStep: RelayRun.Step.activating.rawValue))
    }
}

@Suite("Relay Run — confirmingRelay")
struct RelayRunConfirmRelayTests {
    /// `statusBase`, not `status`: the backend appends a parenthetical parameter
    /// to some statuses, and a raw comparison would read a live relay as dead.
    @Test func confirmRelaySettlesWhenRelaying() {
        let snapshot = world(
            devices: [carrier(location: "VEGA-1-L4"), relay(location: "VEGA-1-L4", status: "relaying")]
        )
        #expect(RelayRun().nextAction(directive: running(step: RelayRun.Step.confirmingRelay.rawValue), world: snapshot)
                == .advanceStep(nextStep: RelayRun.Step.settling.rawValue))
    }

    @Test func confirmRelayReadsTheRelayWhileItPolls() {
        let snapshot = world(devices: [
            carrier(location: "VEGA-1-L4"),
            relay(location: "VEGA-1-L4", updatedAt: fixtureNow.addingTimeInterval(-120)),
        ])
        #expect(RelayRun().nextAction(directive: running(step: RelayRun.Step.confirmingRelay.rawValue), world: snapshot)
                == .refreshDevices(deviceCodes: ["RLY1"], thenStall: nil))
    }

    /// The deadline's own value. Its only other reader states its fixture as
    /// `-RelayRun.activationDeadline - 1`, so it tracks whatever the constant
    /// says and cannot notice a retune.
    @Test func theActivationDeadlineIsTenMinutes() {
        #expect(RelayRun.activationDeadline == 10 * 60)
    }

    @Test func confirmRelayStallsAtTheActivationDeadline() {
        let snapshot = world(devices: [carrier(location: "VEGA-1-L4"), relay(location: "VEGA-1-L4")])
        let overdue = running(
            step: RelayRun.Step.confirmingRelay.rawValue,
            stepStartedAt: fixtureNow.addingTimeInterval(-RelayRun.activationDeadline - 1)
        )
        #expect(RelayRun().nextAction(directive: overdue, world: snapshot) == .stall(.relayActivationFailed))
    }
}

// MARK: - Settling

@Suite("Relay Run — settling")
struct RelayRunSettleTests {
    /// The run's actual deliverable, judged the only way it may be judged: off
    /// DEVICE rows. A just-activated relay produces no `ftlLinks` rows at all,
    /// so a mesh read through those would report failure on a perfect run.
    @Test func finishesOnceTheTargetSystemIsMeshed() {
        let snapshot = world(
            devices: [carrier(location: "VEGA-1-L4"), relay(location: "VEGA-1-L4", status: "relaying")]
        )
        #expect(RelayRun().nextAction(directive: running(step: RelayRun.Step.settling.rawValue), world: snapshot) == .done)
    }

    /// A relay reporting `relaying` somewhere that is NOT the target system
    /// grew somebody else's mesh. The run's target is still unmeshed, so it
    /// must not report success.
    @Test func stallsWhenTheMeshDidNotActuallyGrow() {
        let snapshot = world(
            devices: [carrier(location: "VEGA-1-L4"), relay(location: "ORION-1-L4", status: "relaying")]
        )
        #expect(RelayRun().nextAction(directive: running(step: RelayRun.Step.settling.rawValue), world: snapshot)
                == .stall(.relayActivationFailed))
    }
}

// MARK: - The `.simple`-verb split

@Suite("Relay Run — .simple verbs are split dispatch/poll")
struct RelayRunSimpleVerbTests {
    /// The oracle these tests classify against: the kinds this machine
    /// dispatches that DO create an `Operation` row, so a same-step redispatch
    /// has a guard. Held here because no production site reads it.
    private static let trackedKinds: Set<OperationKind> = [.travel, .print]

    /// **The constraint this machine can hurt a live account by breaking.** A
    /// `.simple` verb carries NO `Operation` row, so `world.openOperation` can
    /// never guard it; and `DirectiveExecutor.apply` re-stamps `stepStartedAt`
    /// on every accepted dispatch. A `.simple` dispatch whose `nextStep` is its
    /// own step therefore re-issues the command every tick, forever, with a
    /// deadline that can never accumulate.
    ///
    /// Asserted over EVERY `.simple` dispatch this machine can produce, at the
    /// action level, so a future step that adds one is covered by construction
    /// rather than by care.
    @Test func everySimpleVerbDispatchAdvancesToADistinctPollStep() {
        let done = printOp()
        let cases: [(String, Directive, WorldSnapshot)] = [
            // `deactivate` at the source relay, on the reclaim path. Verified
            // against `CommandClient`: `deactivate` is absent from
            // `deadlineCommands`, so `completion(for:)` classifies it
            // `.immediate` and the dispatch returns `.accepted(operationID: nil)`
            // — no `Operation` row at all.
            (RelayRun.Step.deactivating.rawValue, running(step: RelayRun.Step.deactivating.rawValue, sourceRelayCode: "R9"), world(
                devices: [
                    carrier(location: "DEAD-1-L4"),
                    relay("R9", location: "DEAD-1-L4", status: "relaying"),
                ]
            )),
            // `stow` at the printed relay, naming the carrier.
            (RelayRun.Step.stowing.rawValue, running(step: RelayRun.Step.stowing.rawValue), world(
                devices: [carrier(), hub(), relay(location: hubLocation)],
                dispatchedOperations: [done.id: done]
            )),
            // `deploy` at the relay, at the target's Lagrange point.
            (RelayRun.Step.emplacing.rawValue, running(step: RelayRun.Step.emplacing.rawValue), world(
                devices: [carrier(location: "VEGA-1-L4"), relay(stowedIn: "V1")],
                systems: ["VEGA": targetSystem()]
            )),
            // `activate` at the just-deployed relay.
            (RelayRun.Step.activating.rawValue, running(step: RelayRun.Step.activating.rawValue), world(
                devices: [carrier(location: "VEGA-1-L4"), relay(location: "VEGA-1-L4")]
            )),
        ]

        var seen: [String] = []
        for (step, directive, snapshot) in cases {
            let action = RelayRun().nextAction(directive: directive, world: snapshot)
            guard case let .dispatch(kind, _, _, next) = action else {
                Issue.record("step \(step) was expected to dispatch, got \(action)")
                continue
            }
            #expect(!Self.trackedKinds.contains(kind),
                    "step \(step) dispatches \(kind.rawValue), which this test believes is untracked")
            #expect(next != step, Comment(rawValue:
                "step \(step) dispatches the untracked verb \(kind.rawValue) back into ITSELF — "
                    + "no operation row can guard it and stepStartedAt is re-stamped every tick"))
            seen.append(kind.rawValue)
        }
        // Pins the inventory itself: a new `.simple` dispatch added later has to
        // come here and be accounted for.
        #expect(seen == ["deactivate", "stow", "deploy", "activate"])
    }

    /// The other half of the same rule: a TRACKED kind may legitimately
    /// redispatch into its own step, because its `Operation` row is the guard.
    /// Without this, "never dispatch into your own step" would look like a
    /// blanket rule and the travel steps would read as bugs.
    @Test func trackedDispatchesMayReenterTheirOwnStep() {
        let snapshot = world(devices: [carrier(), hub(), relay(stowedIn: "V1")])
        guard case let .dispatch(kind, _, _, next) =
                RelayRun().nextAction(directive: running(step: RelayRun.Step.travelling.rawValue), world: snapshot)
        else {
            Issue.record("expected a travel dispatch")
            return
        }
        #expect(Self.trackedKinds.contains(kind))
        #expect(next == RelayRun.Step.travelling.rawValue)
    }
}

// MARK: - The whole sequence

@Suite("Relay Run — step sequence")
struct RelayRunSequenceTests {
    /// Walks the machine end to end, applying each action to a mutable fleet the
    /// way the server would, and pins the ORDER of steps it visits.
    ///
    /// This is the test that would catch a successor wired to the wrong step —
    /// something every single-step test above is blind to, since each one is
    /// handed the world its own step expects.
    @Test func progressesThroughItsStepsInOrder() {
        var devices: [String: Device] = [
            "V1": carrier(),
            "AF1": hub(),
        ]
        var dispatched: [String: GameModels.Operation] = [:]
        var directive = running()
        var visited: [String] = []
        var finished = false

        for _ in 0..<24 {
            let snapshot = world(
                devices: Array(devices.values),
                dispatchedOperations: dispatched,
                systems: ["VEGA": targetSystem()],
                // The rail is armed by default: the walk must clear it with
                // real stock or `acquire` vetoes before the happy path starts.
                footprints: [hubLocation: footprint(hubLocation, resources: 999_999)]
            )
            let action = RelayRun().nextAction(directive: directive, world: snapshot)
            visited.append(directive.step)

            switch action {
            case let .dispatch(kind, deviceCode, params, next):
                // Apply the command's effect the way the server would.
                switch kind.rawValue {
                case OperationKind.print.rawValue:
                    devices["RLY1"] = relay(location: hubLocation)
                    let op = printOp()
                    dispatched[op.id] = op
                case OperationKind.stow.rawValue:
                    devices[deviceCode]?.stowedInDeviceCode = params.target
                    devices[deviceCode]?.location = nil
                case OperationKind.travel.rawValue:
                    devices[deviceCode]?.location = params.destination
                case "deploy":
                    let carrierLocation = devices["V1"]?.location
                    devices[deviceCode]?.stowedInDeviceCode = nil
                    devices[deviceCode]?.location = carrierLocation
                case "activate":
                    devices[deviceCode]?.status = "relaying"
                default:
                    Issue.record("unexpected command \(kind.rawValue)")
                }
                directive.step = next
                directive.stepStartedAt = fixtureNow

            case let .advanceStep(next):
                directive.step = next
                directive.stepStartedAt = fixtureNow

            case let .claimRelay(deviceCode, next):
                directive.claimedRelayCode = deviceCode
                directive.step = next
                directive.stepStartedAt = fixtureNow

            case .done:
                finished = true

            default:
                Issue.record("the happy path produced \(action) at step \(directive.step)")
            }
            if finished { break }
        }

        #expect(finished, "the run never reached .done")
        #expect(visited == [
            RelayRun.Step.acquire.rawValue,
            RelayRun.Step.printing.rawValue,
            RelayRun.Step.stowing.rawValue,
            RelayRun.Step.confirmingStow.rawValue,
            // Two visits: the first dispatches the interstellar hop, the second
            // sees the carrier arrived. Travel is a TRACKED kind, so re-entering
            // its own step is the safe shape.
            RelayRun.Step.travelling.rawValue,
            RelayRun.Step.travelling.rawValue,
            // Two visits again: the first flies the carrier from the system's
            // entry point to its Lagrange point, the second deploys.
            RelayRun.Step.emplacing.rawValue,
            RelayRun.Step.emplacing.rawValue,
            RelayRun.Step.activating.rawValue,
            RelayRun.Step.confirmingRelay.rawValue,
            RelayRun.Step.settling.rawValue,
        ])
    }

    /// The same walk down the RECLAIM path, and the test that proves the shared
    /// tail is reused rather than forked: everything from `stowing` onward is
    /// the print path's own steps, visited in the same order.
    ///
    /// Deliberately driven with the reserve rail ARMED (the default) and NO
    /// census rows at all — the world in which the print path vetoes on its
    /// first evaluation. A reclaim spends nothing, so it must walk the whole
    /// sequence to `.done` regardless.
    @Test func walksTheReclaimPathAndRejoinsTheSharedTail() {
        var devices: [String: Device] = [
            "V1": carrier(),
            "R9": relay("R9", location: "DEAD-1-L4", status: "relaying"),
        ]
        var directive = running(sourceRelayCode: "R9")
        var visited: [String] = []
        var finished = false

        for _ in 0..<24 {
            let snapshot = world(
                devices: Array(devices.values),
                systems: ["VEGA": targetSystem()]
            )
            let action = RelayRun().nextAction(directive: directive, world: snapshot)
            visited.append(directive.step)

            switch action {
            case let .dispatch(kind, deviceCode, params, next):
                switch kind.rawValue {
                case OperationKind.travel.rawValue:
                    devices[deviceCode]?.location = params.destination
                case "deactivate":
                    devices[deviceCode]?.status = "inactive"
                case OperationKind.stow.rawValue:
                    devices[deviceCode]?.stowedInDeviceCode = params.target
                    devices[deviceCode]?.location = nil
                case "deploy":
                    let carrierLocation = devices["V1"]?.location
                    devices[deviceCode]?.stowedInDeviceCode = nil
                    devices[deviceCode]?.location = carrierLocation
                case "activate":
                    devices[deviceCode]?.status = "relaying"
                default:
                    Issue.record("unexpected command \(kind.rawValue) on the reclaim path")
                }
                directive.step = next
                directive.stepStartedAt = fixtureNow

            case let .advanceStep(next):
                directive.step = next
                directive.stepStartedAt = fixtureNow

            case let .claimRelay(deviceCode, next):
                directive.claimedRelayCode = deviceCode
                directive.step = next
                directive.stepStartedAt = fixtureNow

            case .done:
                finished = true

            default:
                Issue.record("the reclaim path produced \(action) at step \(directive.step)")
            }
            if finished { break }
        }

        #expect(finished, "the reclaim run never reached .done")
        #expect(visited == [
            RelayRun.Step.acquire.rawValue,
            // Two visits: the first dispatches the trip out to the source
            // relay, the second sees the carrier standing with it.
            RelayRun.Step.fetching.rawValue,
            RelayRun.Step.fetching.rawValue,
            RelayRun.Step.deactivating.rawValue,
            RelayRun.Step.confirmingIdle.rawValue,
            // From here on, every step is the print path's own — reused, not
            // forked.
            RelayRun.Step.stowing.rawValue,
            RelayRun.Step.confirmingStow.rawValue,
            RelayRun.Step.travelling.rawValue,
            RelayRun.Step.travelling.rawValue,
            RelayRun.Step.emplacing.rawValue,
            RelayRun.Step.emplacing.rawValue,
            RelayRun.Step.activating.rawValue,
            RelayRun.Step.confirmingRelay.rawValue,
            RelayRun.Step.settling.rawValue,
        ])
        // The relay the run planted is the one it reclaimed — no print
        // happened, and no second relay was created.
        #expect(devices.count == 2)
        #expect(devices["R9"]?.status == "relaying")
        #expect(devices["R9"]?.location == "VEGA-1-L4")
    }

    /// A Relay Run is one-shot: the brain launches a fresh directive per target,
    /// so an emptied queue is the end of THIS run rather than a cue to roam.
    @Test func neverRoams() {
        let plan = RelayRun().plan(RoamContext(
            centre: nil, vessel: nil, stars: [], assays: [], devices: [], attempted: []
        ))
        #expect(plan == .exhausted)
    }

    /// An unrecognised step must never dispatch — waiting is inert and
    /// recoverable; guessing at a live API is not.
    @Test func waitsOnAnUnknownStep() {
        let snapshot = world(devices: [carrier(), hub()])
        #expect(RelayRun().nextAction(directive: running(step: "nonsense"), world: snapshot) == .wait)
    }
}
