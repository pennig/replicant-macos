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
