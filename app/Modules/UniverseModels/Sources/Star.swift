//
//  Star.swift
//  UniverseModels
//
//  The locally-persisted star record — the root of the universe tree. Surveyed
//  from `GET /v1/replicants/{code}/stars` (paged) and upserted into SQLite so the
//  galaxy and the locations catalog read instantly offline and survive relaunches.
//  The schema columns mirror `app_schemas_stars_StarItemSchema`; on top of those
//  we track three local lifecycle timestamps that the survey never overwrites:
//    - `createdAt`      — first time we stored this star locally
//    - `firstVisitedAt` — first time the replicant visited it (set later)
//    - `fullyScannedAt` — when its system became fully scanned (set later)
//

import Foundation
import GameModels
import SQLiteData

@Table
public struct Star: Identifiable, Equatable, Sendable {
    /// Star designation code — the natural primary key.
    @Column(primaryKey: true) public var designation: String
    public var spectralType: String
    public var color: String
    public var positionX: Double
    public var positionY: Double
    public var positionZ: Double
    public var estimatedPlanets: Int
    public var explored: Bool
    public var hasLife: Bool?
    public var entryPoint: String?
    @Column(as: Date.FastISO8601Representation.self) public var createdAt: Date
    @Column(as: Date.FastISO8601Representation?.self) public var firstVisitedAt: Date?
    @Column(as: Date.FastISO8601Representation?.self) public var fullyScannedAt: Date?
    public var region: String?
    public var hasHub: Bool

    public var id: String { designation }
    public var position: Position { Position(x: positionX, y: positionY, z: positionZ) }

    /// View this persisted row as the API-shaped `StarItem`.
    public var item: StarItem {
        StarItem(
            designation: designation,
            spectralType: spectralType,
            color: color,
            position: position,
            estimatedPlanets: estimatedPlanets,
            explored: explored,
            hasLife: hasLife,
            entryPoint: entryPoint,
            region: region,
            hasHub: hasHub
        )
    }

    public init(
        designation: String,
        spectralType: String,
        color: String,
        positionX: Double,
        positionY: Double,
        positionZ: Double,
        estimatedPlanets: Int,
        explored: Bool,
        hasLife: Bool?,
        entryPoint: String?,
        createdAt: Date,
        firstVisitedAt: Date? = nil,
        fullyScannedAt: Date? = nil,
        region: String? = nil,
        hasHub: Bool = false
    ) {
        self.designation = designation
        self.spectralType = spectralType
        self.color = color
        self.positionX = positionX
        self.positionY = positionY
        self.positionZ = positionZ
        self.estimatedPlanets = estimatedPlanets
        self.explored = explored
        self.hasLife = hasLife
        self.entryPoint = entryPoint
        self.createdAt = createdAt
        self.firstVisitedAt = firstVisitedAt
        self.fullyScannedAt = fullyScannedAt
        self.region = region
        self.hasHub = hasHub
    }
}

extension Star {
    /// Build a record from a freshly-fetched API item, stamping `createdAt`.
    /// The lifecycle timestamps start nil and are preserved on re-survey.
    public init(item: StarItem, createdAt: Date) {
        self.init(
            designation: item.designation,
            spectralType: item.spectralType,
            color: item.color,
            positionX: item.position.x,
            positionY: item.position.y,
            positionZ: item.position.z,
            estimatedPlanets: item.estimatedPlanets,
            explored: item.explored,
            hasLife: item.hasLife,
            entryPoint: item.entryPoint,
            createdAt: createdAt,
            region: item.region,
            hasHub: item.hasHub
        )
    }
}

// MARK: - Persistence

extension Star {
    /// Upserts `records` from the objective catalogue, refreshing every
    /// catalogue-carried column (`region`/`hasHub` included) on conflict.
    /// Per-replicant knowledge and lifecycle timestamps are left untouched.
    public static func upsertCatalogue(_ records: [Star], in db: Database) throws {
        try Star.insert {
            records
        } onConflict: {
            $0.designation
        } doUpdate: { row, excluded in
            row.spectralType = excluded.spectralType
            row.color = excluded.color
            row.positionX = excluded.positionX
            row.positionY = excluded.positionY
            row.positionZ = excluded.positionZ
            row.estimatedPlanets = excluded.estimatedPlanets
            row.entryPoint = excluded.entryPoint
            row.region = excluded.region
            row.hasHub = excluded.hasHub
        }
        .execute(db)
    }
}

