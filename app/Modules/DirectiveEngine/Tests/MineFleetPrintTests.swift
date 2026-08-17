//
//  MineFleetPrintTests.swift
//  Replicould — DirectiveEngine
//
//  `MineFleetPrint` as a verdict table: prints, waits, and the one escalation.
//

import ConcurrencyExtras
import Dependencies
import Foundation
import GameDatabase
import GameModels
import GameServices
import SQLiteData
import Testing
import UniverseModels
import Utils
@testable import DirectiveEngine

// MARK: - Fixtures

private let now = Date(timeIntervalSince1970: 1_750_000_000)
private let hubLocation = "AINALRAM-BELT-1"
private let hubSystem = "AINALRAM"

/// How far behind the SSE row channel ran during the live over-print.
private let rowLag: TimeInterval = 113 * 60

private func mineDevice(
    _ code: String, type: String, tags: [String] = [], location: String? = nil,
    status: String = "idle", stowedIn: String? = nil, attachedTo: String? = nil,
    controllerDeviceCode: String? = nil, commands: [String] = [],
    updatedAt: Date = now
) -> Device {
    Device(
        deviceCode: code, deviceType: type, replicantCode: "R1", status: status,
        location: location, locationName: nil, operationalCapacity: 100, queueSize: 0,
        stowedInDeviceCode: stowedIn, controllerDeviceCode: controllerDeviceCode,
        attachedToDeviceCode: attachedTo, createdAt: Date(timeIntervalSince1970: 0),
        availableCommands: commands, features: [], tags: tags, detail: .object([:]),
        updatedAt: updatedAt, firstSeenAt: Date(timeIntervalSince1970: 0)
    )
}

private func hub(
    _ code: String = "AF1", location: String = hubLocation, updatedAt: Date = now
) -> Device {
    mineDevice(
        code, type: "autofactory", location: location,
        commands: ["enqueue_print"], updatedAt: updatedAt
    )
}

/// A complete unassigned mine fleet standing at the hub — one row per recipe slot.
private func printedFleet(omitting omitted: String? = nil, updatedAt: Date = now) -> [Device] {
    var out: [Device] = []
    var n = 0
    for (type, quantity) in MineRecipe.all where type != omitted {
        for _ in 0..<quantity {
            n += 1
            out.append(mineDevice(
                "M\(String(format: "%02d", n))", type: type,
                tags: [MineRecipe.fleetTag], location: hubLocation, updatedAt: updatedAt
            ))
        }
    }
    return out
}

private func carrier(
    _ code: String = "SC1", tagged: Bool = true, status: String = "idle",
    location: String? = hubLocation, updatedAt: Date = now
) -> Device {
    mineDevice(
        code, type: MineRecipe.carrierDeviceType,
        tags: tagged ? [MineRecipe.carrierTag] : [], location: location, status: status,
        updatedAt: updatedAt
    )
}

private func census(
    _ resources: Int, at location: String = hubLocation, fetchedAt: Date = now
) -> [String: LocationFootprint] {
    [location: LocationFootprint(
        location: location, devices: 1, resources: resources,
        resourceSites: 0, locationEvents: 0, replicants: 0, fetchedAt: fetchedAt
    )]
}

private func healthyCensus(fetchedAt: Date = now) -> [String: LocationFootprint] {
    census(BrainCeiling.aggregateSpendFloor * 2, fetchedAt: fetchedAt)
}

private func world(
    devices: [Device],
    openOperations: [String: GameModels.Operation] = [:],
    footprints: [String: LocationFootprint]? = nil
) -> WorldSnapshot {
    WorldSnapshot(
        devices: Dictionary(devices.map { ($0.deviceCode, $0) }, uniquingKeysWith: { _, last in last }),
        openOperations: openOperations, log: [], dispatchedOperations: [:],
        systems: [:], siteAssays: [:], footprints: footprints ?? healthyCensus(), peers: [], now: now
    )
}

private func openPrint(on entity: String, directiveID: String? = nil) -> [String: GameModels.Operation] {
    [entity: GameModels.Operation(
        id: "OP-1", entityCode: entity, kind: OperationKind.print.rawValue, status: .active,
        source: .poll, startedAt: now, completesAt: nil, lastConfirmedAt: now, detail: .object([:]),
        directiveID: directiveID
    )]
}

