//
//  RelayRunTests.swift
//  Replicould — DirectiveEngine
//
//  The Relay Run step machine as a pure function table, following the same
//  pattern as `SalvageRunTests`. The run acquires a relay (v1: prints one at the
//  hub), gets it aboard the carrier, flies it to the target's Lagrange point,
//  deploys it, activates it, and confirms the mesh actually grew.
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
private func carrier(location: String? = hubLocation, updatedAt: Date = fixtureNow) -> Device {
    device("V1", type: "heaven_vessel", location: location, updatedAt: updatedAt)
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
    step: String = RelayRun.Step.acquire,
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
        #expect(MissionRegistry.firstStep(for: .relayRun) == RelayRun.Step.acquire)
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
            directive: running(step: RelayRun.Step.acquire),
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
        #expect(next == RelayRun.Step.printing)
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
        guard case .dispatch(_, _, _, RelayRun.Step.printing) =
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
                == .refreshFootprint(nextStep: RelayRun.Step.acquire, thenStall: .printStockShort))
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
                == .refreshFootprint(nextStep: RelayRun.Step.acquire, thenStall: .printStockShort))
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
        let armed = RelayRun(reserveFloor: 500)
        #expect(armed.printStockIsShort(at: hubLocation, world(devices: [carrier(), hub()])))
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
        guard case .dispatch(.print, "AF1", _, RelayRun.Step.printing) =
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
                == .advanceStep(nextStep: RelayRun.Step.travelling))
    }

    /// The reclaim branch is a later task. A row carrying `sourceRelayCode`
    /// must not fall through into the print path and silently print a relay the
    /// plan intended to RECLAIM — it waits, inertly and recoverably, exactly as
    /// an unhandled step does.
    @Test func leavesTheReclaimBranchUnbuilt() {
        let snapshot = world(devices: [carrier(), hub(), relay("OLD", location: "SOMEWHERE-1-L4", status: "relaying")])
        #expect(RelayRun().nextAction(directive: running(sourceRelayCode: "OLD"), world: snapshot) == .wait)
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
        #expect(RelayRun().nextAction(directive: running(step: RelayRun.Step.printing), world: snapshot) == .wait)
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
        #expect(RelayRun().nextAction(directive: running(step: RelayRun.Step.printing), world: snapshot)
                == .advanceStep(nextStep: RelayRun.Step.stowing))
    }

    /// The clone's row arrives by a `.high` read that `GameSync` fires off
    /// `print.completed`. If that read hasn't landed, the code is known but the
    /// row isn't — buy the read here rather than treating it as a failed print.
    /// It carries a stall so a read that keeps failing surfaces after ONE round
    /// instead of re-firing every tick for the whole print deadline.
    @Test func readsTheCloneWhenItsCodeIsKnownButItsRowIsNot() {
        let done = printOp()
        let snapshot = world(devices: [carrier(), hub()], dispatchedOperations: [done.id: done])
        #expect(RelayRun().nextAction(directive: running(step: RelayRun.Step.printing), world: snapshot)
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
        #expect(RelayRun().nextAction(directive: running(step: RelayRun.Step.printing), world: snapshot) == .wait)
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
        #expect(RelayRun().nextAction(directive: running(step: RelayRun.Step.stowing), world: snapshot)
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
            step: RelayRun.Step.printing,
            stepStartedAt: fixtureNow.addingTimeInterval(-RelayRun.printDeadline - 1)
        )
        #expect(RelayRun().nextAction(directive: overdue, world: snapshot) == .stall(.noRelayCoLocated))
    }

    /// …and inside the deadline the same barren world merely waits, so the
    /// stall above is the deadline's doing.
    @Test func waitsInsideThePrintDeadline() {
        let snapshot = world(devices: [carrier(), hub()])
        #expect(RelayRun().nextAction(directive: running(step: RelayRun.Step.printing), world: snapshot) == .wait)
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
            step: RelayRun.Step.printing,
            stepStartedAt: fixtureNow.addingTimeInterval(-RelayRun.printDeadline - 1)
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
        let action = RelayRun().nextAction(directive: running(step: RelayRun.Step.stowing), world: snapshot)
        guard case let .dispatch(kind, deviceCode, params, next) = action else {
            Issue.record("expected a stow dispatch, got \(action)")
            return
        }
        #expect(kind == .stow)
        // The command is issued ON the device being stowed, with the carrier as
        // its `target` — the inverse would stow the vessel into the relay.
        #expect(deviceCode == "RLY1")
        #expect(params.target == "V1")
        #expect(next == RelayRun.Step.confirmingStow)
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
        #expect(RelayRun().nextAction(directive: running(step: RelayRun.Step.stowing), world: snapshot)
                == .advanceStep(nextStep: RelayRun.Step.travelling))
    }

    /// A relay that is neither aboard nor anywhere near the carrier cannot be
    /// stowed onto it; surfacing beats POSTing a command that must be rejected.
    @Test func stallsWhenTheRelayIsNotCoLocatedWithTheCarrier() {
        let done = printOp()
        let snapshot = world(
            devices: [carrier(), hub(), relay(location: "FAR-BELT-9")],
            dispatchedOperations: [done.id: done]
        )
        #expect(RelayRun().nextAction(directive: running(step: RelayRun.Step.stowing), world: snapshot)
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
        #expect(RelayRun().nextAction(directive: running(step: RelayRun.Step.confirmingStow), world: snapshot)
                == .advanceStep(nextStep: RelayRun.Step.travelling))
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
        #expect(RelayRun().nextAction(directive: running(step: RelayRun.Step.confirmingStow), world: snapshot)
                == .refreshDevices(deviceCodes: ["RLY1"], thenStall: nil))
    }

    @Test func stallsWhenTheStowNeverTakes() {
        let done = printOp()
        let snapshot = world(
            devices: [carrier(), hub(), relay(location: hubLocation)],
            dispatchedOperations: [done.id: done]
        )
        let overdue = running(
            step: RelayRun.Step.confirmingStow,
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
        let action = RelayRun().nextAction(directive: running(step: RelayRun.Step.travelling), world: snapshot)
        #expect(action == .dispatch(
            kind: .travel, deviceCode: "V1", params: CommandParams(destination: "VEGA"),
            nextStep: RelayRun.Step.travelling
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
        #expect(RelayRun().nextAction(directive: running(step: RelayRun.Step.travelling), world: snapshot) == .wait)
    }

    @Test func advancesToEmplacingOnArrival() {
        let snapshot = world(devices: [carrier(location: "VEGA"), relay(stowedIn: "V1")])
        #expect(RelayRun().nextAction(directive: running(step: RelayRun.Step.travelling), world: snapshot)
                == .advanceStep(nextStep: RelayRun.Step.emplacing))
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
        #expect(RelayRun().nextAction(directive: running(step: RelayRun.Step.emplacing), world: snapshot)
                == .dispatch(
                    kind: .travel, deviceCode: "V1",
                    params: CommandParams(destination: "VEGA-1-L4"),
                    nextStep: RelayRun.Step.emplacing
                ))
    }

    @Test func deploysTheRelayOnceAtThePoint() {
        let snapshot = world(
            devices: [carrier(location: "VEGA-1-L4"), relay(stowedIn: "V1")],
            systems: ["VEGA": targetSystem()]
        )
        #expect(RelayRun().nextAction(directive: running(step: RelayRun.Step.emplacing), world: snapshot)
                == .dispatch(
                    kind: OperationKind.simple("deploy"), deviceCode: "RLY1",
                    params: CommandParams(), nextStep: RelayRun.Step.activating
                ))
    }

    /// An uncached catalogue blob is "we don't know yet", never "this system has
    /// no Lagrange point" — the two collapse to the same nil if left
    /// unstructured, and acting on the second would silently forfeit the mesh.
    @Test func waitsWhenTheTargetSystemIsNotCachedYet() {
        let snapshot = world(devices: [carrier(location: "VEGA"), relay(stowedIn: "V1")])
        #expect(RelayRun().nextAction(directive: running(step: RelayRun.Step.emplacing), world: snapshot) == .wait)
    }

    /// Past the deadline the backstop spends ONE authoritative catalogue read
    /// before giving up, so the stall's own guidance ("Retry to fetch it again")
    /// is true rather than a dead end over an unchanged snapshot.
    @Test func readsTheCatalogueOnceTheResolutionDeadlinePasses() {
        let snapshot = world(devices: [carrier(location: "VEGA"), relay(stowedIn: "V1")])
        let overdue = running(
            step: RelayRun.Step.emplacing,
            stepStartedAt: fixtureNow.addingTimeInterval(-SalvageRun.systemResolutionDeadline - 1)
        )
        #expect(RelayRun().nextAction(directive: overdue, world: snapshot)
                == .refreshSystem(designation: "VEGA", nextStep: RelayRun.Step.emplacing))
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
        #expect(RelayRun().nextAction(directive: running(step: RelayRun.Step.activating), world: snapshot)
                == .dispatch(
                    kind: OperationKind.simple("activate"), deviceCode: "RLY1",
                    params: CommandParams(), nextStep: RelayRun.Step.confirmingRelay
                ))
    }

    @Test func stallsWhenTheDeployedRelayCannotBeFound() {
        let snapshot = world(devices: [carrier(location: "VEGA-1-L4")])
        #expect(RelayRun().nextAction(directive: running(step: RelayRun.Step.activating), world: snapshot)
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
        #expect(RelayRun().nextAction(directive: running(step: RelayRun.Step.activating), world: snapshot)
                == .stall(.relayActivationFailed))
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
        #expect(RelayRun().nextAction(directive: running(step: RelayRun.Step.emplacing), world: snapshot)
                == .advanceStep(nextStep: RelayRun.Step.activating))
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
        #expect(RelayRun().nextAction(directive: running(step: RelayRun.Step.confirmingRelay), world: snapshot)
                == .advanceStep(nextStep: RelayRun.Step.settling))
    }

    @Test func confirmRelayReadsTheRelayWhileItPolls() {
        let snapshot = world(devices: [
            carrier(location: "VEGA-1-L4"),
            relay(location: "VEGA-1-L4", updatedAt: fixtureNow.addingTimeInterval(-120)),
        ])
        #expect(RelayRun().nextAction(directive: running(step: RelayRun.Step.confirmingRelay), world: snapshot)
                == .refreshDevices(deviceCodes: ["RLY1"], thenStall: nil))
    }

    @Test func confirmRelayStallsAtTheActivationDeadline() {
        let snapshot = world(devices: [carrier(location: "VEGA-1-L4"), relay(location: "VEGA-1-L4")])
        let overdue = running(
            step: RelayRun.Step.confirmingRelay,
            stepStartedAt: fixtureNow.addingTimeInterval(-SalvageRun.activationDeadline - 1)
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
        #expect(RelayRun().nextAction(directive: running(step: RelayRun.Step.settling), world: snapshot) == .done)
    }

    /// A relay reporting `relaying` somewhere that is NOT the target system
    /// grew somebody else's mesh. The run's target is still unmeshed, so it
    /// must not report success.
    @Test func stallsWhenTheMeshDidNotActuallyGrow() {
        let snapshot = world(
            devices: [carrier(location: "VEGA-1-L4"), relay(location: "ORION-1-L4", status: "relaying")]
        )
        #expect(RelayRun().nextAction(directive: running(step: RelayRun.Step.settling), world: snapshot)
                == .stall(.relayActivationFailed))
    }
}

