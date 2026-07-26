//
//  LocationRecords.swift
//  UniverseModels
//
//  Persistence for the stellar-locations catalog. Detail is always fetched and
//  rendered as a whole system, and the body payload is polymorphic, so — like
//  `Device.detail` — we store one JSON blob per explored system rather than
//  normalizing planets/moons/sites into separate tables. The catalog *list* is
//  driven by the census `Star` table (all charted systems); these two tables
//  hold only the deeper, on-demand knowledge:
//
//    - `SystemDetail`      — the mapped `StarSystem` as JSON, one row per
//                            explored system. `recon` is denormalized to a
//                            column so filter/sort need not decode every blob.
//    - `LocationFootprint` — the `GET /v1/locations` holdings overlay
//                            (devices/resources/sites/events/presence) per
//                            location code. NOT a knowledge index.
//
//  The tree and the "bubbles up" roll-ups are reconstructed in memory from the
//  decoded `StarSystem` (see `LocationModels.swift`).
//

import Foundation
import GameModels
import SQLiteData

// MARK: - SystemDetail

@Table
public struct SystemDetail: Identifiable, Equatable, Sendable {
    /// Star designation — the natural primary key (matches `Star.designation`).
    @Column(primaryKey: true) public var designation: String
    /// The mapped `StarSystem`, JSON-encoded.
    public var systemJSON: String
    /// Denormalized `Recon.rawValue` for list filter/sort without decoding.
    public var recon: String
    public var systemScanned: Bool
    /// When this detail was last hydrated from the API.
    public var hydratedAt: Date

    public var id: String { designation }

    public init(
        designation: String, systemJSON: String, recon: String,
        systemScanned: Bool, hydratedAt: Date
    ) {
        self.designation = designation
        self.systemJSON = systemJSON
        self.recon = recon
        self.systemScanned = systemScanned
        self.hydratedAt = hydratedAt
    }
}

extension SystemDetail {
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    /// Wrap a mapped `StarSystem` as a persisted row, stamping `hydratedAt`.
    public init(system: StarSystem, hydratedAt: Date) throws {
        self.init(
            designation: system.designation,
            systemJSON: String(decoding: try Self.encoder.encode(system), as: UTF8.self),
            recon: system.recon.rawValue,
            systemScanned: system.systemScanned,
            hydratedAt: hydratedAt
        )
    }

    /// Decode the stored blob back into the domain `StarSystem`.
    public func system() throws -> StarSystem {
        try Self.decoder.decode(StarSystem.self, from: Data(systemJSON.utf8))
    }
}

// MARK: - LocationFootprint

@Table
public struct LocationFootprint: Identifiable, Equatable, Sendable {
    /// Location code — planet/moon/belt/etc designation.
    @Column(primaryKey: true) public var location: String
    public var devices: Int
    public var resources: Int
    public var resourceSites: Int
    public var locationEvents: Int
    public var replicants: Int
    public var fetchedAt: Date

    public var id: String { location }

    public init(
        location: String, devices: Int, resources: Int, resourceSites: Int,
        locationEvents: Int, replicants: Int, fetchedAt: Date
    ) {
        self.location = location
        self.devices = devices
        self.resources = resources
        self.resourceSites = resourceSites
        self.locationEvents = locationEvents
        self.replicants = replicants
        self.fetchedAt = fetchedAt
    }

    public init(location: String, counts: LocationCounts, fetchedAt: Date) {
        self.init(
            location: location, devices: counts.devices, resources: counts.resources,
            resourceSites: counts.resourceSites, locationEvents: counts.locationEvents,
            replicants: counts.replicants, fetchedAt: fetchedAt
        )
    }

    public var counts: LocationCounts {
        LocationCounts(
            locationEvents: locationEvents, devices: devices, resourceSites: resourceSites,
            resources: resources, replicants: replicants
        )
    }
}

// MARK: - SiteAssay

/// The original resource totals of one site, in absolute units.
///
/// Percentages (`resources_remaining_pct`) are catalog state and live on the
/// site inside the `StarSystem` blob; these totals are *historical event
/// knowledge* the catalog payload never carries. They arrive only on a
/// `salvage.discovered` (or a `scan.completed` salvage block) and must survive
/// the blob rewrites that `mergingScan` / `applying(_:)` perform on every
/// re-scan — hence a table of their own, keyed by site designation rather than
/// a field on `SalvageSite`.
///
/// `siteType` distinguishes salvage from mining so mining assays need no
/// schema change when they land.
@Table
public struct SiteAssay: Identifiable, Equatable, Sendable {
    /// Site designation, e.g. `TAANSI-6-SAL-1` — the natural primary key.
    @Column(primaryKey: true) public var id: String
    /// The body hosting the site, e.g. `TAANSI-6`. Always taken from the event
    /// PAYLOAD: the envelope's `location` names the acting device's position,
    /// not the site's.
    public var body: String
    /// Leading designation segment, denormalized so a per-system query is a
    /// plain column comparison rather than a scan-and-parse. Nothing queries it
    /// today (both readers `@FetchAll` the whole table, which is tiny), so
    /// there is deliberately no index on it — add one with the first query that
    /// wants it.
    public var system: String
    /// `"salvage"` or `"mining"`, matching the backend's `site_type`.
    public var siteType: String
    /// Resource name → original unit count.
    @Column(as: [String: Double].JSONRepresentation.self) public var totals: [String: Double]
    /// When `totals` was last raised.
    public var assayedAt: Date