private func printRun(
    step: String = MineFleetPrint.Step.stocking,
    hub code: String = "AF1",
    stepStartedAt: Date = now.addingTimeInterval(-60)
) -> Directive {
    Directive(
        id: "P1", kind: .mineFleetPrint, status: .running, deviceCode: code,
        controllerCode: nil, roamCentre: nil, fleetTag: MineRecipe.fleetTag, sourceRelayCode: nil,
        targets: [], targetIndex: 0, step: step, stepStartedAt: stepStartedAt,
        returnToOrigin: false, originDesignation: hubSystem, attentionReason: nil,
        createdAt: now.addingTimeInterval(-600), updatedAt: now
    )
}

// MARK: - Tests

@Suite("MineFleetPrint — the operator-invoked print run")
struct MineFleetPrintTests {

    /// The one legitimate stall: the hub row this directive names has left the
    /// fleet, and substituting another printer would be a fabrication.
    @Test("a hub that is gone from the fleet stalls")
    func missingHubStalls() {
        let snapshot = world(devices: printedFleet() + [carrier()])

        #expect(MineFleetPrint().nextAction(directive: printRun(), world: snapshot)
                == .stall(.unreachableDevice))
    }

    /// The run's product is a standing fleet, so a complete one finishes the row.
    @Test("a complete fleet with its carrier is done")
    func completeFleetIsDone() {
        let snapshot = world(devices: printedFleet() + [hub(), carrier()])

        #expect(MineFleetPrint().nextAction(directive: printRun(), world: snapshot) == .done)
    }

    /// The carrier is the delivery vehicle and is not in `MineRecipe.all`, so it
    /// is a separate slot — and its print carries the carrier tag, not the fleet
    /// tag, because `MineRecipe.idleCarrier` recognises it by that tag alone.
    @Test("a complete fleet with no carrier anywhere prints one")
    func missingCarrierIsPrinted() {
        let snapshot = world(devices: printedFleet() + [hub()])

        #expect(MineFleetPrint().nextAction(directive: printRun(), world: snapshot) == .dispatch(
            kind: .print, deviceCode: "AF1",
            params: CommandParams(
                deviceType: MineRecipe.carrierDeviceType, quantity: 1,
                printTags: [MineRecipe.carrierTag]
            ),
            nextStep: MineFleetPrint.Step.printing
        ))
    }

    /// A recipe shortfall is printed in one job for the whole missing quantity,
    /// tagged into the fleet so `MineRecipe` counts it next tick.
    @Test("a shortfall of three drones prints three drones")
    func shortfallIsPrinted() {
        let snapshot = world(devices: printedFleet(omitting: "mining_drone") + [hub(), carrier()])

        #expect(MineFleetPrint().nextAction(directive: printRun(), world: snapshot) == .dispatch(
            kind: .print, deviceCode: "AF1",
            params: CommandParams(
                deviceType: "mining_drone", quantity: 3, printTags: [MineRecipe.fleetTag]
            ),
            nextStep: MineFleetPrint.Step.printing
        ))
    }

    /// One print in flight at a time: `CommandClient` supersedes any other open
    /// op on a device, so a second dispatch orphans the first's operation row.
    @Test("a print already in flight is never doubled up")
    func openOperationWaits() {
        let snapshot = world(
            devices: printedFleet(omitting: "mining_drone") + [hub(), carrier()],
            openOperations: openPrint(on: "AF1")
        )

        #expect(MineFleetPrint().nextAction(directive: printRun(), world: snapshot) == .wait)
    }

    /// Owner-scoped: a bench is one serial queue shared by every run that uses
    /// it, so another run's print there is not this one's to wait on.
    @Test("a co-tenant's print at the hub does not block starting our own")
    func aCoTenantsPrintDoesNotBlock() {
        let snapshot = world(
            devices: printedFleet(omitting: "mining_drone") + [hub(), carrier()],
            openOperations: openPrint(on: "AF1", directiveID: "OTHER")
        )

        #expect(MineFleetPrint().nextAction(directive: printRun(), world: snapshot) == .dispatch(
            kind: .print, deviceCode: "AF1",
            params: CommandParams(
                deviceType: "mining_drone", quantity: 3, printTags: [MineRecipe.fleetTag]
            ),
            nextStep: MineFleetPrint.Step.printing
        ))
    }

    /// Our own print still holds the step — owner-scoping must not make the
    /// guard against orphaning our own operation row toothless.
    @Test("our own open print still holds the step")
    func ourOwnPrintStillWaits() {
        let directive = printRun()
        let snapshot = world(
            devices: printedFleet(omitting: "mining_drone") + [hub(), carrier()],
            openOperations: openPrint(on: "AF1", directiveID: directive.id)
        )

        #expect(MineFleetPrint().nextAction(directive: directive, world: snapshot) == .wait)
    }

    /// Nothing polls `LocationFootprint`, so a stale census buys its own read
    /// rather than waiting for another mission to happen to refresh.
    @Test("a stale census is refreshed rather than waited out")
    func staleCensusBuysARefresh() {
        let stale = now.addingTimeInterval(-(RelayRun.pollInterval + 60))
        let snapshot = world(
            devices: printedFleet(omitting: "mining_drone") + [hub(), carrier()],
            footprints: healthyCensus(fetchedAt: stale)
        )

        #expect(MineFleetPrint().nextAction(directive: printRun(), world: snapshot)
                == .refreshFootprint(nextStep: MineFleetPrint.Step.stocking, thenStall: nil))
    }

    /// **Short stock idles, it never stalls.** The hub buffer refills from
    /// salvage, so a print the reserve rail vetoes is the system working.
    @Test("the reserve floor vetoes the print without escalating")
    func shortStockWaitsAndNeverStalls() {
        let snapshot = world(
            devices: printedFleet(omitting: "mining_drone") + [hub(), carrier()],
            footprints: census(1)
        )

        let action = MineFleetPrint().nextAction(directive: printRun(), world: snapshot)
        #expect(action == .wait)
        if case .stall = action { Issue.record("short stock escalated to a human") }
    }

    /// Count-based, so a superseded print op cannot strand the step: the fleet
    /// is whole, whichever job produced it.
    @Test("printing hands back to stocking once the shortfall is met")
    func printingAdvancesWhenSatisfied() {
        let directive = printRun(step: MineFleetPrint.Step.printing)
        let snapshot = world(devices: printedFleet() + [hub(), carrier()])

        #expect(MineFleetPrint().nextAction(directive: directive, world: snapshot)
                == .advanceStep(nextStep: MineFleetPrint.Step.stocking))
    }

    /// While the print is genuinely in flight the run holds still.
    @Test("printing holds while the print op is open")
    func printingWaitsOnTheOpenOp() {
        let directive = printRun(step: MineFleetPrint.Step.printing)
        let snapshot = world(
            devices: printedFleet(omitting: "mining_drone") + [hub(), carrier()],
            openOperations: openPrint(on: "AF1")
        )

        #expect(MineFleetPrint().nextAction(directive: directive, world: snapshot) == .wait)
    }

    /// A quantity-3 job settles its op on the FIRST clone, so an op-close is no
    /// evidence the job finished — the residual is still draining server-side,
    /// and re-deciding here re-dispatches the whole quantity.
    @Test("a closed op with the quantity still draining holds rather than re-dispatching")
    func printingHoldsWhileTheQuantityDrains() {
        let landed = printedFleet().filter { !["M03", "M04"].contains($0.deviceCode) }
        let directive = printRun(step: MineFleetPrint.Step.printing)
        let snapshot = world(devices: landed + [hub(), carrier()])

        #expect(MineRecipe.shortfall(at: hubLocation, in: snapshot.devices.values)
                == ["mining_drone": 2])
        #expect(MineFleetPrint().nextAction(directive: directive, world: snapshot) == .wait)
    }

    /// The deadline is the only way back to `stocking` while slots stand empty:
    /// a queue that produced nothing in half an hour is not draining.
    @Test("a print that produces nothing within the deadline re-decides")
    func printingRedecidesPastTheDeadline() {
        let directive = printRun(
            step: MineFleetPrint.Step.printing,
            stepStartedAt: now.addingTimeInterval(-(RestockRun.printDeadline + 60))
        )
        let snapshot = world(devices: printedFleet(omitting: "mining_drone") + [hub(), carrier()])

        #expect(MineFleetPrint().nextAction(directive: directive, world: snapshot)
                == .advanceStep(nextStep: MineFleetPrint.Step.stocking))
    }

    /// A bench is shared, and `openOperation` is keyed by device alone, so a
    /// co-tenant's print must not hold this run past its own deadline.
    @Test("the deadline still fires while an op holds the bench")
    func printingRedecidesPastTheDeadlineWithTheBenchBusy() {
        let directive = printRun(
            step: MineFleetPrint.Step.printing,
            stepStartedAt: now.addingTimeInterval(-(RestockRun.printDeadline + 60))
        )
        let snapshot = world(
            devices: printedFleet(omitting: "mining_drone") + [hub(), carrier()],
            openOperations: openPrint(on: "AF1")
        )

        #expect(MineFleetPrint().nextAction(directive: directive, world: snapshot)
                == .advanceStep(nextStep: MineFleetPrint.Step.stocking))
    }

    /// The carrier slot is filled by the TAGGED carrier the launcher flies and
    /// `MineRecipe.idleCarrier` finds — nothing tags a spare, so an untagged
    /// hull retiring this row `.done` would leave the goal carrier-less forever.
    @Test("an untagged idle surge carrier does not fill the carrier slot")
    func anUntaggedCarrierDoesNotFillTheSlot() {
        let snapshot = world(devices: printedFleet() + [hub(), carrier(tagged: false)])

        #expect(MineFleetPrint().nextAction(directive: printRun(), world: snapshot) == .dispatch(
            kind: .print, deviceCode: "AF1",
            params: CommandParams(
                deviceType: MineRecipe.carrierDeviceType, quantity: 1,
                printTags: [MineRecipe.carrierTag]
            ),
            nextStep: MineFleetPrint.Step.printing
        ))
    }
}

