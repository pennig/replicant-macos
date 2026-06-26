//
//  Replicant.swift
//  Replicould — shared dependency clients
//
//  The locally-persisted replicant record. Fetched from `GET /v1/accounts/me`
//  (its `replicants` array) and upserted into SQLite so the account's roster
//  reads instantly offline and survives relaunches. The schema columns mirror
//  `app_schemas_accounts_ReplicantSummarySchema`.
//

import API
import Foundation
import SQLiteData

/// A single replicant owned by the signed-in account.
///
/// The column names track the Swift property names; the snake_case backend keys
/// (`replicant_code`, `current_star`, …) are mapped at the networking boundary
/// in `init(schema:)`.
@Table
public struct Replicant: Identifiable, Equatable, Sendable {
    /// Replicant designation code — the natural primary key.
    @Column(primaryKey: true) public var replicantCode: String
    public var name: String
    public var createdAt: Date
    public var currentStar: String?
    public var currentStarName: String?
    public var currentLocation: String?
    public var currentLocationName: String?
    public var hostedDeviceCode: String?
    public var experiencePoints: Int
    public var deviceCount: Int

    public var id: String { replicantCode }

    public init(
        replicantCode: String,
        name: String,
        createdAt: Date,
        currentStar: String? = nil,
        currentStarName: String? = nil,
        currentLocation: String? = nil,
        currentLocationName: String? = nil,
        hostedDeviceCode: String? = nil,
        experiencePoints: Int = 0,
        deviceCount: Int = 0
    ) {
        self.replicantCode = replicantCode
        self.name = name
        self.createdAt = createdAt
        self.currentStar = currentStar
        self.currentStarName = currentStarName
        self.currentLocation = currentLocation
        self.currentLocationName = currentLocationName
        self.hostedDeviceCode = hostedDeviceCode
        self.experiencePoints = experiencePoints
        self.deviceCount = deviceCount
    }
}

// MARK: - Mapping

extension Replicant {
    /// Map a generated replicant summary onto the local record, parsing the
    /// ISO-8601 `created_at` timestamp.
    public init(schema: Components.Schemas.AppSchemasAccountsReplicantSummarySchema) {
        self.init(
            replicantCode: schema.replicantCode ?? "",
            name: schema.name ?? "",
            createdAt: Self.parseTimestamp(schema.createdAt ?? ""),
            currentStar: schema.currentStar,
            currentStarName: schema.currentStarName,
            currentLocation: schema.currentLocation,
            currentLocationName: schema.currentLocationName,
            hostedDeviceCode: schema.hostedDeviceCode,
            experiencePoints: schema.experiencePoints ?? 0,
            deviceCount: schema.deviceCount ?? 0
        )
    }

    /// Parses an ISO-8601 timestamp, tolerating the presence or absence of
    /// fractional seconds. Falls back to the Unix epoch if unparseable so a
    /// malformed row still sorts predictably rather than crashing.
    static func parseTimestamp(_ string: String) -> Date {
        if let date = try? Date(string, strategy: isoWithFraction) { return date }
        if let date = try? Date(string, strategy: isoPlain) { return date }
        return Date(timeIntervalSince1970: 0)
    }

    private static let isoWithFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let isoPlain = Date.ISO8601FormatStyle()
}

// MARK: - Schema

extension Replicant {
    /// Registers the `replicants` table migration. Kept beside the model so the
    /// schema and the type never drift. Composed into the app's
    /// `bootstrapDatabase` alongside other features' tables.
    public static func registerMigrations(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("Create 'replicants' table") { db in
            try #sql(
                """
                CREATE TABLE "replicants" (
                  "replicantCode" TEXT PRIMARY KEY NOT NULL,
                  "name" TEXT NOT NULL DEFAULT '',
                  "createdAt" TEXT NOT NULL,
                  "currentStar" TEXT,
                  "currentStarName" TEXT,
                  "currentLocation" TEXT,
                  "currentLocationName" TEXT,
                  "hostedDeviceCode" TEXT,
                  "experiencePoints" INTEGER NOT NULL DEFAULT 0,
                  "deviceCount" INTEGER NOT NULL DEFAULT 0
                ) STRICT
                """
            )
            .execute(db)
        }
    }
}
