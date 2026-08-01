//
//  FTLMeshRefresher.swift
//  Replicould — GameServices (shared clients + command engine)
//
//  Rebuilds and persists the FTL mesh (`FTLLinkRecord`) from the current relay
//  roster and each relay's live network view. It lives here, beside the other
//  shared infrastructure, because two unrelated call sites drive it: the star map
//  feature (when the relay device roster changes) and `GameSync`'s relay event
//  route (when a relay's liveness flips via `relay_activated`/`relay_deactivated`,
//  which the roster trigger can't see because the device stays put — only its
//  status changes). Centralizing the read-roster → resolve-links → replace-table
//  sequence keeps those two triggers from diverging, and lets the mesh stay fresh
//  independent of whether the map is on screen.
//
//  Exposed via `@Dependency(\.ftlMeshRefresher)`.
//

import Dependencies
import Foundation
import GameModels
import OSLog
import SQLiteData

private let logger = Logger(subsystem: "name.pennig.replicould", category: "FTLMesh")

public struct FTLMeshRefresher: Sendable {
    /// Rebuild and persist the mesh: read the `ftl_relay` roster from the Device
    /// table, resolve each relay's live network view into undirected edges, and
    /// replace the stored edge set wholesale. Idempotent — safe to call from the
    /// roster-change trigger and the relay event pipeline alike.
    public var refresh: @Sendable () async -> Void

    public init(refresh: @escaping @Sendable () async -> Void) {
        self.refresh = refresh
    }
}

extension FTLMeshRefresher {
    /// The `.ftlMesh` domain's refresh policy, registered by the composition
    /// root at launch. O(relays) serial network reads — the single most
    /// expensive refresh an event can trigger, and exactly why applies must
    /// stay off the router's dispatch path (V3.4-B2): the relay route only
    /// `invalidate(.ftlMesh)`s, and the domain's trailing debounce collapses a
    /// burst into one rebuild. The rebuild is best-effort per relay by design
    /// (an unreachable relay is skipped, not an error), so it always counts as
    /// a refresh.
    public static let domainRegistration = DomainRegistration(refresh: {
        @Dependency(\.ftlMeshRefresher) var ftlMeshRefresher
        await ftlMeshRefresher.refresh()
        return true
    })
}

extension FTLMeshRefresher: DependencyKey {
    public static let liveValue = FTLMeshRefresher(
        refresh: {
            @Dependency(\.defaultDatabase) var database
            @Dependency(\.devicesClient) var devicesClient
            @Dependency(\.date) var date

            // The relay roster, straight from the persisted fleet — every ftl_relay
            // device reduced to its (code, system). A deactivated relay stays in the
            // roster; its network view simply returns no connections (verified live),
            // so it drops out of the resolved edge set naturally — no status filter
            // needed here.
            let relays = (try? await database.read { db in
                try Device.where { $0.deviceType.eq("ftl_relay") }.fetchAll(db)
            }) ?? []
            let nodes = relays.compactMap { device -> RelayNode? in
                guard let system = device.location.map(Self.systemDesignation) else { return nil }
                return RelayNode(deviceCode: device.deviceCode, star: system)
            }

            // Read each relay's backend network view (a failed/refused read is
            // skipped inside `relayNetworks`), then replace the whole persisted
            // mesh with the closure plus its metrics. Classification into drawable
            // links happens on the read side — see `DirectFTLLinks`.
            let views = (try? await devicesClient.relayNetworks(nodes)) ?? []
            let now = date.now
            let rows = FTLLinkRecord.rows(from: views, now: now)
            try? await database.write { db in
                try FTLLinkRecord.replace(rows: rows, into: db)
            }
            logger.debug("mesh rebuilt: \(nodes.count) relay(s) → \(rows.count) closure row(s)")
        }
    )

    /// The star system a location code belongs to — the designation up to the first
    /// hyphen (`AINALRAM-1-L4` → `AINALRAM`).
    private static func systemDesignation(_ location: String) -> String {
        String(location.split(separator: "-").first ?? "")
    }
}

extension FTLMeshRefresher: TestDependencyKey {
    /// Inert by default: a test that wants the mesh rebuilt overrides this. The
    /// no-op avoids reaching the unimplemented `DevicesClient.relayLinks`.
    public static let testValue = FTLMeshRefresher(refresh: {})
}

extension DependencyValues {
    public var ftlMeshRefresher: FTLMeshRefresher {
        get { self[FTLMeshRefresher.self] }
        set { self[FTLMeshRefresher.self] = newValue }
    }
}