// MARK: - Fresh evidence before a re-print

/// A print op and its clone's device row land in SEPARATE transactions, and the
/// op closes on the poll path — which proves the queue emptied and carries no
/// device code. So the moment the op-close releases the one duplicate guard,
/// `MineRecipe.shortfall` is still reading rows from before the clone existed
/// and reports the slot it just filled as missing.
@Suite("MineFleetPrint — fresh evidence before a re-print")
struct MineFleetPrintFreshEvidenceTests {

    /// The over-print's exact shape: the op has closed, the step re-entered
    /// `stocking`, and every row at the hub predates that. A second print here is
    /// how five transport controllers were printed against a demand of one.
    @Test("rows older than the step buy a hub sweep instead of a second print")
    func staleRowsBuyASweepNotASecondPrint() {
        let stale = now.addingTimeInterval(-rowLag)
        let snapshot = world(devices:
            printedFleet(omitting: "ami_transport_controller", updatedAt: stale)
                + [hub(updatedAt: stale), carrier(updatedAt: stale)]
        )
        let directive = printRun(stepStartedAt: now.addingTimeInterval(-5))

        let action = MineFleetPrint().nextAction(directive: directive, world: snapshot)
        #expect(action == .refreshDevicesInSystem(
            designation: hubLocation, thenStall: .unreachableDevice
        ))
        if case .dispatch = action { Issue.record("re-printed off rows that predate the op's close") }
    }

    /// The gate is a holdback, not a wedge: rows read since the step began are
    /// the authoritative answer, and a shortfall they still show is real.
    @Test("rows read since the step began print the shortfall they still show")
    func sweptRowsPrintTheGenuineShortfall() {
        let snapshot = world(devices:
            printedFleet(omitting: "ami_transport_controller") + [hub(), carrier()]
        )
        let directive = printRun(stepStartedAt: now.addingTimeInterval(-5))

        #expect(MineFleetPrint().nextAction(directive: directive, world: snapshot) == .dispatch(
            kind: .print, deviceCode: "AF1",
            params: CommandParams(
                deviceType: "ami_transport_controller", quantity: 1,
                printTags: [MineRecipe.fleetTag]
            ),
            nextStep: MineFleetPrint.Step.printing
        ))
    }

    /// Nothing is decided while the job runs, so the read is not bought there —
    /// the evidence that matters is the evidence AFTER the op closes.
    @Test("an open print op is waited out without buying the sweep")
    func anOpenOpSpendsNoRead() {
        let stale = now.addingTimeInterval(-rowLag)
        let snapshot = world(
            devices: printedFleet(omitting: "ami_transport_controller", updatedAt: stale)
                + [hub(updatedAt: stale), carrier(updatedAt: stale)],
            openOperations: openPrint(on: "AF1")
        )
        let directive = printRun(stepStartedAt: now.addingTimeInterval(-5))

        #expect(MineFleetPrint().nextAction(directive: directive, world: snapshot) == .wait)
    }

    /// A veto path spends nothing either: the sweep sits at the last moment before
    /// the print, after every branch that declines to print at all.
    @Test("the reserve veto declines before the sweep is bought")
    func aVetoedPrintSpendsNoRead() {
        let stale = now.addingTimeInterval(-rowLag)
        let snapshot = world(
            devices: printedFleet(omitting: "ami_transport_controller", updatedAt: stale)
                + [hub(updatedAt: stale), carrier(updatedAt: stale)],
            footprints: census(1)
        )
        let directive = printRun(stepStartedAt: now.addingTimeInterval(-5))

        #expect(MineFleetPrint().nextAction(directive: directive, world: snapshot) == .wait)
    }

    /// A fleet that reads COMPLETE on old rows is positive evidence — the devices
    /// are named in the rows — so it finishes rather than buying a read.
    @Test("a complete fleet on old rows finishes without a sweep")
    func aCompleteFleetOnOldRowsIsStillDone() {
        let stale = now.addingTimeInterval(-rowLag)
        let snapshot = world(devices:
            printedFleet(updatedAt: stale) + [hub(updatedAt: stale), carrier(updatedAt: stale)]
        )
        let directive = printRun(stepStartedAt: now.addingTimeInterval(-5))

        #expect(MineFleetPrint().nextAction(directive: directive, world: snapshot) == .done)
    }

    /// `printing` still hands back on the deadline — the holdback belongs at the
    /// dispatch, so the hand-back stays a plain step move.
    @Test("printing still hands back to stocking on the deadline")
    func printingStillHandsBackOnTheDeadline() {
        let stale = now.addingTimeInterval(-rowLag)
        let directive = printRun(
            step: MineFleetPrint.Step.printing,
            stepStartedAt: now.addingTimeInterval(-(RestockRun.printDeadline + 60))
        )
        let snapshot = world(devices:
            printedFleet(omitting: "ami_transport_controller", updatedAt: stale)
                + [hub(updatedAt: stale), carrier(updatedAt: stale)]
        )

        #expect(MineFleetPrint().nextAction(directive: directive, world: snapshot)
                == .advanceStep(nextStep: MineFleetPrint.Step.stocking))
    }
}

