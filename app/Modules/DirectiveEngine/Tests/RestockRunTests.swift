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

private func snapshot(
    _ devices: [Device], open: [String: GameModels.Operation] = [:]
) -> WorldSnapshot {
    WorldSnapshot(
        devices: Dictionary(devices.map { ($0.deviceCode, $0) }, uniquingKeysWith: { _, last in last }),
        openOperations: open, dispatchedOperations: [:],
        footprints: [hubLocation: LocationFootprint(
            location: hubLocation, devices: 1, resources: BrainCeiling.aggregateSpendFloor * 2,
            resourceSites: 0, locationEvents: 0, replicants: 0, fetchedAt: now
        )],
        now: now
    )
}

/// `wanting` sizes `targets` so `desiredIdle` reads exactly that demand.
private func restocking(id: String = "R1", wanting: Int, hub code: String = "B1") -> Directive {
    Directive(
        id: id, kind: .restockRun, status: .running, deviceCode: code,
        controllerCode: nil, roamCentre: nil, fleetTag: nil, sourceRelayCode: nil,
        targets: (0..<wanting).map { "T\($0)" }, targetIndex: 0,
        step: RestockRun.Step.stocking.rawValue, stepStartedAt: now.addingTimeInterval(-60),
        returnToOrigin: false, originDesignation: hubSystem, attentionReason: nil,
        createdAt: now.addingTimeInterval(-600), updatedAt: now
    )
}

@Suite("Restock Run — the print-only fan-out (C2)")
struct RestockRunFanOutTests {

    /// C2, punch-list line 255, and Ruling 3's own-print case: the chooser
    /// moves to free bench B2 while B1 holds our own open order, and a
    /// demand of one is already fully covered by it.
    @Test("a substituted bench does not buy a second relay")
    func substitutedBenchBuysNoSecondRelay() {
        let mine = op(on: "B1", owner: "R-1", deviceType: "ftl_relay")
        let world = snapshot([bench("B1", printing: "ftl_relay"), bench("B2")], open: ["B1": mine])

        // Demand is one relay, and one is already on order.
        #expect(RestockRun().nextAction(directive: restocking(id: "R-1", wanting: 1), world: world) == .wait)
    }
}
