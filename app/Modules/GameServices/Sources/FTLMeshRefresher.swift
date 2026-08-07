//
//  FTLMeshRefresher.swift
//  Replicould — GameServices (shared clients + command engine)
//
//  Keeps the persisted FTL mesh (`FTLLinkRecord`) in step with the relay roster
//  and each relay's live network view. Two call sites drive it: the star map
//  feature (roster changes) and `GameSync`'s relay event route (liveness flips,
//  which the roster trigger can't see). Exposed via `@Dependency(\.ftlMeshRefresher)`.
//

import Dependencies
import Foundation
import GameModels
import OSLog
import SQLiteData

private let logger = Logger(subsystem: "name.pennig.replicould", category: "FTLMesh")

public struct FTLMeshRefresher: Sendable {
    /// Bring the mesh up to date. Folds in a single relay when exactly one has
    /// been noted since the last refresh and its view can describe the whole
    /// change; otherwise reads every relay. Idempotent.
    public var refresh: @Sendable () async -> Void

    /// Record that one relay's liveness changed, ahead of the refresh the caller
    /// then invalidates. A nil code means the change could not be attributed,
    /// which forces the next refresh to read every relay.
    public var noteRelayChanged: @Sendable (String?) -> Void

    public init(
        refresh: @escaping @Sendable () async -> Void,
        noteRelayChanged: @escaping @Sendable (String?) -> Void = { _ in }
    ) {
        self.refresh = refresh
        self.noteRelayChanged = noteRelayChanged
    }
}

extension FTLMeshRefresher {
    /// The `.ftlMesh` domain's refresh policy, registered by the composition root
    /// at launch. Applies must stay off the router's dispatch path (V3.4-B2): the
    /// relay route notes the device and `invalidate(.ftlMesh)`s, and the domain's
    /// trailing debounce collapses a burst into one refresh. Best-effort per relay
    /// by design, so it always counts as a refresh.
    public static let domainRegistration = DomainRegistration(refresh: {
        @Dependency(\.ftlMeshRefresher) var ftlMeshRefresher
        await ftlMeshRefresher.refresh()
        return true
    })
}

extension FTLMeshRefresher: DependencyKey {
    public static let liveValue: FTLMeshRefresher = {
        let pending = LockIsolated(Pending())
        return FTLMeshRefresher(
            refresh: {
                let sole = pending.withValue { value -> String? in
                    defer { value = Pending() }
                    return value.soleCode
                }
                if let sole, await foldIn(relay: sole) { return }
                await sweep()
            },
            noteRelayChanged: { deviceCode in
                pending.withValue { $0.note(deviceCode) }
            }
        )
    }()

    /// The relays noted since the last refresh. Only a single attributed relay is
    /// foldable — a burst is cheaper to answer with one full read anyway.
    private struct Pending {
        private var codes: Set<String> = []
        private var unattributed = false

        var soleCode: String? {
            guard !unattributed, codes.count == 1 else { return nil }
            return codes.first
        }

        mutating func note(_ deviceCode: String?) {
            guard let deviceCode else { return unattributed = true }
            codes.insert(deviceCode)
        }
    }

    /// Read every relay's network view and replace the stored mesh wholesale.
    /// O(relays) serial network reads — the most expensive refresh an event can
    /// trigger, which is what `foldIn` exists to avoid paying routinely.
    private static func sweep() async {
        @Dependency(\.defaultDatabase) var database
        @Dependency(\.devicesClient) var devicesClient
        @Dependency(\.date) var date

        let nodes = await relayNodes()
        let views = (try? await devicesClient.relayNetworks(nodes)) ?? []
        let rows = FTLLinkRecord.rows(from: views, now: date.now)
        try? await database.write { db in
            try FTLLinkRecord.replace(rows: rows, into: db)
        }
        logger.debug("mesh swept: \(nodes.count) relay(s) → \(rows.count) closure row(s)")
    }

    /// Update the mesh from this one relay's view plus the local roster, and
    /// report whether that was enough. False means the caller must sweep: the
    /// change joined or split components, whose other pairs no single view names.
    private static func foldIn(relay deviceCode: String) async -> Bool {
        @Dependency(\.defaultDatabase) var database
        @Dependency(\.devicesClient) var devicesClient
        @Dependency(\.date) var date

        let nodes = await relayNodes()
        guard let stored = try? await database.read({ db in try FTLLinkRecord.all.fetchAll(db) })
        else { return false }

        // Absent from the roster means reclaimed, stowed, or gone. There is
        // nothing to read, and pruning its defunct edges is the whole update. A
        // read that fails leaves a nil view too, which holds that star's rows
        // rather than guessing at them.
        var view: RelayNetworkView?
        if let node = nodes.first(where: { $0.deviceCode == deviceCode }) {
            view = (try? await devicesClient.relayNetworks([node]))?.first
        }

        let update = FTLLinkRecord.incremental(
            view: view,
            relaysByStar: nodes.reduce(into: [:]) { $0[$1.star, default: 0] += 1 },
            stored: stored,
            now: date.now)
        guard !update.needsFullSweep else { return false }
        guard !update.isEmpty else { return true }

        let stars = Array(update.rewritten)
        try? await database.write { db in
            try FTLLinkRecord.where { $0.a.in(stars) }.delete().execute(db)
            try FTLLinkRecord.where { $0.b.in(stars) }.delete().execute(db)
            for row in update.rows {
                try FTLLinkRecord.insert { row }.execute(db)
            }
        }
        logger.debug(
            "mesh folded \(deviceCode, privacy: .public): \(stars.count) star(s) → \(update.rows.count) row(s)"
        )
        return true
    }

    /// The relay roster, straight from the persisted fleet, reduced to (code,
    /// system). Matched on the relay CAPABILITY rather than the device type: a
    /// `system_hub` contains an integrated relay and genuinely meshes its system.
    /// This is the same predicate `SalvageTargetPlanner.meshSystems` uses, and the
    /// two must not diverge — the map and the planner have to agree on what a mesh
    /// node is. Filtered in Swift because `features` is a JSON column.
    ///
    /// The planner ALSO requires `statusBase == "relaying"`, deliberately not
    /// copied. It answers "which systems are meshed right now" from local rows, so
    /// it must exclude a downed relay. This answers "which devices should I
    /// interrogate", and ground truth comes from the live read: a deactivated relay
    /// returns no connections and drops out naturally. A status filter here would
    /// skip a just-activated relay whose row has not been confirm-read yet.
    private static func relayNodes() async -> [RelayNode] {
        @Dependency(\.defaultDatabase) var database
        let relays = (try? await database.read { db in
            try Device.all.fetchAll(db)
        })?.filter { $0.features.contains("relay") } ?? []
        return relays.compactMap { device -> RelayNode? in
            guard let system = device.location.map(Self.systemDesignation) else { return nil }
            return RelayNode(deviceCode: device.deviceCode, star: system)
        }
    }

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
