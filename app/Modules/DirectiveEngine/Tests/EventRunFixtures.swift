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
    static func device(
        _ code: String, type: String, attachedTo: String? = nil,
        location: String? = "HUB-1", tags: [String] = [], updatedAt: Date = .distantPast,
        cargoUsed: Int? = nil, cargoCapacity: Int? = nil
    ) -> Device {
        var hold: [String: JSONValue] = [:]
        if let cargoUsed { hold["cargo_used"] = .number(Double(cargoUsed)) }
        if let cargoCapacity { hold["cargo_capacity"] = .number(Double(cargoCapacity)) }
        return Device(
            deviceCode: code, deviceType: type, replicantCode: "R-1", status: "idle",
            location: location, locationName: nil, operationalCapacity: 1, queueSize: 0,
            stowedInDeviceCode: nil, controllerDeviceCode: nil, attachedToDeviceCode: attachedTo,
            createdAt: .distantPast, availableCommands: [], features: [], tags: tags,
            detail: .object(hold),
            updatedAt: updatedAt, firstSeenAt: .distantPast
        )
    }

    static func openPrint(on code: String, now: Date) -> [String: GameModels.Operation] {
        [code: GameModels.Operation(
            id: "OP-1", entityCode: code, kind: OperationKind.print.rawValue, status: .active,
            source: .poll, startedAt: now, completesAt: nil, lastConfirmedAt: now,
            detail: .object([:])
        )]
    }

    static func directive(step: String, now: Date) -> Directive {
        Directive(
            id: "d1", kind: .eventRun, status: .running, deviceCode: "CARRIER",
            controllerCode: nil, roamCentre: nil,
            fleetTag: EventRun.fleetTag(forTheatre: "HUB-1"), sourceRelayCode: nil,
            targets: ["X-1-EVT-001"], targetIndex: 0, step: step,
            stepStartedAt: now, returnToOrigin: true, originDesignation: "HUB",
            attentionReason: nil, createdAt: now, updatedAt: now,
            theatreDepot: "HUB-1", freighterCode: "FREIGHT"
        )
    }

    static func event(resources: [String: Int], devices: [(Int, String)]) -> LocationEvent {
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
        log: [DirectiveLogEntry] = []
    ) -> WorldSnapshot {
        WorldSnapshot(
            devices: Dictionary(devices.map { ($0.deviceCode, $0) }, uniquingKeysWith: { _, l in l }),
            openOperations: openOperations,
            log: log,
            footprints: [
                "HUB-1": LocationFootprint(
                    location: "HUB-1", devices: devices.count, resources: stock,
                    resourceSites: 0, locationEvents: 0, replicants: 0,
                    fetchedAt: footprintFresh ? now : .distantPast
                )
            ],
            theatres: [
                Theatre(depot: "HUB-1", system: "HUB", origin: .derived,
                        readiness: .operational, stock: stock)
            ],
            locationEvents: [event.designation: event],
            now: now
        )
    }
}
