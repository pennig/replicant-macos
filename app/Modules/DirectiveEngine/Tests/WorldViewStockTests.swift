//
//  WorldViewStockTests.swift
//  Replicould — DirectiveEngine
//

import Foundation
import GameDatabase
import SQLiteData
import Testing
import UniverseModels
@testable import DirectiveEngine

@Suite("WorldView — theatre stock")
struct WorldViewStockTests {
    @Test("stock sums the operational depots' rows and takes the oldest read")
    func sumsOperationalDepots() {
        let older = Date(timeIntervalSince1970: 1_750_000_000)
        let newer = older.addingTimeInterval(600)
        let rows = [
            LocationInventory(location: "A-BELT-1", resourceType: "conductive", quantity: 100, fetchedAt: older),
            LocationInventory(location: "B-BELT-1", resourceType: "conductive", quantity: 50, fetchedAt: newer),
            LocationInventory(location: "B-BELT-1", resourceType: "rares", quantity: 25, fetchedAt: newer),
            LocationInventory(location: "OFF-BELT-1", resourceType: "rares", quantity: 9999, fetchedAt: newer),
        ]
        let stock = WorldView.aggregateStock(rows: rows, depots: ["A-BELT-1", "B-BELT-1"])
        #expect(stock.quantities == ["conductive": 150, "rares": 25])
        #expect(stock.freshness == older)
    }

    @Test("no depot row means empty stock and no freshness")
    func noRowsMeansUnknown() {
        let stock = WorldView.aggregateStock(rows: [], depots: ["A-BELT-1"])
        #expect(stock.quantities.isEmpty)
        #expect(stock.freshness == nil)
    }

    /// Drives the real `read(from:now:)` path: an operational theatre's depot
    /// pulls its rows into `theatreStock`, a non-depot location's rows do not,
    /// and freshness is the oldest DEPOT row, ignoring the newer off-depot one.
    @Test("read wires theatreStock and freshness off the recognised depot")
    func readWiresTheatreStock() async throws {
        let db = try GameDatabase.bootstrap()
        let older = Date(timeIntervalSince1970: 1_750_000_000)
        let newer = older.addingTimeInterval(600)
        try await db.write { db in
            try seedRelay(db, code: "R1", location: "SOL-3-L4", status: "relaying")
            try seedPrintHub(db, code: "AF1", location: "SOL-3")
            try seedHubStockpile(db, location: "SOL-3", resources: 50_000)
            try LocationInventory.insert {
                [
                    LocationInventory(location: "SOL-3", resourceType: "conductive", quantity: 100, fetchedAt: older),
                    LocationInventory(location: "VEGA-3", resourceType: "rares", quantity: 9999, fetchedAt: newer),
                ]
            }.execute(db)
        }

        let view = try await db.read { try WorldView.read(from: $0, now: Date()) }
        #expect(view.theatres.map(\.depot) == ["SOL-3"])
        #expect(view.theatres[0].isOperational)
        #expect(view.theatreStock == ["conductive": 100])
        #expect(view.theatreStockFreshness == older)
    }

    @Test("no locationInventories rows yields empty stock and nil freshness")
    func readWithNoInventoryRowsYieldsUnknownStock() async throws {
        let db = try GameDatabase.bootstrap()
        try await db.write { db in
            try seedRelay(db, code: "R1", location: "SOL-3-L4", status: "relaying")
            try seedPrintHub(db, code: "AF1", location: "SOL-3")
            try seedHubStockpile(db, location: "SOL-3", resources: 50_000)
        }

        let view = try await db.read { try WorldView.read(from: $0, now: Date()) }
        #expect(view.theatres[0].isOperational)
        #expect(view.theatreStock.isEmpty)
        #expect(view.theatreStockFreshness == nil)
    }
}
