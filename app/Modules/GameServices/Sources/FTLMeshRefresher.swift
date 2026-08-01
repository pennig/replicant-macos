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
    /// Rebuild and persist the mesh: read the relay-capable roster from the Device
    /// table, resolve each relay's live network view into the closure plus its
    /// metrics, and replace the stored row set wholesale. Idempotent — safe to
    /// call from the roster-change trigger and the relay event pipeline alike.
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

            // The relay roster, straight from the persisted fleet, reduced to
            // (code, system). Matched on the relay CAPABILITY rather than the
            // device type: a `system_hub` contains an integrated relay and
            // genuinely meshes its system, so a `deviceType == "ftl_relay"` match
            // left every hub off the map entirely. This is the same CAPABILITY
            // predicate `SalvageTargetPlanner.meshSystems` uses, and the two must
            // not diverge on it — the map and the planner have to agree on what a
            // mesh node is. Filtered in Swift because `features` is a JSON column;
            // the fleet is small enough that the whole-table read is cheap.
            //
            // The planner ALSO requires `statusBase == "relaying"`; deliberately
            // not copied here, and the asymmetry is the point. The planner answers
            // "which systems are meshed right now" from local rows, so it must
            // exclude a relay that is down. This answers "which devices should I
            // interrogate", and ground truth then comes from the live read itself:
            // a deactivated relay returns no connections (verified live) and drops
            // out naturally. Adding the status filter here would be a bug — a
            // just-activated relay whose local row has not been confirm-read yet
            // would be skipped, losing real edges.
            //
            // Known, accepted: a deactivated relay still contributes its range to
            // the per-star merge in `rows(from:)`, so a system holding an active
            // short-range relay plus a downed longer-range one can classify a
            // borderline pair as direct. That fails toward drawing an edge, which
            // is the design's stated direction.
            let relays = (try? await database.read { db in
                try Device.all.fetchAll(db)
            })?.filter { $0.features.contains("relay") } ?? []
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
    /// no-op avoids reaching the unimplemented `DevicesClient.relayNetworks`.
    public static let testValue = FTLMeshRefresher(refresh: {})
}

extension DependencyValues {
    public var ftlMeshRefresher: FTLMeshRefresher {
        get { self[FTLMeshRefresher.self] }
        set { self[FTLMeshRefresher.self] = newValue }
    }
}
