//
//  DevicesClientTests.swift
//  Replicould — GameServices
//
//  `fetchByTag` is the primitive Salvage Run rests on: a fleet-wide list
//  filtered by tag, so it reports stowed and travelling devices that
//  `?location=` structurally cannot (stowing clears `location`, dropping the
//  device out of the location index entirely — see the
//  device-tags-and-control-range memory note).
//

import Dependencies
import Foundation
import GameModels
import Testing
import Utils
@testable import GameServices

@Suite struct DevicesClientTests {
    /// The whole point of the tag scope: a stowed device reports no location at
    /// all, and a travelling one reports null — both must still come back.
    @Test func fetchByTagReturnsStowedAndTravellingDevices() async throws {
        let devices = try await withDependencies {
            $0.devicesClient.fetchByTag = { tag in
                #expect(tag == "auto:salvage")
                return [
                    Self.device(deviceCode: "VESSEL", status: "travelling", location: "TOSLIT-3"),
                    Self.device(deviceCode: "DRONE", location: nil, stowedInDeviceCode: "VESSEL"),
                    Self.device(deviceCode: "PLATE", status: "travelling", location: nil),
                ]
            }
        } operation: {
            @Dependency(\.devicesClient) var client
            return try await client.fetchByTag("auto:salvage")
        }

        #expect(devices.map(\.deviceCode) == ["VESSEL", "DRONE", "PLATE"])
        #expect(devices[1].stowedInDeviceCode == "VESSEL")
    }

    /// Builds a minimal `Device` row for fixture purposes — there is no shared
    /// `Device.fixture` helper in this module yet, so construct directly.
    private static func device(
        deviceCode: String,
        status: String = "idle",
        location: String?,
        stowedInDeviceCode: String? = nil
    ) -> Device {
        Device(
            deviceCode: deviceCode,
            deviceType: "transport_drone",
            replicantCode: "REPLICANT-1",
            status: status,
            location: location,
            locationName: nil,
            operationalCapacity: 1,
            queueSize: 0,
            stowedInDeviceCode: stowedInDeviceCode,
            controllerDeviceCode: nil,
            attachedToDeviceCode: nil,
            createdAt: Date(timeIntervalSince1970: 0),
            availableCommands: [],
            features: [],
            tags: [],
            detail: .object([:]),
            updatedAt: Date(timeIntervalSince1970: 0),
            firstSeenAt: Date(timeIntervalSince1970: 0)
        )
    }
}