    public init(
        id: String, body: String, system: String, siteType: String,
        totals: [String: Double], assayedAt: Date
    ) {
        self.id = id
        self.body = body
        self.system = system
        self.siteType = siteType
        self.totals = totals
        self.assayedAt = assayedAt
    }
}

extension SiteAssay {
    /// Merge an observation into stored totals. A site's original capacity is
    /// fixed and absolute remaining is always ≤ total, so a write may only ever
    /// raise a value — applied **per resource key**, so an observation naming a
    /// subset leaves the rest alone. Non-positive observations say nothing
    /// about capacity and are ignored.
    public static func raising(
        _ stored: [String: Double], with observed: [String: Double]
    ) -> [String: Double] {
        var out = stored
        for (resource, amount) in observed where amount > 0 {
            out[resource] = Swift.max(out[resource] ?? 0, amount)
        }
        return out
    }

    /// The original total implied by an absolute remaining amount and the
    /// percentage still present — how a `scan.completed` observation is turned
    /// into a capacity figure. Nil when the percentage is unusable (≤ 0): the
    /// remaining amount is then 0 and reveals nothing, and the division would
    /// overflow to infinity.
    public static func impliedTotal(remaining: Double, percentRemaining: Double) -> Double? {
        guard percentRemaining > 0 else { return nil }
        return remaining / (percentRemaining / 100)
    }

    /// The star system a designation belongs to — its leading segment
    /// (`TAANSI-6-5-SAL-1` → `TAANSI`).
    public static func system(of designation: String) -> String {
        String(designation.split(separator: "-").first ?? "")
    }
}

// MARK: - Schema

extension SystemDetail {
    /// Registers the `systemDetails` table. Call from the app's
    /// `bootstrapDatabase` alongside the other tables.
    public static func registerMigrations(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("Create 'systemDetails' table") { db in
            try #sql(
                """
                CREATE TABLE "systemDetails" (
                  "designation" TEXT PRIMARY KEY NOT NULL,
                  "systemJSON" TEXT NOT NULL DEFAULT '',
                  "recon" TEXT NOT NULL DEFAULT 'aware',
                  "systemScanned" INTEGER NOT NULL DEFAULT 0,
                  "hydratedAt" TEXT NOT NULL
                ) STRICT
                """
            )
            .execute(db)
        }
    }
}

extension LocationFootprint {
    /// Registers the `locationFootprints` table. Call from the app's
    /// `bootstrapDatabase` alongside the other tables.
    public static func registerMigrations(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("Create 'locationFootprints' table") { db in
            try #sql(
                """
                CREATE TABLE "locationFootprints" (
                  "location" TEXT PRIMARY KEY NOT NULL,
                  "devices" INTEGER NOT NULL DEFAULT 0,
                  "resources" INTEGER NOT NULL DEFAULT 0,
                  "resourceSites" INTEGER NOT NULL DEFAULT 0,
                  "locationEvents" INTEGER NOT NULL DEFAULT 0,
                  "replicants" INTEGER NOT NULL DEFAULT 0,
                  "fetchedAt" TEXT NOT NULL
                ) STRICT
                """
            )
            .execute(db)
        }
    }
}

extension SiteAssay {
    /// Registers the `siteAssays` table. Call from `GameDatabase.migrator()`
    /// alongside the other tables.
    public static func registerMigrations(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("Create 'siteAssays' table") { db in
            try #sql(
                """
                CREATE TABLE "siteAssays" (
                  "id" TEXT PRIMARY KEY NOT NULL,
                  "body" TEXT NOT NULL DEFAULT '',
                  "system" TEXT NOT NULL DEFAULT '',
                  "siteType" TEXT NOT NULL DEFAULT 'salvage',
                  "totals" TEXT NOT NULL DEFAULT '{}',
                  "assayedAt" TEXT NOT NULL
                ) STRICT
                """
            )
            .execute(db)
        }
    }
}
