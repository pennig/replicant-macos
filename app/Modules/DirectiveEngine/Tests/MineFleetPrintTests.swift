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
    queueSize: Int = 0, updatedAt: Date = now
) -> Device {
    Device(
        deviceCode: code, deviceType: type, replicantCode: "R1", status: status,
        location: location, locationName: nil, operationalCapacity: 100, queueSize: queueSize,
        stowedInDeviceCode: stowedIn, controllerDeviceCode: controllerDeviceCode,
        attachedToDeviceCode: attachedTo, createdAt: Date(timeIntervalSince1970: 0),
        availableCommands: commands, features: [], tags: tags, detail: .object([:]),
        updatedAt: updatedAt, firstSeenAt: Date(timeIntervalSince1970: 0)
    )
}

private func hub(
    _ code: String = "AF1", location: String = hubLocation,
    queueSize: Int = 0, updatedAt: Date = now
) -> Device {
    mineDevice(
        code, type: "autofactory", location: location,
        commands: ["enqueue_print"], queueSize: queueSize, updatedAt: updatedAt
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
                tags: [MineRecipe.fleetTag.string], location: hubLocation, updatedAt: updatedAt
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
        tags: tagged ? [MineRecipe.carrierTag.string] : [], location: location, status: status,
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
    census(1_000_000, fetchedAt: fetchedAt)
}

private func world(
    devices: [Device],
    openOperations: [String: GameModels.Operation] = [:],
    inventories: [String: LocationStock]? = nil
) -> WorldSnapshot {
    WorldSnapshot(
        devices: Dictionary(devices.map { ($0.deviceCode, $0) }, uniquingKeysWith: { _, last in last }),
        openOperations: openOperations, log: [], dispatchedOperations: [:],
        systems: [:], siteAssays: [:], footprints: healthyCensus(),
        inventories: inventories ?? railClearingInventory(at: hubLocation, fetchedAt: now),
        peers: [], now: now
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
    step: String = MineFleetPrint.Step.stocking.rawValue,
    hub code: String = "AF1",
    stepStartedAt: Date = now.addingTimeInterval(-60)
) -> Directive {
    Directive(
        id: "P1", kind: .mineFleetPrint, status: .running, deviceCode: code,
        controllerCode: nil, roamCentre: nil, fleetTag: MineRecipe.fleetTag.string, sourceRelayCode: nil,
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
                printTags: [MineRecipe.carrierTag.string]
            ),
            nextStep: MineFleetPrint.Step.stocking.rawValue
        ))
    }

    /// The carrier-missing world above, past the print deadline: `stocking`
    /// prints here and `printing` re-decides, so a fallback to either arm
    /// cannot pass this alongside `.wait`.
    @Test("an unknown step waits rather than falling through to a real step")
    func unknownStepWaits() {
        let snapshot = world(devices: printedFleet() + [hub()])
        let run = printRun(
            step: "not-a-real-step",
            stepStartedAt: now.addingTimeInterval(-PrintJob.deadline - 1)
        )

        #expect(MineFleetPrint().nextAction(directive: run, world: snapshot) == .wait)
    }

    /// A recipe shortfall is printed in one job for the whole missing quantity,
    /// tagged into the fleet so `MineRecipe` counts it next tick.
    @Test("a shortfall of three drones prints three drones")
    func shortfallIsPrinted() {
        let snapshot = world(devices: printedFleet(omitting: "mining_drone") + [hub(), carrier()])

        #expect(MineFleetPrint().nextAction(directive: printRun(), world: snapshot) == .dispatch(
            kind: .print, deviceCode: "AF1",
            params: CommandParams(
                deviceType: "mining_drone", quantity: 3, printTags: [MineRecipe.fleetTag.string]
            ),
            nextStep: MineFleetPrint.Step.stocking.rawValue
        ))
    }

    /// An unattributed print in flight leaves real depth to spare, so the run
    /// queues its own job behind it rather than holding.
    @Test("a print already in flight does not block a second, independent one")
    func openOperationWaits() {
        let snapshot = world(
            devices: printedFleet(omitting: "mining_drone") + [hub(queueSize: 10), carrier()],
            openOperations: openPrint(on: "AF1")
        )

        #expect(MineFleetPrint().nextAction(directive: printRun(), world: snapshot)
                == .dispatch(
                    kind: .print, deviceCode: "AF1",
                    params: CommandParams(
                        deviceType: "mining_drone", quantity: 3, printTags: [MineRecipe.fleetTag.string]
                    ),
                    nextStep: MineFleetPrint.Step.stocking.rawValue
                ))
    }

    /// A co-tenant's job leaves real depth to spare, so the run queues its own
    /// print behind it rather than holding for the bench to clear.
    @Test("a co-tenant's print at the hub does not block the run's own")
    func aCoTenantsPrintWaitsRatherThanDispatching() {
        let snapshot = world(
            devices: printedFleet(omitting: "mining_drone") + [hub(queueSize: 10), carrier()],
            openOperations: openPrint(on: "AF1", directiveID: "OTHER")
        )

        #expect(MineFleetPrint().nextAction(directive: printRun(), world: snapshot)
                == .dispatch(
                    kind: .print, deviceCode: "AF1",
                    params: CommandParams(
                        deviceType: "mining_drone", quantity: 3, printTags: [MineRecipe.fleetTag.string]
                    ),
                    nextStep: MineFleetPrint.Step.stocking.rawValue
                ))
    }

    /// Every bench busy is the system working, not a fault — two hubs, each
    /// already AT capacity (`queueSize: 1`, explicit rather than an accident
    /// of the unset default) on another run's print, hold in `printing`.
    @Test("an all-busy depot holds, it does not stall")
    func allBusyWaits() {
        let busy = openPrint(on: "AF1", directiveID: "OTHER")
            .merging(openPrint(on: "AF2", directiveID: "OTHER")) { _, last in last }
        let snapshot = world(
            devices: printedFleet(omitting: "mining_drone")
                + [hub(queueSize: 1), hub("AF2", queueSize: 1), carrier()],
            openOperations: busy
        )

        #expect(MineFleetPrint().nextAction(directive: printRun(), world: snapshot)
                == .advanceStep(nextStep: MineFleetPrint.Step.printing.rawValue))
    }

    /// A depot with no print-capable device at all is still a fault: printing
    /// somewhere else would be a fabrication. Distinct from `missingHubStalls`
    /// above — here the pin resolves to a real row, it just cannot print.
    @Test("a depot with no bench stalls")
    func noBenchStalls() {
        let notAPrinter = mineDevice("AF1", type: "autofactory", location: hubLocation)
        let snapshot = world(devices: printedFleet(omitting: "mining_drone") + [notAPrinter, carrier()])

        #expect(MineFleetPrint().nextAction(directive: printRun(), world: snapshot)
                == .stall(.unreachableDevice))
    }

    /// Our own open print names no type, so `onOrder` cannot net it against
    /// demand — real depth still has room, so the run queues a second job
    /// rather than holding.
    @Test("an untyped open print of our own does not net, and does not block")
    func ourOwnPrintStillWaits() {
        let directive = printRun()
        let snapshot = world(
            devices: printedFleet(omitting: "mining_drone") + [hub(queueSize: 10), carrier()],
            openOperations: openPrint(on: "AF1", directiveID: directive.id)
        )

        #expect(MineFleetPrint().nextAction(directive: directive, world: snapshot)
                == .dispatch(
                    kind: .print, deviceCode: "AF1",
                    params: CommandParams(
                        deviceType: "mining_drone", quantity: 3, printTags: [MineRecipe.fleetTag.string]
                    ),
                    nextStep: MineFleetPrint.Step.stocking.rawValue
                ))
    }

    /// Nothing polls `LocationFootprint`, so a stale census buys its own read
    /// rather than waiting for another mission to happen to refresh.
    @Test("a stale census is refreshed rather than waited out")
    func staleCensusBuysARefresh() {
        let stale = now.addingTimeInterval(-(RelayRun.pollInterval + 60))
        let snapshot = world(
            devices: printedFleet(omitting: "mining_drone") + [hub(), carrier()],
            inventories: railClearingInventory(at: hubLocation, fetchedAt: stale)
        )

        #expect(MineFleetPrint().nextAction(directive: printRun(), world: snapshot)
                == .refreshFootprint(nextStep: MineFleetPrint.Step.stocking.rawValue, thenStall: nil))
    }

    /// **Short stock idles, it never stalls.** The hub buffer refills from
    /// salvage, so a print the reserve rail vetoes is the system working.
    @Test("the reserve floor vetoes the print without escalating")
    func shortStockWaitsAndNeverStalls() {
        let snapshot = world(
            devices: printedFleet(omitting: "mining_drone") + [hub(), carrier()],
            inventories: [hubLocation: railShortStock(fetchedAt: now)]
        )

        let action = MineFleetPrint().nextAction(directive: printRun(), world: snapshot)
        #expect(action == .wait)
        if case .stall = action { Issue.record("short stock escalated to a human") }
    }

    /// Count-based, so a superseded print op cannot strand the step: the fleet
    /// is whole, whichever job produced it.
    @Test("printing hands back to stocking once the shortfall is met")
    func printingAdvancesWhenSatisfied() {
        let directive = printRun(step: MineFleetPrint.Step.printing.rawValue)
        let snapshot = world(devices: printedFleet() + [hub(), carrier()])

        #expect(MineFleetPrint().nextAction(directive: directive, world: snapshot)
                == .advanceStep(nextStep: MineFleetPrint.Step.stocking.rawValue))
    }

    /// While the print is genuinely in flight the run holds still.
    @Test("printing holds while the print op is open")
    func printingWaitsOnTheOpenOp() {
        let directive = printRun(step: MineFleetPrint.Step.printing.rawValue)
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
        let directive = printRun(step: MineFleetPrint.Step.printing.rawValue)
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
            step: MineFleetPrint.Step.printing.rawValue,
            stepStartedAt: now.addingTimeInterval(-(PrintJob.deadline + 60))
        )
        let snapshot = world(devices: printedFleet(omitting: "mining_drone") + [hub(), carrier()])

        #expect(MineFleetPrint().nextAction(directive: directive, world: snapshot)
                == .advanceStep(nextStep: MineFleetPrint.Step.stocking.rawValue))
    }

    /// A bench is shared, and `openOperation` is keyed by device alone, so a
    /// co-tenant's print must not hold this run past its own deadline.
    @Test("the deadline still fires while an op holds the bench")
    func printingRedecidesPastTheDeadlineWithTheBenchBusy() {
        let directive = printRun(
            step: MineFleetPrint.Step.printing.rawValue,
            stepStartedAt: now.addingTimeInterval(-(PrintJob.deadline + 60))
        )
        let snapshot = world(
            devices: printedFleet(omitting: "mining_drone") + [hub(), carrier()],
            openOperations: openPrint(on: "AF1")
        )

        #expect(MineFleetPrint().nextAction(directive: directive, world: snapshot)
                == .advanceStep(nextStep: MineFleetPrint.Step.stocking.rawValue))
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
                printTags: [MineRecipe.carrierTag.string]
            ),
            nextStep: MineFleetPrint.Step.stocking.rawValue
        ))
    }

    @Test func stepVocabularyIsFrozen() {
        #expect(MineFleetPrint.Step.allCases.map(\.rawValue) == ["stocking", "printing"])
    }
}

