//
//  LocationsClient.swift
//  Replicould — GameServices (shared clients + command engine)
//
//  Reads the stellar-locations catalog through the generated `ReplicantSpace`
//  client (inheriting bearer auth, rate limiting, and logging). Three calls:
//    - `footprint()`   → GET /v1/locations       (holdings overlay; see note)
//    - `system(_:)`    → GET /v1/locations/{star} (star-level roster + belts)
//    - `body(_:)`      → GET /v1/locations/{code} (scanned body detail to merge)
//
//  Location detail is gated on *presence*, not exploration: the endpoint returns
//  detail only while one of your replicants is in the system, and otherwise
//  responds 403 ("No replicant in system"), surfaced here as
//  `LocationsError.noReplicantInSystem` (not a failure — it just means "travel
//  there first"). All decoding goes through the JSON round-trip in
//  `LocationDTOs.swift`, since the generated client exposes the nested blocks
//  only as opaque freeform containers.
//

import API
import ComposableArchitecture
import Foundation
import GameModels
import SQLiteData
import UniverseModels
import Utils

public enum LocationsError: Error, Equatable, Sendable {
    /// No replicant is currently in the system, so live detail is unavailable
    /// (HTTP 403 "No replicant in system"). Presence-gated, *not* exploration —
    /// a previously-scanned system the replicant has left returns this too.
    case noReplicantInSystem
    case notFound
    case malformed
    case unexpected(Int)
}

public struct LocationsClient: Sendable {
    /// Per-location holdings (devices/resources/sites/events/presence), keyed by
    /// location code. An overlay for badges/inventory hints — NOT a knowledge
    /// index; a scanned system with no holdings is simply absent.
    public var footprint: @Sendable () async throws -> [String: LocationCounts]

    /// The star-level system: physical star, planet roster (types estimated
    /// until scanned), asteroid belts, counts, and system events. Throws
    /// `.noReplicantInSystem` if no replicant is currently in the system.
    public var system: @Sendable (_ designation: String) async throws -> StarSystem

    /// Scanned detail for a single body (planet/moon/belt/lagrange/…), merged
    /// into the tree in place of its roster stub.
    public var body: @Sendable (_ designation: String) async throws -> BodyDetail

    /// Full system scan of the replicant's current system — the only source of
    /// shops, megastructures/objects, and the outer system. Returns a
    /// `StarSystem` to merge (see `StarSystem.mergingScan`).
    public var scan: @Sendable (_ replicantCode: String) async throws -> StarSystem

    public init(
        footprint: @escaping @Sendable () async throws -> [String: LocationCounts],
        system: @escaping @Sendable (String) async throws -> StarSystem,
        body: @escaping @Sendable (String) async throws -> BodyDetail,
        scan: @escaping @Sendable (String) async throws -> StarSystem
    ) {
        self.footprint = footprint
        self.system = system
        self.body = body
        self.scan = scan
    }
}

extension BodyDetail {
    /// The stored resources at this body (planets, moons, belts carry inventory;
    /// a special site carries none).
    public var inventory: [InventoryItem] {
        switch self {
        case .planet(let p): return p.inventory
        case .moon(let m):   return m.inventory
        case .belt(let b):   return b.inventory
        case .special:       return []
        }
    }
}

extension LocationsClient {
    /// Fresh inventory at a location, fetched through `body(_:)`. Used by the
    /// print confirmation to check a blueprint's cost against what's on hand.
    public func inventory(at designation: String) async throws -> [InventoryItem] {
        try await body(designation).inventory
    }

    /// Resolve a print's resource requirements by refreshing the location's live
    /// inventory and filling in what's on hand for each required resource. A
    /// location we can't read (unexplored, offline, or no location at all) leaves
    /// the stock unknown rather than failing the preview.
    public func printRequirements(
        deviceType: String,
        location: String?,
        locationName: String?,
        required: [PrintResourceLine]
    ) async -> PrintRequirements {
        var available: [String: Double]?
        if let location, let items = try? await inventory(at: location) {
            available = Dictionary(
                items.map { ($0.resourceType.lowercased(), $0.quantity) },
                uniquingKeysWith: +
            )
        }
        return PrintRequirements.resolve(
            deviceType: deviceType,
            locationName: locationName,
            required: required,
            available: available
        )
    }
}

