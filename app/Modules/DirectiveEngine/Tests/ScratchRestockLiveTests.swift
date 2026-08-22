//
//  ScratchRestockLiveTests.swift
//  Replicould — DirectiveEngine
//
//  SCRATCH: replays the live AINALRAM-BELT-1 restock state to see which gate
//  `RestockRun.stocking` stops at. Delete before merging.
//

import Foundation
import GameModels
import Testing
import UniverseModels
import Utils
@testable import DirectiveEngine

private let liveNow = Date(timeIntervalSince1970: 1_787_000_000)
private let liveDepot = "AINALRAM-BELT-1"

private func liveBench(
    _ code: String,
    type: String = "autofactory",
    status: String,
    queueSize: Int,
    printing: String? = nil,
    queued: [String] = []
) -> Device {
    var detail: [String: JSONValue] = [:]
    if let printing { detail["printing"] = .object(["device_type": .string(printing)]) }
    if !queued.isEmpty {
        detail["print_queue"] = .array(queued.map { .object(["device_type": .string($0)]) })
    }
    return Device(
        deviceCode: code, deviceType: type, replicantCode: "R1", status: status,
        location: liveDepot, locationName: nil, operationalCapacity: 100,
        queueSize: queueSize, stowedInDeviceCode: nil, controllerDeviceCode: nil,
        attachedToDeviceCode: nil, createdAt: Date(timeIntervalSince1970: 0),
        availableCommands: ["enqueue_print"], features: [], tags: [],
        detail: .object(detail), updatedAt: liveNow.addingTimeInterval(-30),
        firstSeenAt: Date(timeIntervalSince1970: 0)
    )
}

private func liveOp(
    _ id: String, on entity: String, owner: String, deviceType: String?,
    status: OperationStatus
) -> GameModels.Operation {
    var params: [String: JSONValue] = [:]
    if let deviceType { params["device_type"] = .string(deviceType) }
    return GameModels.Operation(
        id: id, entityCode: entity, kind: OperationKind.print.rawValue,
        status: status, source: .poll, startedAt: liveNow.addingTimeInterval(-600),
        completesAt: nil, lastConfirmedAt: liveNow.addingTimeInterval(-60),
        detail: .object(["params": .object(params)]), directiveID: owner
    )
}

/// The six benches standing at AINALRAM-BELT-1 in the live DB, 2026-08-22.
private let liveBenches: [Device] = [
    liveBench("43C9B54A", status: "printing (fleet_tender)", queueSize: 10,
              printing: "fleet_tender", queued: ["service_bot"]),
    liveBench("89130889", status: "idle", queueSize: 10),
    liveBench("E9F509DE", status: "printing (structural_fabricator)", queueSize: 10,
              printing: "structural_fabricator", queued: ["cargo_lifter", "ftl_beacon"]),
    liveBench("5DFEDEDA", status: "waiting_for_resources", queueSize: 10,
              queued: ["orbital_foundry", "fusion_barge"]),
    liveBench("DC16B030", status: "idle", queueSize: 10),
    liveBench("1B6C833D", type: "structural_fabricator", status: "idle", queueSize: 0),
]

/// The eventRun's open print ops, the only open ops at the depot.
private let liveEventOps: [String: [GameModels.Operation]] = [
    "43C9B54A": [
        liveOp("OP1", on: "43C9B54A", owner: "EVENTRUN", deviceType: "fleet_tender", status: .active),
        liveOp("OP2", on: "43C9B54A", owner: "EVENTRUN", deviceType: "service_bot", status: .enqueued),
    ],
    "5DFEDEDA": [
        liveOp("OP3", on: "5DFEDEDA", owner: "EVENTRUN", deviceType: "orbital_foundry", status: .enqueued)
    ],
    "E9F509DE": [
        liveOp("OP4", on: "E9F509DE", owner: "EVENTRUN", deviceType: nil, status: .active)
    ],
]

/// The live per-type reading at AINALRAM-BELT-1.
private let liveStock = LocationStock(
    quantities: [
        "carbon": 97_849, "conductive": 157_013, "rares": 67_327,
        "silicates": 141_597, "structural": 608_857, "volatiles": 15_941,
    ],
    fetchedAt: liveNow.addingTimeInterval(-20)
)

private func liveRestock(targets: [String]) -> Directive {
    Directive(
        id: "2EB42927", kind: .restockRun, status: .running, deviceCode: "43C9B54A",
        targets: targets, targetIndex: 0,
        step: RestockRun.Step.stocking.rawValue,
        stepStartedAt: liveNow.addingTimeInterval(-1_400),
        returnToOrigin: false, originDesignation: "AINALRAM", attentionReason: nil,
        createdAt: liveNow.addingTimeInterval(-1_500_000), updatedAt: liveNow,
        theatreDepot: liveDepot
    )
}