// MARK: - Fan-out fixtures

/// Every recipe type except three, so `stocking` always has real demand to net
/// against `onOrder` across several ticks.
private func fanOutShortFleet() -> [Device] {
    let short: Set<String> = ["ami_mining_controller", "mining_drone", "ami_survey_controller"]
    var out: [Device] = []
    var n = 0
    for (type, quantity) in MineRecipe.all where !short.contains(type) {
        for _ in 0..<quantity {
            n += 1
            out.append(mineDevice(
                "N\(String(format: "%02d", n))", type: type,
                tags: [MineRecipe.fleetTag.string], location: hubLocation
            ))
        }
    }
    return out + [carrier()]
}

/// A print-capable autofactory bench. `printing` mirrors a snapshot's own
/// `printing` block, matching `PrintSchedulerTests.bench`.
private func bench(_ code: String, printing: String? = nil) -> Device {
    var detail: [String: JSONValue] = [:]
    if let printing { detail["printing"] = .object(["device_type": .string(printing)]) }
    return Device(
        deviceCode: code, deviceType: "autofactory", replicantCode: "R1", status: "idle",
        location: hubLocation, locationName: nil, operationalCapacity: 100, queueSize: 0,
        stowedInDeviceCode: nil, controllerDeviceCode: nil, attachedToDeviceCode: nil,
        createdAt: Date(timeIntervalSince1970: 0), availableCommands: ["enqueue_print"],
        features: [], tags: [], detail: .object(detail), updatedAt: now,
        firstSeenAt: Date(timeIntervalSince1970: 0)
    )
}

