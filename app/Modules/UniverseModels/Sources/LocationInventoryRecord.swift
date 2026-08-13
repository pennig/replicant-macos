//
//  LocationInventoryRecord.swift
//  Replicould — UniverseModels
//
//  Per-resource-type stock at one location, beside the totals-only
//  `LocationFootprint`. Written wholesale per location, so a type absent from a
//  fresh reading is gone rather than stale.
//

import Foundation
import GameModels
import SQLiteData

@Table
public struct LocationInventory: Identifiable, Equatable, Sendable {
    public var location: String
    public var resourceType: String
    public var quantity: Double
    public var fetchedAt: Date

    public var id: String { "\(location)|\(resourceType)" }

    public init(location: String, resourceType: String, quantity: Double, fetchedAt: Date) {
        self.location = location
        self.resourceType = resourceType
        self.quantity = quantity
        self.fetchedAt = fetchedAt
    }
}

extension LocationInventory {
    /// Replace one location's rows with `items`. Call inside a write
    /// transaction: the delete and the insert must land together, or a reader
    /// between them sees the location holding nothing.
    public static func replace(
        location: String, items: [InventoryItem], fetchedAt: Date, in db: Database
    ) throws {
        try LocationInventory.where { $0.location.eq(location) }.delete().execute(db)
        let rows = items.map {
            LocationInventory(
                location: location, resourceType: $0.resourceType.lowercased(),
                quantity: $0.quantity, fetchedAt: fetchedAt
            )
        }
        guard !rows.isEmpty else { return }
        try LocationInventory.insert { rows }.execute(db)
    }

    /// Creates the `locationInventories` table.
    public static let createLocationInventories = SchemaMigration(
        "Create 'locationInventories' table"
    ) { db in
        try #sql(
            """
            CREATE TABLE "locationInventories" (
              "location" TEXT NOT NULL,
              "resourceType" TEXT NOT NULL,
              "quantity" REAL NOT NULL DEFAULT 0,
              "fetchedAt" TEXT NOT NULL,
              PRIMARY KEY ("location", "resourceType")
            ) STRICT
            """
        )
        .execute(db)
    }
}
