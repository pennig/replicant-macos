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
    public var createdAt: Date
    public var firstVisitedAt: Date?
    public var fullyScannedAt: Date?

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
            entryPoint: entryPoint
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
        fullyScannedAt: Date? = nil
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
            createdAt: createdAt
        )
    }
}

// MARK: - Schema

extension Star {
    /// Registers the `stars` table migration. Kept beside the model so schema
    /// and type never drift. Called from the app's `bootstrapDatabase`.
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

    /// Temporary shim so `GameDatabase` keeps compiling mid-conversion.
    /// Deleted in the manifest task.
    public static func registerMigrations(_ migrator: inout DatabaseMigrator) {
        createStars.register(in: &migrator)
    }
}
