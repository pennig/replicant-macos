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
        cargoUsed: Int? = nil
    ) -> Device {
        Device(
            deviceCode: code, deviceType: type, replicantCode: "R-1", status: "idle",
            location: location, locationName: nil, operationalCapacity: 1, queueSize: 0,
            stowedInDeviceCode: nil, controllerDeviceCode: nil, attachedToDeviceCode: attachedTo,
            createdAt: .distantPast, availableCommands: [], features: [], tags: tags,
            detail: cargoUsed.map { .object(["cargo_used": .number(Double($0))]) } ?? .object([:]),
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

    static func world(
        devices: [Device], event: LocationEvent, now: Date,
        footprintFresh: Bool = true, stock: Int = 500_000,
        openOperations: [String: GameModels.Operation] = [:]
    ) -> WorldSnapshot {
        WorldSnapshot(
            devices: Dictionary(devices.map { ($0.deviceCode, $0) }, uniquingKeysWith: { _, l in l }),
            openOperations: openOperations,
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
