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
import OSLog

private let logger = Logger(subsystem: "name.pennig.replicould", category: "Devices")

public struct DevicesClient: Sendable {
    /// Read one device's authoritative snapshot (`GET /v1/devices/{code}`),
    /// stamped with the fetch wall-clock as its synthesized event-time (§4.1).
    public var read: @Sendable (_ deviceCode: String) async throws -> Device

    /// Cold-load the whole account fleet (`GET /v1/devices`, paged). Each device
    /// is stamped with the fetch time; callers reconcile them so local provenance
    /// (`firstSeenAt`) is preserved.
    public var fetchAll: @Sendable () async throws -> [Device]
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
        },
        fetchAll: {
            @Dependency(\.gameClient) var gameClient
            @Dependency(\.date) var date
            // Resolve the client once and reuse it across the paged walk (the
            // governor is process-shared, but one client per walk is the clean
            // shape — mirrors `StarsClient.survey`).
            let client = gameClient()
            var devices: [Device] = []
            var cursor: Int?
            var pages = 0
            repeat {
                let output = try await client.getV1Devices(query: .init(cursor: cursor, limit: 100))
                let body = try output.ok.body.json
                let now = date.now
                devices.append(contentsOf: (body.devices ?? []).map { Device(schema: $0, fetchedAt: now) })
                cursor = body.nextCursor
                pages += 1
            } while cursor != nil
            logger.info("cold-load: fetched \(devices.count) devices across \(pages) page(s)")
            return devices
        }
    )
}

extension DevicesClient: TestDependencyKey {
    /// Unimplemented by default so a test that reaches the network without
    /// stubbing it fails loudly.
    public static let testValue = DevicesClient(
        read: unimplemented("DevicesClient.read"),
        fetchAll: unimplemented("DevicesClient.fetchAll", placeholder: [])
    )
}

extension DependencyValues {
    public var devicesClient: DevicesClient {
        get { self[DevicesClient.self] }
        set { self[DevicesClient.self] = newValue }
    }
}