// MARK: - The `.simple`-verb split

@Suite("Relay Run — .simple verbs are split dispatch/poll")
struct RelayRunSimpleVerbTests {
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
        let cases: [(String, WorldSnapshot)] = [
            // `stow` at the printed relay, naming the carrier.
            (RelayRun.Step.stowing, world(
                devices: [carrier(), hub(), relay(location: hubLocation)],
                dispatchedOperations: [done.id: done]
            )),
            // `deploy` at the relay, at the target's Lagrange point.
            (RelayRun.Step.emplacing, world(
                devices: [carrier(location: "VEGA-1-L4"), relay(stowedIn: "V1")],
                systems: ["VEGA": targetSystem()]
            )),
            // `activate` at the just-deployed relay.
            (RelayRun.Step.activating, world(
                devices: [carrier(location: "VEGA-1-L4"), relay(location: "VEGA-1-L4")]
            )),
        ]

        var seen: [String] = []
        for (step, snapshot) in cases {
            let action = RelayRun().nextAction(directive: running(step: step), world: snapshot)
            guard case let .dispatch(kind, _, _, next) = action else {
                Issue.record("step \(step) was expected to dispatch, got \(action)")
                continue
            }
            #expect(!RelayRun.trackedKinds.contains(kind),
                    "step \(step) dispatches \(kind.rawValue), which this test believes is untracked")
            #expect(next != step, Comment(rawValue:
                "step \(step) dispatches the untracked verb \(kind.rawValue) back into ITSELF — "
                    + "no operation row can guard it and stepStartedAt is re-stamped every tick"))
            seen.append(kind.rawValue)
        }
        // Pins the inventory itself: a new `.simple` dispatch added later has to
        // come here and be accounted for.
        #expect(seen == ["stow", "deploy", "activate"])
    }

    /// The other half of the same rule: a TRACKED kind may legitimately
    /// redispatch into its own step, because its `Operation` row is the guard.
    /// Without this, "never dispatch into your own step" would look like a
    /// blanket rule and the travel steps would read as bugs.
    @Test func trackedDispatchesMayReenterTheirOwnStep() {
        let snapshot = world(devices: [carrier(), hub(), relay(stowedIn: "V1")])
        guard case let .dispatch(kind, _, _, next) =
                RelayRun().nextAction(directive: running(step: RelayRun.Step.travelling), world: snapshot)
        else {
            Issue.record("expected a travel dispatch")
            return
        }
        #expect(RelayRun.trackedKinds.contains(kind))
        #expect(next == RelayRun.Step.travelling)
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

            case .done:
                finished = true

            default:
                Issue.record("the happy path produced \(action) at step \(directive.step)")
            }
            if finished { break }
        }

        #expect(finished, "the run never reached .done")
        #expect(visited == [
            RelayRun.Step.acquire,
            RelayRun.Step.printing,
            RelayRun.Step.stowing,
            RelayRun.Step.confirmingStow,
            // Two visits: the first dispatches the interstellar hop, the second
            // sees the carrier arrived. Travel is a TRACKED kind, so re-entering
            // its own step is the safe shape.
            RelayRun.Step.travelling,
            RelayRun.Step.travelling,
            // Two visits again: the first flies the carrier from the system's
            // entry point to its Lagrange point, the second deploys.
            RelayRun.Step.emplacing,
            RelayRun.Step.emplacing,
            RelayRun.Step.activating,
            RelayRun.Step.confirmingRelay,
            RelayRun.Step.settling,
        ])
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