/// An open print op naming a device type and quantity, so it counts toward
/// `PrintScheduler.onOrder`.
private func op(
    on entity: String, owner: String, deviceType: String, quantity: Int? = nil
) -> GameModels.Operation {
    var params: [String: JSONValue] = ["device_type": .string(deviceType)]
    if let quantity { params["quantity"] = .number(Double(quantity)) }
    return GameModels.Operation(
        id: "OP-\(entity)", entityCode: entity, kind: OperationKind.print.rawValue,
        status: .active, source: .poll, startedAt: now, completesAt: nil,
        lastConfirmedAt: now, detail: .object(["params": .object(params)]), directiveID: owner
    )
}

/// `benches` at the hub alongside a fixed fan-out shortfall, so every fan-out
/// test always has real demand behind it.
private func snapshot(
    _ benches: [Device], open: [String: GameModels.Operation] = [:]
) -> WorldSnapshot {
    world(devices: fanOutShortFleet() + benches, openOperations: open)
}

private func row(
    step: String = MineFleetPrint.Step.stocking.rawValue, startedAgo interval: TimeInterval = 60
) -> Directive {
    printRun(step: step, hub: "B1", stepStartedAt: now.addingTimeInterval(-interval))
}

@Suite("MineFleetPrint — the print-only fan-out (C1)")
struct MineFleetPrintFanOutTests {