// MARK: - Through the real engine

private func seedPrintRun(
    _ database: any DatabaseWriter, rows: [Device], stepStartedAt: Date
) async throws {
    try await database.write { db in
        try Directive.insert { printRun(stepStartedAt: stepStartedAt) }.execute(db)
        for row in rows { try Device.upsert { row }.execute(db) }
        try LocationFootprint.upsert {
            LocationFootprint(
                location: hubLocation, devices: rows.count,
                resources: BrainCeiling.aggregateSpendFloor * 2,
                resourceSites: 0, locationEvents: 0, replicants: 0, fetchedAt: now
            )
        }
        .execute(db)
    }
}

/// The pure verdict table cannot show that the sweep it asks for actually clears
/// the gate — that takes `DirectiveEngineCore`, which owns the read, the
/// reconcile and the re-ask.
@Suite("MineFleetPrint — the row-lag re-print, through the engine")
struct MineFleetPrintEngineTests {

    /// The live incident end to end: the transport clone exists server-side and
    /// its row does not. One scoped read, no second print, run complete.
    @Test func theRowLagResolvesToACompleteFleetAndNoSecondPrint() async throws {
        let database = try GameDatabase.bootstrap()
        let stale = now.addingTimeInterval(-rowLag)
        let landed = printedFleet(omitting: "ami_transport_controller", updatedAt: stale)
        try await seedPrintRun(
            database, rows: landed + [hub(updatedAt: stale), carrier(updatedAt: stale)],
            stepStartedAt: now.addingTimeInterval(-5)
        )
        let dispatches = LockIsolated<[String]>([])
        let queries = LockIsolated<[String]>([])
        let clone = mineDevice(
            "CLONE1", type: "ami_transport_controller", tags: [MineRecipe.fleetTag],
            location: hubLocation
        )

        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(now)
            $0.uuid = .incrementing
            $0.devicesClient.fetchAtLocation = { designation in
                queries.withValue { $0.append(designation) }
                return printedFleet(omitting: "ami_transport_controller") + [hub(), carrier(), clone]
            }
            $0.commandGovernor.dispatchOwned = { _, _, params, _ in
                dispatches.withValue { $0.append(params.deviceType ?? "?") }
                return .dispatched(.accepted(operationID: nil))
            }
        } operation: {
            let core = DirectiveEngineCore(machines: [MineFleetPrint()], tick: .seconds(5))
            await core.evaluateOnce(directiveID: "P1")
        }

