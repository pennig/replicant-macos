//
//  EventRunFixtures.swift
//  Replicould — DirectiveEngine
//
//  Shared device, directive, event and world fixtures for the `EventRun` suites.
//

import Foundation
import GameModels
import GameServices
import UniverseModels
import Utils
@testable import DirectiveEngine

enum EventRunFixtures {
    /// `commands` defaults to what the live server reports for the type: an
    /// autofactory always advertises `enqueue_print`, packed and under way
    /// included, so only its status ever rules it out as a printer.
    static func device(
        _ code: String, type: String, attachedTo: String? = nil,
        location: String? = "HUB-1", tags: [String] = [], updatedAt: Date = .distantPast,
        cargoUsed: Int? = nil, cargoCapacity: Int? = nil, commands: [String]? = nil
    ) -> Device {
        var hold: [String: JSONValue] = [:]
        if let cargoUsed { hold["cargo_used"] = .number(Double(cargoUsed)) }
        if let cargoCapacity { hold["cargo_capacity"] = .number(Double(cargoCapacity)) }
        return Device(
            deviceCode: code, deviceType: type, replicantCode: "R-1", status: "idle",
            location: location, locationName: nil, operationalCapacity: 1, queueSize: 0,
            stowedInDeviceCode: nil, controllerDeviceCode: nil, attachedToDeviceCode: attachedTo,
            createdAt: .distantPast,
            availableCommands: commands ?? (type == "autofactory" ? ["enqueue_print"] : []),
            features: [], tags: tags,
            detail: .object(hold),
            updatedAt: updatedAt, firstSeenAt: .distantPast
        )
    }

    /// The convoy's courier: wearing the tag its own print stamps, and hosting a
    /// replicant — the two halves `EventRun.isCourier` requires. `world` seeds
    /// `COURIER` into `replicantHostDevices` by default, matching this.
    static func courier(
        _ code: String = "COURIER", attachedTo: String? = nil,
        location: String? = "HUB-1", updatedAt: Date = .distantPast
    ) -> Device {
        device(
            code, type: "matrix_container", attachedTo: attachedTo, location: location,
            tags: [EventRun.rootTag.string], updatedAt: updatedAt
        )
    }

    /// The convoy stood down at the event, courier still aboard the carrier.
    static func onSiteConvoy(
        updatedAt: Date, cargoUsed: Int = 0, cargoCapacity: Int = 500
    ) -> [Device] {
        [
            device("CARRIER", type: "surge_carrier", location: "X-1", updatedAt: updatedAt),
            device(
                "FREIGHT", type: "cargo_freighter", location: "X-1", updatedAt: updatedAt,
                cargoUsed: cargoUsed, cargoCapacity: cargoCapacity
            ),
            courier(attachedTo: "CARRIER", location: "X-1", updatedAt: updatedAt),
        ]
    }

    /// The replicant living in `COURIER`, which is what makes it a courier to a
    /// `WorldSnapshot` read from the database rather than built by hand.
    static func courierReplicant() -> Replicant {
        Replicant(
            replicantCode: "R-COURIER", name: "courier", createdAt: .distantPast,
            currentStar: "X", currentStarName: nil, currentLocation: "X-1",
            currentLocationName: nil, hostedDeviceCode: "COURIER"
        )
    }

    /// The rows that make `HUB-1` recognise as an operational theatre: a printer
    /// standing the depot up, and a relay meshing its system.
    static func depotFleet(updatedAt: Date = .distantPast) -> [Device] {
        [
            Device(
                deviceCode: "PRINTER", deviceType: "autofactory", replicantCode: "R-1",
                status: "idle", location: "HUB-1", locationName: nil, operationalCapacity: 1,
                queueSize: 0, stowedInDeviceCode: nil, controllerDeviceCode: nil,
                attachedToDeviceCode: nil, createdAt: .distantPast,
                availableCommands: ["enqueue_print"], features: ["print"], tags: [],
                detail: .object([:]), updatedAt: updatedAt, firstSeenAt: .distantPast
            ),
            Device(
                deviceCode: "MESH", deviceType: "ftl_relay", replicantCode: "R-1",
                status: "relaying", location: "HUB-1", locationName: nil, operationalCapacity: 1,
                queueSize: 0, stowedInDeviceCode: nil, controllerDeviceCode: nil,
                attachedToDeviceCode: nil, createdAt: .distantPast,
                availableCommands: [], features: ["relay"], tags: [],
                detail: .object([:]), updatedAt: updatedAt, firstSeenAt: .distantPast
            ),
        ]
    }

    /// The stock census that makes the depot `.operational`.
    static func depotFootprint(fetchedAt: Date) -> LocationFootprint {
        LocationFootprint(
            location: "HUB-1", devices: 2, resources: BrainCeiling.aggregateSpendFloor * 2,
            resourceSites: 0, locationEvents: 0, replicants: 0, fetchedAt: fetchedAt
        )
    }