    /// The Stage 3 acceptance criterion. Three autofactories, a shortfall of at
    /// least three types, and three prints in flight after three evaluations —
    /// one per tick, because `MissionAction.dispatch` carries one command.
    @Test("three benches carry three types")
    func threeBenchesCarryThreeTypes() {
        var world = snapshot([bench("B1"), bench("B2"), bench("B3")])
        var directive = row()
        var open: [String: GameModels.Operation] = [:]
        var dispatched: [String] = []

        for _ in 0..<3 {
            guard case let .dispatch(_, deviceCode, params, next) =
                MineFleetPrint().nextAction(directive: directive, world: world)
            else { return #expect(Bool(false), "expected a dispatch") }
            dispatched.append(deviceCode)
            open[deviceCode] = op(
                on: deviceCode, owner: directive.id,
                deviceType: params.deviceType!, quantity: params.quantity
            )
            world = snapshot([bench("B1"), bench("B2"), bench("B3")], open: open)
            directive.step = next
            // The executor re-stamps on advanceStep; the fan-out must not depend
            // on the stamp, so hold it still.
        }

        #expect(Set(dispatched) == ["B1", "B2", "B3"])
        #expect(Set(open.values.compactMap(\.printedDeviceType)).count == 3)
    }

    /// "With one autofactory, behaviour equals today's." A single bench still
    /// orders one job at a time and waits for it — the fan-out must not turn
    /// into a queue of orders nobody can serve.
    @Test("one bench orders one job and then waits")
    func oneBenchOrdersOneJob() {
        var world = snapshot([bench("B1")])
        let directive = row()

        guard case let .dispatch(_, deviceCode, params, _) =
            MineFleetPrint().nextAction(directive: directive, world: world)
        else { return #expect(Bool(false), "expected a dispatch") }

        world = snapshot(
            [bench("B1", printing: params.deviceType)],
            open: ["B1": op(on: deviceCode, owner: directive.id,
                            deviceType: params.deviceType!, quantity: params.quantity)]
        )

        #expect(MineFleetPrint().nextAction(directive: directive, world: world)
                == .advanceStep(nextStep: MineFleetPrint.Step.printing.rawValue))
    }

    /// "A co-tenant's job never blocks or extends another run's deadline."
    /// Two runs, one depot, two benches: each gets one and neither waits on
    /// the other, and neither run's step clock is touched by the other's job.
    @Test("a co-tenant's print neither blocks nor extends this run")
    func coTenantNeitherBlocksNorExtends() {
        let theirs = op(on: "B1", owner: "OTHER", deviceType: "mining_drone")
        let world = snapshot(
            [bench("B1", printing: "mining_drone"), bench("B2")], open: ["B1": theirs]
        )

        guard case let .dispatch(_, deviceCode, _, _) =
            MineFleetPrint().nextAction(directive: row(startedAgo: 60), world: world)
        else { return #expect(Bool(false), "expected a dispatch") }
        #expect(deviceCode == "B2")

        // The co-tenant's job must not extend THIS run's deadline: drive it
        // through printing with the co-tenant's bench the only one present.
        let stalled = snapshot([bench("B1", printing: "mining_drone")], open: ["B1": theirs])
        let recent = row(step: MineFleetPrint.Step.printing.rawValue, startedAgo: 60)
        #expect(MineFleetPrint().nextAction(directive: recent, world: stalled) == .wait)

        let expired = row(step: MineFleetPrint.Step.printing.rawValue, startedAgo: PrintJob.deadline + 1)
        #expect(MineFleetPrint().nextAction(directive: expired, world: stalled)
                == .advanceStep(nextStep: MineFleetPrint.Step.stocking.rawValue))
    }

    /// Our own print sits open on B1, demand covered; B2 stands free. `choose`
    /// cannot see ownership, so only `onOrder` netting stops a second order —
    /// the run holds in `printing`, it does not complete.
    @Test("this run's own print on one bench draws no second once demand is covered")
    func ownPrintCoveringDemandDrawsNoSecondBench() {
        let directive = printRun()
        let mine = op(on: "AF1", owner: directive.id, deviceType: "mining_drone", quantity: 3)
        let snapshot = world(
            devices: printedFleet(omitting: "mining_drone") + [hub(), hub("AF2"), carrier()],
            openOperations: ["AF1": mine]
        )

        let action = MineFleetPrint().nextAction(directive: directive, world: snapshot)
        #expect(action != .dispatch(
            kind: .print, deviceCode: "AF2",
            params: CommandParams(deviceType: "mining_drone", quantity: 3, printTags: [MineRecipe.fleetTag.string]),
            nextStep: MineFleetPrint.Step.stocking.rawValue
        ), "the over-print bug this stage exists to fix")
        #expect(action == .advanceStep(nextStep: MineFleetPrint.Step.printing.rawValue))
    }
}