private func liveWorld(relays: [Device] = []) -> WorldSnapshot {
    WorldSnapshot(
        devices: Dictionary(
            (liveBenches + relays).map { ($0.deviceCode, $0) }, uniquingKeysWith: { _, last in last }
        ),
        openOperations: liveEventOps.compactMapValues(\.first),
        queuedOperations: liveEventOps,
        footprints: [liveDepot: LocationFootprint(
            location: liveDepot, devices: 56, resources: 1_088_584,
            resourceSites: 0, locationEvents: 0, replicants: 0,
            fetchedAt: liveNow.addingTimeInterval(-20)
        )],
        inventories: [liveDepot: liveStock],
        now: liveNow
    )
}

@Suite("SCRATCH — the live AINALRAM restock state")
struct ScratchRestockLiveTests {

    @Test("what stocking decides with an empty pool and one unmet target")
    func liveDecision() {
        let world = liveWorld()
        let directive = liveRestock(targets: ["SPACA"])
        let benches = PrintScheduler.benches(at: liveDepot, in: world)
        let idle = RelayRun.idleRelays(at: liveDepot, in: world).count
        let onOrder = PrintScheduler.onOrder(for: directive.id, at: liveDepot, in: world)
        let desired = RestockRun.desiredIdle(for: directive, benches: benches.count)
        let action = RestockRun().nextAction(directive: directive, world: world)

        print("SCRATCH benches=\(benches.count) depths=\(benches.map(\.queueDepth)) idle=\(idle) onOrder=\(onOrder) desired=\(desired)")
        print("SCRATCH action=\(action)")
        #expect(benches.count > 0)
    }

    @Test("and with two unmet targets, the state between 15:11 and 15:34")
    func liveDecisionTwoTargets() {
        let spare = Device(
            deviceCode: "4F21DF6E", deviceType: RelayRun.relayDeviceType, replicantCode: "R1",
            status: "inactive", location: liveDepot, locationName: nil,
            operationalCapacity: 100, queueSize: 0, stowedInDeviceCode: nil,
            controllerDeviceCode: nil, attachedToDeviceCode: nil,
            createdAt: Date(timeIntervalSince1970: 0), availableCommands: [],
            features: [], tags: [], detail: .object(["in_control_range": .bool(true)]),
            updatedAt: liveNow.addingTimeInterval(-500), firstSeenAt: Date(timeIntervalSince1970: 0)
        )
        let world = liveWorld(relays: [spare])
        let directive = liveRestock(targets: ["STRIBAR", "SPACA"])
        let benches = PrintScheduler.benches(at: liveDepot, in: world)
        let idle = RelayRun.idleRelays(at: liveDepot, in: world).count
        let desired = RestockRun.desiredIdle(for: directive, benches: benches.count)
        let action = RestockRun().nextAction(directive: directive, world: world)

        print("SCRATCH2 benches=\(benches.count) idle=\(idle) desired=\(desired)")
        print("SCRATCH2 action=\(action)")
        #expect(benches.count > 0)
    }

    /// The live shape at 15:48: the depot's device rows are ~6 min old while
    /// `stepStartedAt` was re-stamped ~60s ago by the previous evaluation.
    @Test("what stocking decides when fleet evidence predates the step")
    func staleFleetEvidence() {
        let aged = liveBenches.map { device -> Device in
            var copy = device
            copy.updatedAt = liveNow.addingTimeInterval(-360)
            return copy
        }
        let world = WorldSnapshot(
            devices: Dictionary(aged.map { ($0.deviceCode, $0) }, uniquingKeysWith: { _, last in last }),
            openOperations: liveEventOps.compactMapValues(\.first),
            queuedOperations: liveEventOps,
            footprints: [liveDepot: LocationFootprint(
                location: liveDepot, devices: 56, resources: 1_088_584,
                resourceSites: 0, locationEvents: 0, replicants: 0,
                fetchedAt: liveNow.addingTimeInterval(-20)
            )],
            inventories: [liveDepot: liveStock],
            now: liveNow
        )
        let directive = Directive(
            id: "2EB42927", kind: .restockRun, status: .running, deviceCode: "43C9B54A",
            targets: ["SPACA"], targetIndex: 0,
            step: RestockRun.Step.stocking.rawValue,
            stepStartedAt: liveNow.addingTimeInterval(-60),
            returnToOrigin: false, originDesignation: "AINALRAM", attentionReason: nil,
            createdAt: liveNow.addingTimeInterval(-1_500_000), updatedAt: liveNow,
            theatreDepot: liveDepot
        )
        let action = RestockRun().nextAction(directive: directive, world: world)
        print("SCRATCH3 fleetStale=\(PrintJob.fleetEvidenceIsStale(directive, at: liveDepot, in: world)) action=\(action)")
        #expect(true)
    }
}
