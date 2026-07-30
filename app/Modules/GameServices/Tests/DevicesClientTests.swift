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

import API
import Dependencies
import Foundation
import GameModels
import GameSession
import HTTPTypes
import OpenAPIRuntime
import Testing
import Utils
@testable import GameServices

@Suite struct DevicesClientTests {
    /// Confirms the dependency plumbing: overriding `devicesClient.fetchByTag`
    /// and calling it through `@Dependency` round-trips exactly what the
    /// closure returns. This does NOT exercise `DevicesClient.liveValue` —
    /// see `fetchByTagLiveValueWalksBothPagesAndPreservesStowage` below for the
    /// test that actually drives the cursor loop and the schema mapping.
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

    /// The real coverage: drives `DevicesClient.liveValue.fetchByTag` against a
    /// stub transport serving the walk across two pages, so the cursor loop,
    /// `Self.pageSize`, the per-page issue-time stamp, and the
    /// `Device(schema:fetchedAt:)` mapping are all exercised — mirrors
    /// `StarsClientTests`' pattern of driving the live value through a stub
    /// `ClientTransport` rather than stubbing the dependency closure itself.
    @Test func fetchByTagLiveValueWalksBothPagesAndPreservesStowage() async throws {
        let devices = try await withDependencies {
            $0.gameClient = GameClient(make: {
                Client(serverURL: URL(string: "https://stub.invalid")!, transport: PagedTagTransport())
            })
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
        } operation: {
            try await DevicesClient.liveValue.fetchByTag("auto:salvage")
        }

        // Both pages made it back, in order. A dropped final page (cursor
        // handling that stops too early) would fail the first assertion; a
        // cursor bug that never sees `next_cursor: null` would hang instead of
        // this test ever reaching an assertion at all.
        #expect(devices.map(\.deviceCode) == ["VESSEL", "DRONE"])
        // The property the whole method exists for: a stowed device's location
        // comes back null, same as the travelling one, but its
        // stowedInDeviceCode is intact.
        #expect(devices[0].location == nil)
        #expect(devices[1].location == nil)
        #expect(devices[1].stowedInDeviceCode == "VESSEL")
    }

    /// Serves the tag walk's two pages: page 1 (no `cursor` query item) returns
    /// a travelling vessel plus a non-null `next_cursor`; page 2 (`cursor`
    /// present) returns a stowed drone plus a null `next_cursor`, ending the
    /// walk. Discriminating on the query string (rather than call count) means
    /// a test failure that re-requests page 1 is visible as a repeated device
    /// rather than a crash.
    private struct PagedTagTransport: ClientTransport {
        func send(
            _ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String
        ) async throws -> (HTTPResponse, HTTPBody?) {
            let isSecondPage = (request.path ?? "").contains("cursor=")
            let json = isSecondPage
                ? #"""
                  {"devices":[
                    {"device_code":"DRONE","device_type":"transport_drone","status":"stowed",
                     "location":null,"stowed_in_device_code":"VESSEL"}
                  ],"next_cursor":null}
                  """#
                : #"""
                  {"devices":[
                    {"device_code":"VESSEL","device_type":"surge_plate","status":"travelling",
                     "location":null}
                  ],"next_cursor":2}
                  """#
            return (
                HTTPResponse(status: .init(code: 200), headerFields: [.contentType: "application/json"]),
                HTTPBody(json)
            )
        }
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