    /// The event carrying LIVE progress, as the ledger reports it mid-run.
    static func progressEvent(
        met: Bool, replicant: Bool, status: String = "active",
        rewards: [String: Int] = ["rares": 400]
    ) -> LocationEvent {
        LocationEvent(
            designation: "X-1-EVT-001", location: "X-1", tier: 1, status: status,
            objectivesMet: met,
            detail: .object([
                "criteria": .array([.object([
                    "name": .string("default"), "devices": .array([]),
                    "resources": .object(["structural": .number(200)]),
                ])]),
                "progress": .object([
                    "met": .bool(met), "replicant_present": .bool(replicant),
                    "options": .array([.object([
                        "name": .string("default"), "met": .bool(met), "devices": .array([]),
                        "resources": .array([.object([
                            "resource_type": .string("structural"),
                            "current": .number(met ? 200 : 0), "required": .number(200),
                            "met": .bool(met),
                        ])]),
                    ])]),
                ]),
                "rewards": .object([
                    "xp": .number(500),
                    "resources": .object(rewards.mapValues { .number(Double($0)) }),
                ]),
            ]),
            firstSeenAt: .distantPast, updatedAt: .distantPast
        )
    }

    static func openPrint(
        on code: String, now: Date, deviceType: String? = nil, quantity: Int = 1
    ) -> [String: GameModels.Operation] {
        var params: [String: JSONValue] = [:]
        if let deviceType {
            params["device_type"] = .string(deviceType)
            params["quantity"] = .number(Double(quantity))
        }
        return [code: GameModels.Operation(
            id: "OP-\(code)", entityCode: code, kind: OperationKind.print.rawValue, status: .active,
            source: .poll, startedAt: now, completesAt: nil, lastConfirmedAt: now,
            detail: params.isEmpty ? .object([:]) : .object(["params": .object(params)])
        )]
    }

    static func directive(step: String, now: Date) -> Directive {
        Directive(
            id: "d1", kind: .eventRun, status: .running, deviceCode: "CARRIER",
            controllerCode: nil, roamCentre: nil,
            fleetTag: EventRun.fleetTag(forTheatre: "HUB-1").string, sourceRelayCode: nil,
            targets: ["X-1-EVT-001"], targetIndex: 0, step: step,
            stepStartedAt: now, returnToOrigin: true, originDesignation: "HUB",
            attentionReason: nil, createdAt: now, updatedAt: now,
            theatreDepot: "HUB-1", freighterCode: "FREIGHT"
        )
    }

    static func event(
        resources: [String: Int] = [:], devices: [(Int, String)]
    ) -> LocationEvent {
        LocationEvent(
            designation: "X-1-EVT-001", location: "X-1", tier: 1, status: "active",
            detail: .object([
                "criteria": .array([.object([
                    "name": .string("default"),
                    "devices": .array(devices.map {
                        .object(["count": .number(Double($0.0)), "device_type": .string($0.1)])
                    }),
                    "resources": .object(resources.mapValues { .number(Double($0)) }),
                ])]),
                "rewards": .object(["xp": .number(500)]),
            ]),
            firstSeenAt: .distantPast, updatedAt: .distantPast
        )
    }

    /// A `.stepStarted` entry, as `DirectiveExecutor.move` writes one.
    static func entered(_ step: String, at occurredAt: Date) -> DirectiveLogEntry {
        DirectiveLogEntry(
            id: "S-\(step)-\(occurredAt.timeIntervalSince1970)", directiveID: "d1", deviceCode: nil,
            kind: .stepStarted, summary: step, step: step, operationID: nil,
            eventID: nil, occurredAt: occurredAt
        )
    }

    /// A `.commandDispatched` entry, in `DirectiveExecutor.dispatchSummary`'s wording.
    static func dispatched(
        _ kind: OperationKind, to deviceCode: String, step: String, at occurredAt: Date
    ) -> DirectiveLogEntry {
        DirectiveLogEntry(
            id: "C-\(kind.rawValue)-\(occurredAt.timeIntervalSince1970)", directiveID: "d1",
            deviceCode: nil, kind: .commandDispatched,
            summary: "Dispatched \(kind.rawValue) to \(deviceCode)",
            step: step, operationID: nil, eventID: nil, occurredAt: occurredAt
        )
    }

    static func world(
        devices: [Device], event: LocationEvent, now: Date,
        footprintFresh: Bool = true, stock: Int = 500_000,
        openOperations: [String: GameModels.Operation] = [:],
        dispatchedOperations: [String: GameModels.Operation] = [:],
        log: [DirectiveLogEntry] = [], hosts: Set<String> = ["COURIER"],
        blueprintBills: [String: ResourceCost] = [:],
        blueprintComponents: [String: [String: Int]] = [:],
        blueprintPrintTimes: [String: Int] = [:]
    ) -> WorldSnapshot {
        WorldSnapshot(
            devices: Dictionary(devices.map { ($0.deviceCode, $0) }, uniquingKeysWith: { _, l in l }),
            openOperations: openOperations,
            log: log,
            dispatchedOperations: dispatchedOperations,
            footprints: [
                "HUB-1": LocationFootprint(
                    location: "HUB-1", devices: devices.count, resources: stock,
                    resourceSites: 0, locationEvents: 0, replicants: 0,
                    fetchedAt: footprintFresh ? now : .distantPast
                )
            ],
            blueprintBills: blueprintBills,
            blueprintComponents: blueprintComponents,
            blueprintPrintTimes: blueprintPrintTimes,
            theatres: [
                Theatre(depot: "HUB-1", system: "HUB", origin: .derived,
                        readiness: .operational, stock: stock)
            ],
            locationEvents: [event.designation: event],
            replicantHostDevices: hosts,
            now: now
        )
    }
}
