//
//  BrainTheatrePersistenceTests.swift
//  Replicould — DirectiveEngine
//
//  `Brain.persistTheatres` through the real tick: a depot, written, then kept.
//

import API
import Dependencies
import Foundation
import GameDatabase
import GameModels
import GameSession
import SQLiteData
import Testing
import UniverseModels
@testable import DirectiveEngine

private let persistenceNow = Date(timeIntervalSince1970: 60_000)

private func fundedClient() -> GameClient {
    var client = GameClient.testValue
    client.budget = { _ in RateLimitGovernor.Snapshot(limit: 60, remaining: 60, resetAt: nil) }
    return client
}

/// One meshed system holding TWO print locations, `BELT-1` the richer, so a
/// derived theatre resolves to `BELT-1` on the first tick.
private func seedTwoPrintLocations(_ db: Database) throws {
    try seedStar(db, designation: "AINALRAM", x: 0, y: 0, z: 0)
    try seedRelay(db, code: "REL-A", location: "AINALRAM", updatedAt: persistenceNow)
    try seedPrintHub(db, code: "HUB-1", location: "AINALRAM-BELT-1", updatedAt: persistenceNow)
    try seedPrintHub(db, code: "HUB-2", location: "AINALRAM-BELT-2", updatedAt: persistenceNow)
    try seedHubStockpile(db, location: "AINALRAM-BELT-1", resources: 40_000, fetchedAt: persistenceNow)
    try seedHubStockpile(db, location: "AINALRAM-BELT-2", resources: 900, fetchedAt: persistenceNow)
}

private func stock(_ db: Database, at location: String, _ resources: Int) throws {
    try LocationFootprint.upsert {
        LocationFootprint(
            location: location, devices: 1, resources: resources, resourceSites: 0,
            locationEvents: 0, replicants: 0, fetchedAt: persistenceNow
        )
    }
    .execute(db)
}

private func tick(_ database: any DatabaseWriter) async -> BrainReport {
    await withDependencies {
        $0.defaultDatabase = database
        $0.date = .constant(persistenceNow)
        $0.uuid = .incrementing
        $0.deviceRefresher = confirmingRefresher(database)
        $0.gameClient = fundedClient()
    } operation: {
        await Brain(now: persistenceNow).report()
    }
}

@Suite("Brain — theatre persistence")
struct BrainTheatrePersistenceTests {
    @Test("a tick over a derived theatre with no records writes one")
    func aTickPersistsADerivedTheatre() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in try seedTwoPrintLocations(db) }
        let before = try await database.read { db in try TheatreRecord.all.fetchAll(db) }
        #expect(before.isEmpty)

        let report = await tick(database)

        #expect(report.theatres.map(\.depot) == ["AINALRAM-BELT-1"])
        let records = try await database.read { db in try TheatreRecord.all.fetchAll(db) }
        #expect(records.count == 1)
        #expect(records.first?.depot == "AINALRAM-BELT-1")
        #expect(records.first?.system == "AINALRAM")
        #expect(records.first?.origin == "derived")
        #expect(records.first?.establishedAt == persistenceNow)
    }

    /// The whole point of the table: `BELT-1` is the POORER location by the
    /// second tick, so naming it again is only possible off the written row.
    @Test("a stock flip between two print locations does not move the depot")
    func theDepotSurvivesAStockFlip() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in try seedTwoPrintLocations(db) }
        #expect(await tick(database).theatres.map(\.depot) == ["AINALRAM-BELT-1"])

        try await database.write { db in
            try stock(db, at: "AINALRAM-BELT-1", 100)
            try stock(db, at: "AINALRAM-BELT-2", 90_000)
        }

        let report = await tick(database)

        #expect(report.theatres.map(\.depot) == ["AINALRAM-BELT-1"])
        #expect(report.theatres.first?.stock == 100)
        let records = try await database.read { db in try TheatreRecord.all.fetchAll(db) }
        #expect(records.map(\.depot) == ["AINALRAM-BELT-1"])
    }

    /// Losing the printer is the one thing that releases a depot, and the new
    /// one replaces the row rather than joining it.
    @Test("a depot that loses its printer is replaced, one row per system")
    func losingThePrinterRewritesTheRow() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in try seedTwoPrintLocations(db) }
        #expect(await tick(database).theatres.map(\.depot) == ["AINALRAM-BELT-1"])

        try await database.write { db in
            try Device.where { $0.deviceCode.eq("HUB-1") }.delete().execute(db)
            try stock(db, at: "AINALRAM-BELT-2", 90_000)
        }

        let report = await tick(database)

        #expect(report.theatres.map(\.depot) == ["AINALRAM-BELT-2"])
        let records = try await database.read { db in try TheatreRecord.all.fetchAll(db) }
        #expect(records.map(\.depot) == ["AINALRAM-BELT-2"])
    }
}
