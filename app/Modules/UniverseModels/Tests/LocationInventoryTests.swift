//
//  LocationInventoryTests.swift
//  Replicould — UniverseModels
//

import Foundation
import GameDatabase
import SQLiteData
import Testing
@testable import UniverseModels

@Suite("LocationInventory — the per-type stock record")
struct LocationInventoryTests {
    private func database() throws -> any DatabaseWriter {
        try GameDatabase.bootstrap()
    }

    @Test("replace writes one row per resource type")
    func replaceWritesRows() throws {
        let db = try database()
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        try db.write { db in
            try LocationInventory.replace(
                location: "AINALRAM-BELT-1",
                items: [
                    InventoryItem(resourceType: "conductive", quantity: 120),
                    InventoryItem(resourceType: "volatiles", quantity: 10),
                ],
                fetchedAt: now,
                in: db
            )
        }
        let rows = try db.read { db in
            try LocationInventory.all.order { $0.resourceType }.fetchAll(db)
        }
        #expect(rows.map(\.resourceType) == ["conductive", "volatiles"])
        #expect(rows.map(\.quantity) == [120, 10])
        #expect(rows.allSatisfy { $0.fetchedAt == now })
    }

    @Test("replace drops types absent from the fresh reading")
    func replaceDropsStaleTypes() throws {
        let db = try database()
        let first = Date(timeIntervalSince1970: 1_750_000_000)
        let second = first.addingTimeInterval(3600)
        try db.write { db in
            try LocationInventory.replace(
                location: "AINALRAM-BELT-1",
                items: [
                    InventoryItem(resourceType: "conductive", quantity: 120),
                    InventoryItem(resourceType: "volatiles", quantity: 10),
                ],
                fetchedAt: first,
                in: db
            )
            try LocationInventory.replace(
                location: "AINALRAM-BELT-1",
                items: [InventoryItem(resourceType: "conductive", quantity: 90)],
                fetchedAt: second,
                in: db
            )
        }
        let rows = try db.read { db in try LocationInventory.all.fetchAll(db) }
        #expect(rows.count == 1)
        #expect(rows.first?.resourceType == "conductive")
        #expect(rows.first?.quantity == 90)
    }

    @Test("replace scopes its delete to the one location")
    func replaceScopesToLocation() throws {
        let db = try database()
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        try db.write { db in
            try LocationInventory.replace(
                location: "OTHER-BELT-1",
                items: [InventoryItem(resourceType: "rares", quantity: 40)],
                fetchedAt: now, in: db
            )
            try LocationInventory.replace(
                location: "AINALRAM-BELT-1",
                items: [InventoryItem(resourceType: "conductive", quantity: 120)],
                fetchedAt: now, in: db
            )
        }
        let rows = try db.read { db in
            try LocationInventory.all.order { $0.location }.fetchAll(db)
        }
        #expect(rows.map(\.location) == ["AINALRAM-BELT-1", "OTHER-BELT-1"])
    }
}
