//
//  DevicesClient.swift
//  Replicould — shared dependency clients
//
//  Talks to the device endpoints through the shared generated client (so calls
//  inherit bearer auth, rate limiting, and logging). Lives here, beside the
//  `Device` table, because it's cross-feature infrastructure the ingestion
//  service (`GameSync`) and the future Devices feature both use, rather than
//  belonging to any one feature. Exposed via `@Dependency(\.devicesClient)`.
//
//  Phase 2 needs only the single-device read — the authoritative snapshot a
//  relay event invalidates into. The account-wide paged list walk arrives with
//  the Devices feature (Phase 5).
//

import API
import ComposableArchitecture
import Foundation

public struct DevicesClient: Sendable {
    /// Read one device's authoritative snapshot (`GET /v1/devices/{code}`),
    /// stamped with the fetch wall-clock as its synthesized event-time (§4.1).
    public var read: @Sendable (_ deviceCode: String) async throws -> Device
}

// MARK: - Live implementation

extension DevicesClient: DependencyKey {
    public static let liveValue = DevicesClient(
        read: { deviceCode in
            @Dependency(\.gameClient) var gameClient
            @Dependency(\.date) var date
            let output = try await gameClient().getV1DevicesDeviceCode(path: .init(deviceCode: deviceCode))
            let schema = try output.ok.body.json
            return Device(schema: schema, fetchedAt: date.now)
        }
    )
}

extension DevicesClient: TestDependencyKey {
    /// Unimplemented by default so a test that reaches a device read without
    /// stubbing it fails loudly.
    public static let testValue = DevicesClient(
        read: unimplemented("DevicesClient.read")
    )
}

extension DependencyValues {
    public var devicesClient: DevicesClient {
        get { self[DevicesClient.self] }
        set { self[DevicesClient.self] = newValue }
    }
}
