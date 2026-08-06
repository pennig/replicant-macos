//
//  RepairTestSupport.swift
//  Replicould — DirectiveEngine
//
//  Shared fixtures for the repair test suites. Test target only — production
//  `Sources/` must never carry test fixtures.
//

import Foundation
import GameModels
import Utils
@testable import DirectiveEngine

let repairFixtureNow = Date(timeIntervalSince1970: 1_000)

func device(
    _ code: String,
    type: String,
    location: String? = "SOL-3",
    stowedIn: String? = nil,
    directives: [String] = [],
    capacity: Double = 100,
    updatedAt: Date = repairFixtureNow
) -> Device {
    var detail: [String: JSONValue] = [:]
    if !directives.isEmpty {
        detail["available_directives"] = .array(directives.map(JSONValue.string))
    }
    return Device(
        deviceCode: code, deviceType: type, replicantCode: "R1", status: "idle",
        location: location, locationName: nil, operationalCapacity: capacity, queueSize: 0,
        stowedInDeviceCode: stowedIn, controllerDeviceCode: nil, attachedToDeviceCode: nil,
        createdAt: Date(timeIntervalSince1970: 0), availableCommands: [],
        features: [], tags: [], detail: .object(detail),
        updatedAt: updatedAt, firstSeenAt: Date(timeIntervalSince1970: 0)
    )
}

func world(devices: [Device]) -> WorldSnapshot {
    WorldSnapshot(
        devices: Dictionary(devices.map { ($0.deviceCode, $0) }, uniquingKeysWith: { _, last in last }),
        openOperations: [:], log: [], systems: [:], now: repairFixtureNow
    )
}
