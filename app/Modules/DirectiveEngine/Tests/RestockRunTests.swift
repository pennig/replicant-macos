//
//  RestockRunTests.swift
//  Replicould — DirectiveEngine
//
//  The Restock Run's print-only fan-out (C2): demand nets against what is
//  already `onOrder`, so a bench substitution never buys a second relay.
//

import Foundation
import GameModels
import Testing
import UniverseModels
import Utils
@testable import DirectiveEngine

private let now = Date(timeIntervalSince1970: 1_750_000_000)
private let hubLocation = "AINALRAM-BELT-1"
private let hubSystem = "AINALRAM"

private let depot = hubLocation

private func bench(_ code: String, printing: String? = nil, updatedAt: Date = now) -> Device {
    var detail: [String: JSONValue] = [:]
    if let printing { detail["printing"] = .object(["device_type": .string(printing)]) }
    return Device(
        deviceCode: code, deviceType: "autofactory", replicantCode: "R1", status: "idle",
        location: hubLocation, locationName: nil, operationalCapacity: 100, queueSize: 0,
        stowedInDeviceCode: nil, controllerDeviceCode: nil, attachedToDeviceCode: nil,
        createdAt: Date(timeIntervalSince1970: 0), availableCommands: ["enqueue_print"],
        features: [], tags: [], detail: .object(detail), updatedAt: updatedAt,
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

private func snapshot(
    _ devices: [Device], open: [String: GameModels.Operation] = [:],
    stock: LocationStock? = nil
) -> WorldSnapshot {
    WorldSnapshot(
        devices: Dictionary(devices.map { ($0.deviceCode, $0) }, uniquingKeysWith: { _, last in last }),
        openOperations: open, dispatchedOperations: [:],
        footprints: [hubLocation: LocationFootprint(
            location: hubLocation, devices: 1, resources: 1_000_000,
            resourceSites: 0, locationEvents: 0, replicants: 0, fetchedAt: now
        )],
        inventories: [hubLocation: stock ?? railClearingStock(fetchedAt: now)],
        now: now
    )
}

/// `wanting` sizes `targets` so `desiredIdle` reads exactly that demand.
private func restocking(
    id: String = "R1", wanting: Int = 1, hub code: String = "B1", startedAgo: TimeInterval = 60
) -> Directive {
    Directive(
        id: id, kind: .restockRun, status: .running, deviceCode: code,
        controllerCode: nil, roamCentre: nil, fleetTag: nil, sourceRelayCode: nil,
        targets: (0..<wanting).map { "T\($0)" }, targetIndex: 0,
        step: RestockRun.Step.stocking.rawValue, stepStartedAt: now.addingTimeInterval(-startedAgo),
        returnToOrigin: false, originDesignation: hubSystem, attentionReason: nil,
        createdAt: now.addingTimeInterval(-600), updatedAt: now
    )
}

/// A directive whose `targets` count is `count` and nothing else — the shape
/// `desiredIdle` reads demand off.
private func wanting(_ count: Int) -> Directive {
    restocking(wanting: count)
}

@Suite("Restock Run — the print-only fan-out (C2)")
struct RestockRunFanOutTests {

    /// C2, punch-list line 255: the chooser moves to free bench B2 while B1
    /// holds our own open order, and a demand of one is already fully
    /// covered by it.
    @Test("a substituted bench does not buy a second relay")
    func substitutedBenchBuysNoSecondRelay() {
        let mine = op(on: "B1", owner: "R-1", deviceType: "ftl_relay")
        let world = snapshot([bench("B1", printing: "ftl_relay"), bench("B2")], open: ["B1": mine])

        // Demand is one relay, and one is already on order.
        #expect(RestockRun().nextAction(directive: restocking(id: "R-1", wanting: 1), world: world) == .wait)
    }
}

@Suite("Restock Run — the cap scales with benches, and buys evidence before it spends (C8)")
struct RestockRunCapAndSweepTests {

    /// The cap is per-bench first, then an absolute ceiling: written with
    /// literals rather than in terms of `idleCap`, so that changing either
    /// term reddens this test.
    @Test("the idle cap scales with bench count")
    func idleCapScalesWithBenches() {
        // One bench: three. Four benches: twelve, clipped to ten.
        #expect(RestockRun.desiredIdle(for: wanting(20), benches: 1) == 3)
        #expect(RestockRun.desiredIdle(for: wanting(20), benches: 3) == 9)
        #expect(RestockRun.desiredIdle(for: wanting(20), benches: 4) == 10)
        #expect(RestockRun.desiredIdle(for: wanting(20), benches: 0) == 0)
    }

    /// In the live row `targets.count` is 1, so the cap has never been the
    /// binding term. This fixture manufactures the case where it is.
    @Test("demand still binds below the cap")
    func demandBindsBelowTheCap() {
        #expect(RestockRun.desiredIdle(for: wanting(1), benches: 4) == 1)
    }

    /// A printed clone's row lands off the SSE frame minutes to hours after its
    /// print op closes, so "no op open" is not evidence the pool is still
    /// short. automation-brain ticket 14.
    @Test("stale fleet evidence buys a sweep before the spend")
    func staleEvidenceBuysASweep() {
        // Every device row at the depot predates the step stamp, so nothing
        // observed since this step began can vouch for the pool.
        let stale = bench("B1", updatedAt: now.addingTimeInterval(-3600))
        let world = snapshot([stale])

        #expect(
            RestockRun().nextAction(directive: restocking(startedAgo: 60), world: world)
                == .refreshDevicesInSystem(designation: depot, thenStall: .unreachableDevice)
        )
    }

    /// The gate sits LAST: with the reserve rail already short, fleet
    /// evidence being stale too must never buy a sweep before the veto lands.
    @Test("a short reserve declines before the sweep is ever reached")
    func shortReserveDeclinesBeforeTheSweep() {
        let stale = bench("B1", updatedAt: now.addingTimeInterval(-3600))
        let world = snapshot([stale], stock: railShortStock(fetchedAt: now))

        #expect(RestockRun().nextAction(directive: restocking(startedAgo: 60), world: world) == .wait)
    }
}