extension LocationsClient {
    /// Scan the replicant's current system and persist the result, overlaying it
    /// onto any already-hydrated `SystemDetail` (preserving per-body scan detail).
    /// Shared by the explicit Scan action and the passive GameSync capture.
    public func scanAndPersist(replicantCode: String) async throws {
        @Dependency(\.defaultDatabase) var database
        @Dependency(\.date.now) var now
        let scanned = try await scan(replicantCode)
        try await database.write { db in
            let existing = try SystemDetail
                .where { $0.designation.eq(scanned.designation) }.fetchOne(db)
            let merged = (try existing?.system())?.mergingScan(scanned) ?? scanned
            let row = try SystemDetail(system: merged, hydratedAt: now)
            try SystemDetail.upsert { row }.execute(db)
        }
    }

    /// Fetch a single body's scanned detail and merge it into the persisted
    /// `SystemDetail` blob for its system, so callers reading `allSalvageSites`
    /// from the local catalog (e.g. the gather_salvage location picker) see that
    /// body's sites without opening the Locations feature. Best-effort: a system
    /// with no replicant present (403), an uncharted system, or an unreadable
    /// body simply leaves the catalog untouched rather than throwing.
    public func hydrateBody(systemDesignation: String, bodyDesignation: String) async throws {
        @Dependency(\.defaultDatabase) var database
        @Dependency(\.date.now) var now
        let cached = try await database.read { db in
            try SystemDetail.where { $0.designation.eq(systemDesignation) }.fetchOne(db)
        }
        // Attach the body onto whatever base roster we have — the cached blob, or
        // a fresh star-level fetch when the system isn't in the catalog yet.
        var base = try cached?.system()
        if base == nil { base = try? await system(systemDesignation) }
        guard var assembled = base, let detail = try? await body(bodyDesignation) else { return }
        assembled = assembled.applying(detail)
        let row = try SystemDetail(system: assembled, hydratedAt: now)
        try await database.write { db in
            try SystemDetail.upsert { row }.execute(db)
        }
    }

    /// Fold a `scan_complete` relay event's `result` body into the local catalog,
    /// sparing a later `body(_:)` hydration call (the event already carries the
    /// scanned body's physical block, salvage, sites, and inventory). Merges onto
    /// the cached `SystemDetail` blob when present, else seeds a minimal system so
    /// the body — and its salvage — isn't lost before the system is hydrated.
    /// Best-effort and idempotent: an unrecognized or system-less payload is a
    /// no-op. Returns whether a body was persisted.
    @discardableResult
    public func ingestScanResult(payload: [String: JSONValue]) async throws -> Bool {
        guard
            let result = payload["result"],
            let detail = ((try? LocationDecoding.scanResultBody(from: result)) ?? nil)
        else { return false }
        let system = String(detail.designation.split(separator: "-").first ?? "")
        guard !system.isEmpty else { return false }

        @Dependency(\.defaultDatabase) var database
        @Dependency(\.date.now) var now
        try await database.write { db in
            let cached = try SystemDetail.where { $0.designation.eq(system) }.fetchOne(db)
            let base = (try? cached?.system()) ?? StarSystem(designation: system, recon: .visited)
            let merged = base.seedingParent(of: detail).applying(detail)
            let row = try SystemDetail(system: merged, hydratedAt: now)
            try SystemDetail.upsert { row }.execute(db)
        }
        return true
    }

    /// Mark a body's salvage as fully spent in the catalog (a `salvage_depleted`
    /// event). No-op if the system isn't cached or nothing matches. Returns
    /// whether a row changed.
    @discardableResult
    public func markSalvageDepleted(location: String) async throws -> Bool {
        try await mutateSalvage(atBody: location) { $0.depleted = true; $0.resourcesAvailable = [] }
    }

    /// Drop one depleted resource from a body's salvage (a
    /// `salvage_resource_depleted` event). Full depletion arrives separately as
    /// `salvage_depleted`, so this only prunes the resource list.
    @discardableResult
    public func markSalvageResourceDepleted(location: String, resource: String) async throws -> Bool {
        try await mutateSalvage(atBody: location) { $0.resourcesAvailable.removeAll { $0 == resource } }
    }

    /// Shared body: load the cached system, apply the salvage transform, and
    /// persist only if it actually changed something.
    private func mutateSalvage(
        atBody location: String, _ transform: @Sendable (inout SalvageSite) -> Void
    ) async throws -> Bool {
        let system = String(location.split(separator: "-").first ?? "")
        guard !system.isEmpty else { return false }
        @Dependency(\.defaultDatabase) var database
        @Dependency(\.date.now) var now
        return try await database.write { db in
            guard
                let cached = try SystemDetail.where({ $0.designation.eq(system) }).fetchOne(db),
                let starSystem = try? cached.system()
            else { return false }
            let updated = starSystem.updatingSalvage(at: location, transform)
            guard updated != starSystem else { return false }
            let row = try SystemDetail(system: updated, hydratedAt: now)
            try SystemDetail.upsert { row }.execute(db)
            return true
        }
    }
}

