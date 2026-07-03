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
import GameModels
import OSLog
import Utils

private let logger = Logger(subsystem: "name.pennig.replicould", category: "Devices")

public struct DevicesClient: Sendable {
    /// Read one device's authoritative snapshot (`GET /v1/devices/{code}`),
    /// stamped with the request-issue time as its synthesized event-time (§4.1),
    /// so out-of-order responses reconcile by initiation order.
    public var read: @Sendable (_ deviceCode: String) async throws -> Device

    /// Cold-load the whole account fleet (`GET /v1/devices`, paged). Each device
    /// is stamped with its page's request-issue time; callers reconcile them so
    /// local provenance (`firstSeenAt`) is preserved.
    public var fetchAll: @Sendable () async throws -> [Device]

    /// Read the diversion defense state at a location (`GET /v1/locations/{code}`),
    /// mapping its `object` block to a `DiversionSnapshot`. A `diverting` device
    /// exposes no activity block of its own — the impact target, ETA, and
    /// deflection progress all live on the object it's attached to. Nil when the
    /// location carries no divertible object (or isn't readable).
    public var diversion: @Sendable (_ locationDesignation: String) async throws -> DiversionSnapshot?
}

// MARK: - Live implementation

extension DevicesClient: DependencyKey {
    public static let liveValue = DevicesClient(
        read: { deviceCode in
            @Dependency(\.gameClient) var gameClient
            @Dependency(\.date) var date
            // Stamp the event-time at request *issue*, before the round-trip, so
            // reconciliation orders snapshots by when each read was initiated —
            // not by when its response happened to land. A read that starts later
            // reflects same-or-newer server state, so a slow earlier read can no
            // longer clobber a newer one on arrival (see `Reconciler`'s guard).
            let issuedAt = date.now
            let output = try await gameClient().getV1DevicesDeviceCode(path: .init(deviceCode: deviceCode))
            let schema = try output.ok.body.json
            return Device(schema: schema, fetchedAt: issuedAt)
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
                // Issue-time per page (before the round-trip), matching `read`: a
                // page's devices reconcile by when the page was requested, so a
                // slow page can't regress a newer single-device read that landed
                // in the meantime.
                let issuedAt = date.now
                let output = try await client.getV1Devices(query: .init(cursor: cursor, limit: 100))
                let body = try output.ok.body.json
                devices.append(contentsOf: (body.devices ?? []).map { Device(schema: $0, fetchedAt: issuedAt) })
                cursor = body.nextCursor
                pages += 1
            } while cursor != nil
            logger.info("cold-load: fetched \(devices.count) devices across \(pages) page(s)")
            return devices
        },
        diversion: { designation in
            @Dependency(\.gameClient) var gameClient
            let output = try await gameClient().getV1LocationsDesignation(path: .init(designation: designation))
            // The generated client hands the nested blocks back only as an opaque
            // freeform container, so round-trip through JSON to reach the `object`
            // block. A non-OK response (403 unexplored, 404) just means "no card".
            guard case let .ok(ok) = output else { return nil }
            let data = try Self.locationEncoder.encode(try ok.body.json)
            let value = try JSONDecoder().decode(JSONValue.self, from: data)
            return DiversionSnapshot(objectBlock: value["object"], fallbackDesignation: designation)
        }
    )

    private static let locationEncoder = JSONEncoder()
}

extension DevicesClient: TestDependencyKey {
    /// Unimplemented by default so a test that reaches the network without
    /// stubbing it fails loudly.
    public static let testValue = DevicesClient(
        read: unimplemented("DevicesClient.read"),
        fetchAll: unimplemented("DevicesClient.fetchAll", placeholder: []),
        diversion: unimplemented("DevicesClient.diversion", placeholder: nil)
    )
}

extension DependencyValues {
    public var devicesClient: DevicesClient {
        get { self[DevicesClient.self] }
        set { self[DevicesClient.self] = newValue }
    }
}