// MARK: - Schema

extension Star {
    /// Creates the `stars` table. Kept beside the model so schema and type
    /// never drift.
    public static let createStars = SchemaMigration("Create 'stars' table") { db in
        try #sql(
            """
            CREATE TABLE "stars" (
              "designation" TEXT PRIMARY KEY NOT NULL,
              "spectralType" TEXT NOT NULL DEFAULT '',
              "color" TEXT NOT NULL DEFAULT '',
              "positionX" REAL NOT NULL DEFAULT 0,
              "positionY" REAL NOT NULL DEFAULT 0,
              "positionZ" REAL NOT NULL DEFAULT 0,
              "estimatedPlanets" INTEGER NOT NULL DEFAULT 0,
              "explored" INTEGER NOT NULL DEFAULT 0,
              "hasLife" INTEGER,
              "entryPoint" TEXT,
              "createdAt" TEXT NOT NULL,
              "firstVisitedAt" TEXT,
              "fullyScannedAt" TEXT
            ) STRICT
            """
        )
        .execute(db)
    }

    /// Backfills `fullyScannedAt` for systems already known to be fully
    /// surveyed. Nothing ever wrote the column, so every system surveyed before
    /// it started being stamped was left null — 31 of them on the live database,
    /// which is why the star map showed none as fully scanned.
    ///
    /// Raw SQL against the stored blob rather than decoding through
    /// `StarSystem`: a migration runs forever against databases whose Swift
    /// model may have moved on, so it must not depend on today's model shape.
    /// The predicate mirrors `StarSystem.isFullyScanned` exactly — every planet
    /// scanned against a positive total, and every moon scanned whenever a
    /// positive moon total is reported. A NULL count makes its comparison NULL,
    /// which is falsy, matching that property's "unknown is never scanned" bias.
    ///
    /// The timestamp is the detail row's own `hydratedAt` — the best available
    /// evidence of when we learned the system was complete — and both columns
    /// are TEXT, so copying it across preserves the exact serialization.
    public static let backfillFullyScannedAt = SchemaMigration(
        "Backfill 'fullyScannedAt' from systemDetails"
    ) { db in
        try #sql(
            """
            UPDATE "stars" SET "fullyScannedAt" = (
              SELECT "d"."hydratedAt" FROM "systemDetails" AS "d"
              WHERE "d"."designation" = "stars"."designation"
            )
            WHERE "fullyScannedAt" IS NULL
              AND "designation" IN (
                SELECT "designation" FROM "systemDetails"
                WHERE json_extract("systemJSON", '$.planetsTotal') > 0
                  AND json_extract("systemJSON", '$.planetsScanned')
                      >= json_extract("systemJSON", '$.planetsTotal')
                  AND (
                    json_extract("systemJSON", '$.moonsTotal') IS NULL
                    OR json_extract("systemJSON", '$.moonsTotal') = 0
                    OR json_extract("systemJSON", '$.moonsScanned')
                       >= json_extract("systemJSON", '$.moonsTotal')
                  )
              )
            """
        )
        .execute(db)
    }

    /// Adds the census `region` column — nullable, mirroring the payload.
    public static let addStarRegion = SchemaMigration("Add 'region' to 'stars'") { db in
        try #sql(
            """
            ALTER TABLE "stars" ADD COLUMN "region" TEXT
            """
        )
        .execute(db)
    }

    /// Adds the census `hasHub` flag — non-nullable, mirroring the payload.
    public static let addStarHasHub = SchemaMigration("Add 'hasHub' to 'stars'") { db in
        try #sql(
            """
            ALTER TABLE "stars" ADD COLUMN "hasHub" INTEGER NOT NULL DEFAULT 0
            """
        )
        .execute(db)
    }
}
