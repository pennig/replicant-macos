//
//  MineFleetPrintTests.swift
//  Replicould — DirectiveEngine
//
//  `MineFleetPrint` as a verdict table: prints, waits, and the one escalation.
//

import Foundation
import GameModels
import GameServices
import Testing
import UniverseModels
import Utils
@testable import DirectiveEngine

// MARK: - Fixtures

private let now = Date(timeIntervalSince1970: 1_750_000_000)
private let hubLocation = "AINALRAM-BELT-1"
private let hubSystem = "AINALRAM"

private func mineDevice(
    _ code: String, type: String, tags: [String] = [], location: String? = nil,
    status: String = "idle", stowedIn: String? = nil, attachedTo: String? = nil,
    controllerDeviceCode: String? = nil, commands: [String] = []
) -> Device {
    Device(
        deviceCode: code, deviceType: type, replicantCode: "R1", status: status,
        location: location, locationName: nil, operationalCapacity: 100, queueSize: 0,
        stowedInDeviceCode: stowedIn, controllerDeviceCode: controllerDeviceCode,
        attachedToDeviceCode: attachedTo, createdAt: Date(timeIntervalSince1970: 0),
        availableCommands: commands, features: [], tags: tags, detail: .object([:]),
        updatedAt: now, firstSeenAt: Date(timeIntervalSince1970: 0)
    )
}

private func hub(_ code: String = "AF1", location: String = hubLocation) -> Device {
    mineDevice(code, type: "autofactory", location: location, commands: ["enqueue_print"])
}

/// A complete unassigned mine fleet standing at the hub — one row per recipe slot.
private func printedFleet(omitting omitted: String? = nil) -> [Device] {
    var out: [Device] = []
    var n = 0
    for (type, quantity) in MineRecipe.all where type != omitted {
        for _ in 0..<quantity {
            n += 1
            out.append(mineDevice(
                "M\(String(format: "%02d", n))", type: type,
                tags: [MineRecipe.fleetTag], location: hubLocation
            ))
        }
    }
    return out
}

private func carrier(
    _ code: String = "SC1", tagged: Bool = true, status: String = "idle",
    location: String? = hubLocation
) -> Device {
    mineDevice(
        code, type: MineRecipe.carrierDeviceType,
        tags: tagged ? [MineRecipe.carrierTag] : [], location: location, status: status
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

private func openPrint(on entity: String) -> [String: GameModels.Operation] {
    [entity: GameModels.Operation(
        id: "OP-1", entityCode: entity, kind: OperationKind.print.rawValue, status: .active,
        source: .poll, startedAt: now, completesAt: nil, lastConfirmedAt: now, detail: .object([:])
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
}
