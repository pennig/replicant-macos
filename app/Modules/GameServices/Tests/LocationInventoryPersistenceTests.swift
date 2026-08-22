//
//  LocationInventoryPersistenceTests.swift
//  Replicould — GameServices
//

import Dependencies
import Foundation
import GameDatabase
import SQLiteData
import Testing
import UniverseModels
@testable import GameServices

@Suite("Depot inventory persistence")
struct LocationInventoryPersistenceTests {
    @Test("refreshDepotInventories writes one location's per-type rows")
    func writesRows() async throws {
        let db = try GameDatabase.bootstrap()
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        var client = LocationsClient.testValue
        client.body = { designation in
            #expect(designation == "AINALRAM-BELT-1")
            return .belt(Belt(
                designation: designation,
                inventory: [
                    InventoryItem(resourceType: "conductive", quantity: 19161),
                    InventoryItem(resourceType: "volatiles", quantity: 6538),
                ]
            ))
        }
        let stubbed = client
        await withDependencies {
            $0.defaultDatabase = db
            $0.date = .constant(now)
        } operation: {
            await stubbed.refreshDepotInventories(["AINALRAM-BELT-1"])
        }
        let rows = try await db.read { db in
            try LocationInventory.all.order { $0.resourceType }.fetchAll(db)
        }
        #expect(rows.map(\.resourceType) == ["conductive", "volatiles"])
        #expect(rows.map(\.quantity) == [19161, 6538])
    }

    @Test("a failing depot is skipped, not fatal")
    func failingDepotIsSkipped() async throws {
        struct Boom: Error {}
        let db = try GameDatabase.bootstrap()
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        var client = LocationsClient.testValue
        client.body = { designation in
            if designation == "BAD-BELT-1" { throw Boom() }
            return .belt(Belt(
                designation: designation,
                inventory: [InventoryItem(resourceType: "rares", quantity: 40)]
            ))
        }
        let stubbed = client
        await withDependencies {
            $0.defaultDatabase = db
            $0.date = .constant(now)
        } operation: {
            await stubbed.refreshDepotInventories(["BAD-BELT-1", "GOOD-BELT-1"])
        }
        let rows = try await db.read { db in try LocationInventory.all.fetchAll(db) }
        #expect(rows.map(\.location) == ["GOOD-BELT-1"])
    }

    /// A Lagrange point is a `.special` body and a real depot — `TIANEFU-9-L4`
    /// is a pinned theatre holding five figures. `BodyDetail.inventory` dropped
    /// every special site's stock, so no L4 depot ever got a row and the
    /// reserve rail vetoed its prints on a reading thrown away, not absent.
    @Test("a special site's inventory is persisted, not dropped")
    func specialSiteInventoryIsPersisted() async throws {
        let db = try GameDatabase.bootstrap()
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        var client = LocationsClient.testValue
        client.body = { designation in
            .special(SpecialSite(
                designation: designation, kind: .lagrange,
                inventory: [
                    InventoryItem(resourceType: "conductive", quantity: 2991),
                    InventoryItem(resourceType: "structural", quantity: 5292),
                ]
            ))
        }
        let stubbed = client
        await withDependencies {
            $0.defaultDatabase = db
            $0.date = .constant(now)
        } operation: {
            await stubbed.refreshDepotInventories(["TIANEFU-9-L4"])
        }
        let rows = try await db.read { db in
            try LocationInventory.all.order { $0.resourceType }.fetchAll(db)
        }
        #expect(rows.map(\.resourceType) == ["conductive", "structural"])
        #expect(rows.map(\.quantity) == [2991, 5292])
    }
}