// MARK: - Two runs sharing one depot, through the engine

/// Ticket 18's co-tenant criterion, proved through the real engine: unlike the
/// unit table above, this exercises `WorldSnapshot.read` and the operations
/// table fresh between the two evaluations.
@Suite("MineFleetPrint — two runs at one depot, through the engine")
struct MineFleetPrintCoTenancyEngineTests {

    /// Two `mineFleetPrint` rows, two benches, one evaluation each: each lands
    /// its own op on its own bench and neither is superseded.
    @Test func twoRunsAtOneDepotEachKeepTheirOwnOp() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Directive.insert { printRun(hub: "AF1") }.execute(db)
            try Directive.insert {
                Directive(
                    id: "P2", kind: .mineFleetPrint, status: .running, deviceCode: "AF1",
                    controllerCode: nil, roamCentre: nil, fleetTag: MineRecipe.fleetTag.string,
                    sourceRelayCode: nil, targets: [], targetIndex: 0,
                    step: MineFleetPrint.Step.stocking.rawValue,
                    stepStartedAt: now.addingTimeInterval(-60),
                    returnToOrigin: false, originDesignation: hubSystem, attentionReason: nil,
                    createdAt: now.addingTimeInterval(-600), updatedAt: now
                )
            }.execute(db)
            for row in printedFleet(omitting: "mining_drone") + [hub(), hub("AF2"), carrier()] {
                try Device.upsert { row }.execute(db)
            }
            try LocationFootprint.upsert {
                LocationFootprint(
                    location: hubLocation, devices: 3,
                    resources: 1_000_000,
                    resourceSites: 0, locationEvents: 0, replicants: 0, fetchedAt: now
                )
            }.execute(db)
            try LocationInventory.insert { railClearingRows(at: hubLocation, fetchedAt: now) }.execute(db)
        }
        let opCounter = LockIsolated(0)

        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(now)
            $0.uuid = .incrementing
            $0.commandGovernor.dispatchOwned = { kind, deviceCode, _, owner in
                let n = opCounter.withValue { $0 += 1; return $0 }
                try? await database.write { db in
                    try GameModels.Operation.insert {
                        GameModels.Operation(
                            id: "OP-\(n)", entityCode: deviceCode, kind: kind.rawValue,
                            status: .active, source: .optimistic, startedAt: now,
                            completesAt: nil, lastConfirmedAt: now, detail: .object([:]),
                            directiveID: owner?.directiveID, step: owner?.step
                        )
                    }.execute(db)
                }
                return .dispatched(.accepted(operationID: "OP-\(n)"))
            }
        } operation: {
            let core = DirectiveEngineCore(machines: [MineFleetPrint()], tick: .seconds(5))
            await core.evaluateOnce(directiveID: "P1")
            await core.evaluateOnce(directiveID: "P2")
        }

        let ops = try await database.read { db in try GameModels.Operation.all.fetchAll(db) }
        #expect(Set(ops.map(\.entityCode)) == ["AF1", "AF2"])
        #expect(ops.allSatisfy { $0.status != .superseded })
        let p1 = try await database.read { db in try Directive.where { $0.id.eq("P1") }.fetchOne(db) }
        let p2 = try await database.read { db in try Directive.where { $0.id.eq("P2") }.fetchOne(db) }
        #expect(p1?.attentionReason == nil)
        #expect(p2?.attentionReason == nil)
    }
}