extension LocationsClient: DependencyKey {
    public static let liveValue = LocationsClient(
        footprint: {
            @Dependency(\.gameClient) var gameClient
            let client = gameClient.make()
            let output = try await client.getV1Locations()
            switch output {
            case .ok(let ok):
                return try LocationDecoding.footprint(from: try ok.body.json)
            case .default(let statusCode, _):
                throw LocationsError.unexpected(statusCode)
            }
        },
        system: { designation in
            let raw = try await fetchLocation(designation)
            guard let system = raw.starSystem() else { throw LocationsError.malformed }
            return system
        },
        body: { designation in
            let raw = try await fetchLocation(designation)
            guard let detail = raw.bodyDetail() else { throw LocationsError.malformed }
            return detail
        },
        scan: { replicantCode in
            @Dependency(\.gameClient) var gameClient
            let client = gameClient.make()
            let output = try await client.postV1ReplicantsReplicantCodeScan(
                path: .init(replicantCode: replicantCode)
            )
            switch output {
            case .ok(let ok):
                guard let system = try LocationDecoding.scannedSystem(from: ok.body.json)
                else { throw LocationsError.malformed }
                return system
            case .notFound:
                throw LocationsError.notFound
            case .badRequest:
                throw LocationsError.unexpected(400)
            case .default(let statusCode, _):
                throw LocationsError.unexpected(statusCode)
            }
        }
    )

    /// Shared GET /v1/locations/{designation} with the explored-gate mapping.
    private static func fetchLocation(_ designation: String) async throws -> LocationPayload {
        @Dependency(\.gameClient) var gameClient
        let client = gameClient.make()
        let output = try await client.getV1LocationsDesignation(path: .init(designation: designation))
        switch output {
        case .ok(let ok):
            return try LocationDecoding.location(from: try ok.body.json)
        case .forbidden:
            throw LocationsError.noReplicantInSystem
        case .notFound:
            throw LocationsError.notFound
        case .conflict:
            throw LocationsError.unexpected(409)
        case .badRequest:
            throw LocationsError.unexpected(400)
        case .unprocessableContent:
            throw LocationsError.unexpected(422)
        case .default(let statusCode, _):
            throw LocationsError.unexpected(statusCode)
        }
    }
}

extension LocationsClient: TestDependencyKey {
    public static let testValue = LocationsClient(
        footprint: { [:] },
        system: { _ in throw LocationsError.noReplicantInSystem },
        body: { _ in throw LocationsError.notFound },
        scan: { _ in throw LocationsError.notFound }
    )

    public static let previewValue = LocationsClient(
        footprint: {
            ["SOL-3": LocationCounts(locationEvents: 1, devices: 1, replicants: 1)]
        },
        system: { designation in
            StarSystem(
                designation: designation, name: designation,
                star: SystemStar(designation: designation, stellarClass: "G2", color: "yellow-white"),
                recon: .visited, systemScanned: true, entryPoint: "\(designation)-5-L4",
                planetsScanned: 1, planetsTotal: 2,
                planets: [
                    Planet(designation: "\(designation)-1", type: "Barren", orbitalDistanceAu: 0.39, recon: .visited),
                    Planet(
                        designation: "\(designation)-3", type: "Terrestrial", orbitalDistanceAu: 1,
                        inHabitableZone: true, recon: .scanned, moonCount: 1
                    ),
                ]
            )
        },
        body: { designation in
            .planet(Planet(designation: designation, type: "Terrestrial", recon: .scanned))
        },
        scan: { _ in
            StarSystem(
                designation: "SOL", star: SystemStar(designation: "SOL", stellarClass: "G2"),
                recon: .scanned, systemScanned: true,
                structures: [SpecialSite(designation: "EXODUS-ARK-001", kind: .megastructure,
                                         objectType: "megastructure", progressPercentage: 100)],
                shops: [Shop(controllerCode: "043CA0A9", shopName: "Riker's Lunar Supplies", location: "SOL-3-1")]
            )
        }
    )
}

extension DependencyValues {
    public var locationsClient: LocationsClient {
        get { self[LocationsClient.self] }
        set { self[LocationsClient.self] = newValue }
    }
}
