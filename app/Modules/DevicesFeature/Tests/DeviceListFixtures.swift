//
//  DeviceListFixtures.swift
//  Replicould — Devices feature tests
//
//  Shared builders for the `DeviceListLayout` suites. Named `makeDevice` (not
//  `device`) so it can't collide with the file-private `device(_:status:)` in
//  `DevicesFeatureTests.swift`.
//

import Foundation
import GameModels
import Utils

func makeDevice(
    _ code: String,
    type: String = "survey_drone",
    status: String = "idle",
    location: String? = nil,
    locationName: String? = nil,
    capacity: Double = 100,
    tags: [String] = [],
    stowedIn: String? = nil,
    controlledBy: String? = nil,
    attachedTo: String? = nil,
    detail: JSONValue = .object([:])
) -> Device {
    Device(
        deviceCode: code,
        deviceType: type,
        replicantCode: "R1",
        status: status,
        location: location,
        locationName: locationName,
        operationalCapacity: capacity,
        queueSize: 0,
        stowedInDeviceCode: stowedIn,
        controllerDeviceCode: controlledBy,
        attachedToDeviceCode: attachedTo,
        createdAt: Date(timeIntervalSince1970: 0),
        availableCommands: [],
        features: [],
        tags: tags,
        detail: detail,
        updatedAt: Date(timeIntervalSince1970: 1_000),
        firstSeenAt: Date(timeIntervalSince1970: 1_000)
    )
}

func makeDirective(
    id: String = "D1",
    kind: DirectiveKind = .surveyRun,
    status: DirectiveStatus = .needsAttention,
    deviceCode: String,
    controllerCode: String? = nil,
    freighterCodes: [String] = [],
    fleetTag: String? = nil,
    reason: DirectiveAttentionReason? = .commandRejected
) -> Directive {
    Directive(
        id: id,
        kind: kind,
        status: status,
        deviceCode: deviceCode,
        controllerCode: controllerCode,
        roamCentre: nil,
        fleetTag: fleetTag,
        sourceRelayCode: nil,
        targets: [],
        targetIndex: 0,
        step: "idle",
        stepStartedAt: Date(timeIntervalSince1970: 0),
        returnToOrigin: false,
        originDesignation: nil,
        attentionReason: reason,
        createdAt: Date(timeIntervalSince1970: 0),
        updatedAt: Date(timeIntervalSince1970: 0),
        freighterCodes: freighterCodes
    )
}