// MARK: - stocking and printing must agree on completion

/// `stocking` and `printing` must agree on what finished means: both key
/// off the un-netted shortfall, so ordering demand is never mistaken for
/// delivering it.
@Suite("MineFleetPrint — fully-ordered demand does not complete the run")
struct MineFleetPrintCompletionGuardTests {

    /// Demand outstanding, fully covered by an open order, no device rows for
    /// the clone yet: the run must hold in `printing`, not report `.completed`.
    @Test func fullyOrderedDemandHoldsInPrintingRatherThanCompleting() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Directive.insert { printRun(hub: "AF1") }.execute(db)
            for row in printedFleet(omitting: "mining_drone") + [hub(), carrier()] {
                try Device.upsert { row }.execute(db)
            }
            try GameModels.Operation.insert {
                GameModels.Operation(
                    id: "OP-1", entityCode: "AF1", kind: OperationKind.print.rawValue,
                    status: .active, source: .poll, startedAt: now, completesAt: nil,
                    lastConfirmedAt: now,
                    detail: .object(["params": .object([
                        "device_type": .string("mining_drone"), "quantity": .number(3),
                    ])]),
                    directiveID: "P1"
                )
            }.execute(db)
            try LocationFootprint.upsert {
                LocationFootprint(
                    location: hubLocation, devices: 2,
                    resources: 1_000_000,
                    resourceSites: 0, locationEvents: 0, replicants: 0, fetchedAt: now
                )
            }.execute(db)
            try LocationInventory.insert { railClearingRows(at: hubLocation, fetchedAt: now) }.execute(db)
        }

        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(now)
            $0.uuid = .incrementing
            $0.commandGovernor.dispatchOwned = { _, _, _, _ in .dispatched(.accepted(operationID: nil)) }
        } operation: {
            let core = DirectiveEngineCore(machines: [MineFleetPrint()], tick: .seconds(5))
            await core.evaluateOnce(directiveID: "P1")
        }

        let row = try #require(
            await database.read { db in try Directive.where { $0.id.eq("P1") }.fetchOne(db) }
        )
        #expect(row.step == MineFleetPrint.Step.printing.rawValue)
        #expect(row.status == .running)
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
                printTags: [MineRecipe.fleetTag.string]
            ),
            nextStep: MineFleetPrint.Step.stocking.rawValue
        ))
    }

    /// An unattributed open print leaves real depth to spare, so the run
    /// proceeds to order its own job — and, with the fleet row this stale,
    /// buys the sweep first rather than spending on unconfirmed evidence.
    @Test("an open print op does not block a fleet-evidence sweep")
    func anOpenOpSpendsNoRead() {
        let stale = now.addingTimeInterval(-rowLag)
        let snapshot = world(
            devices: printedFleet(omitting: "ami_transport_controller", updatedAt: stale)
                + [hub(queueSize: 10, updatedAt: stale), carrier(updatedAt: stale)],
            openOperations: openPrint(on: "AF1")
        )
        let directive = printRun(stepStartedAt: now.addingTimeInterval(-5))

        #expect(MineFleetPrint().nextAction(directive: directive, world: snapshot)
                == .refreshDevicesInSystem(designation: hubLocation, thenStall: .unreachableDevice))
    }

    /// A veto path spends nothing either: the sweep sits at the last moment before
    /// the print, after every branch that declines to print at all.
    @Test("the reserve veto declines before the sweep is bought")
    func aVetoedPrintSpendsNoRead() {
        let stale = now.addingTimeInterval(-rowLag)
        let snapshot = world(
            devices: printedFleet(omitting: "ami_transport_controller", updatedAt: stale)
                + [hub(updatedAt: stale), carrier(updatedAt: stale)],
            inventories: [hubLocation: railShortStock(fetchedAt: now)]
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
            step: MineFleetPrint.Step.printing.rawValue,
            stepStartedAt: now.addingTimeInterval(-(PrintJob.deadline + 60))
        )
        let snapshot = world(devices:
            printedFleet(omitting: "ami_transport_controller", updatedAt: stale)
                + [hub(updatedAt: stale), carrier(updatedAt: stale)]
        )

        #expect(MineFleetPrint().nextAction(directive: directive, world: snapshot)
                == .advanceStep(nextStep: MineFleetPrint.Step.stocking.rawValue))
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
                resources: 1_000_000,
                resourceSites: 0, locationEvents: 0, replicants: 0, fetchedAt: now
            )
        }
        .execute(db)
        try LocationInventory.insert { railClearingRows(at: hubLocation, fetchedAt: now) }.execute(db)
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
            "CLONE1", type: "ami_transport_controller", tags: [MineRecipe.fleetTag.string],
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
        #expect(row.step == MineFleetPrint.Step.stocking.rawValue)
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
