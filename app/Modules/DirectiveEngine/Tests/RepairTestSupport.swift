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

func repairDevice(
    _ code: String,
    type: String,
    location: String? = "SOL-3",
    stowedIn: String? = nil,
    directives: [String] = [],
    currentDirective: String? = nil,
    currentDirectiveStatus: String? = nil,
    capacity: Double = 100,
    updatedAt: Date = repairFixtureNow,
    repairingTarget: String? = nil,
    travelArrival: Date? = nil
) -> Device {
    var detail: [String: JSONValue] = [:]
    if !directives.isEmpty {
        detail["available_directives"] = .array(directives.map(JSONValue.string))
    }
    if let currentDirective {
        detail["ami_directive"] = .object(["name": .string(currentDirective)])
    }
    if let currentDirectiveStatus {
        detail["ami_directive_status"] = .string(currentDirectiveStatus)
    }
    if let repairingTarget {
        detail["repair"] = .object(["target_device_code": .string(repairingTarget)])
    }
    if let travelArrival {
        let stamp = travelArrival.formatted(.iso8601)
        detail["travel"] = .object(["arrives_at": .string(stamp)])
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

func repairWorld(
    devices: [Device],
    log: [DirectiveLogEntry] = [],
    openOperations: [String: GameModels.Operation] = [:]
) -> WorldSnapshot {
    WorldSnapshot(
        devices: Dictionary(devices.map { ($0.deviceCode, $0) }, uniquingKeysWith: { _, last in last }),
        openOperations: openOperations, log: log, systems: [:], now: repairFixtureNow
    )
}

/// The `.stepStarted` entries `DirectiveExecutor.move` writes, one per named
/// step, ordered oldest first the way `WorldSnapshot.read` returns them.
func repairStepLog(_ steps: [String]) -> [DirectiveLogEntry] {
    steps.enumerated().map { index, step in
        DirectiveLogEntry(
            id: "L\(index)", directiveID: "D1", deviceCode: nil, kind: .stepStarted,
            summary: "Step: \(step)", step: step, operationID: nil, eventID: nil,
            occurredAt: repairFixtureNow.addingTimeInterval(Double(index))
        )
    }
}

func repairDirective(
    step: String,
    deviceCode: String,
    targets: [String] = [],
    targetIndex: Int = 0,
    stepStartedAt: Date = repairFixtureNow
) -> Directive {
    Directive(
        id: "D1", kind: .surveyRun, status: .running, deviceCode: deviceCode,
        targets: targets, targetIndex: targetIndex,
        step: step, stepStartedAt: stepStartedAt, returnToOrigin: false,
        originDesignation: nil, attentionReason: nil,
        createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0)
    )
}