        #expect(queries.value == [hubLocation], "one scoped read of the hub, not one per device")
        #expect(dispatches.value.isEmpty, "the clone was already printed — nothing to re-order")
        let row = try #require(
            await database.read { db in try Directive.where { $0.id.eq("P1") }.fetchOne(db) }
        )
        #expect(row.status == .completed)
        #expect(row.attentionReason == nil)
    }

    /// And the gate does not wedge a genuinely short fleet: the same read that
    /// would have revealed a clone reveals none, so the print goes out.
    @Test func aSweepThatFindsNoCloneStillPrints() async throws {
        let database = try GameDatabase.bootstrap()
        let stale = now.addingTimeInterval(-rowLag)
        let landed = printedFleet(omitting: "ami_transport_controller", updatedAt: stale)
        try await seedPrintRun(
            database, rows: landed + [hub(updatedAt: stale), carrier(updatedAt: stale)],
            stepStartedAt: now.addingTimeInterval(-5)
        )
        let dispatches = LockIsolated<[String]>([])

        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(now)
            $0.uuid = .incrementing
            $0.devicesClient.fetchAtLocation = { _ in
                printedFleet(omitting: "ami_transport_controller") + [hub(), carrier()]
            }
            $0.commandGovernor.dispatchOwned = { _, _, params, _ in
                dispatches.withValue { $0.append(params.deviceType ?? "?") }
                return .dispatched(.accepted(operationID: nil))
            }
        } operation: {
            let core = DirectiveEngineCore(machines: [MineFleetPrint()], tick: .seconds(5))
            await core.evaluateOnce(directiveID: "P1")
        }

        #expect(dispatches.value == ["ami_transport_controller"])
        let row = try #require(
            await database.read { db in try Directive.where { $0.id.eq("P1") }.fetchOne(db) }
        )
        #expect(row.step == MineFleetPrint.Step.printing)
        #expect(row.status == .running)
    }

    /// A read that will not land is the one thing that must NOT fall through to a
    /// print: the engine's one-round bound collapses it onto the carried reason.
    @Test func aFailedSweepHaltsRatherThanPrinting() async throws {
        let database = try GameDatabase.bootstrap()
        let stale = now.addingTimeInterval(-rowLag)
        let landed = printedFleet(omitting: "ami_transport_controller", updatedAt: stale)
        try await seedPrintRun(
            database, rows: landed + [hub(updatedAt: stale), carrier(updatedAt: stale)],
            stepStartedAt: now.addingTimeInterval(-5)
        )
        struct ReadFailure: Error {}
        let dispatches = LockIsolated<[String]>([])

        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(now)
            $0.uuid = .incrementing
            $0.devicesClient.fetchAtLocation = { _ in throw ReadFailure() }
            $0.commandGovernor.dispatchOwned = { _, _, params, _ in
                dispatches.withValue { $0.append(params.deviceType ?? "?") }
                return .dispatched(.accepted(operationID: nil))
            }
        } operation: {
            let core = DirectiveEngineCore(machines: [MineFleetPrint()], tick: .seconds(5))
            await core.evaluateOnce(directiveID: "P1")
        }

        #expect(dispatches.value.isEmpty)
        let row = try #require(
            await database.read { db in try Directive.where { $0.id.eq("P1") }.fetchOne(db) }
        )
        #expect(row.status == .needsAttention)
        #expect(row.attentionReason == .unreachableDevice)
    }
}
