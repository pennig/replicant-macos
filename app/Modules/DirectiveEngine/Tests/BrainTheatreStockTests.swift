//
//  BrainTheatreStockTests.swift
//  Replicould — DirectiveEngine
//
//  Pins that each operational theatre's `BrainReport.theatreLimits` carries
//  its OWN census reading — never another theatre's — through the real
//  `Brain.report()` pipeline, `Snapshot.hubFootprints` included.
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

private let stockFixtureNow = Date(timeIntervalSince1970: 40_000)

private func fundedGameClient() -> GameClient {
    var client = GameClient.testValue
    client.budget = { _ in RateLimitGovernor.Snapshot(limit: 60, remaining: 60, resetAt: nil) }
    return client
}

/// Two meshed, print-capable systems far enough apart that `MeshGraph` never
/// merges them into one component — each recognised as its OWN theatre, with
/// a footprint of `resources` distinct from the other's.
private func seedTwoTheatreWorld(_ db: Database, ainalramStock: Int, denebedStock: Int) throws {
    try seedStar(db, designation: "AINALRAM", x: 0, y: 0, z: 0)
    try seedRelay(db, code: "REL-A", location: "AINALRAM", updatedAt: stockFixtureNow)
    try seedPrintHub(db, code: "HUB-A", location: "AINALRAM-BELT-1", updatedAt: stockFixtureNow)
    try seedHubStockpile(db, location: "AINALRAM-BELT-1", resources: ainalramStock, fetchedAt: stockFixtureNow)

    try seedStar(db, designation: "DENEBED", x: 2_000, y: 2_000, z: 2_000)
    try seedRelay(db, code: "REL-B", location: "DENEBED", updatedAt: stockFixtureNow)
    try seedPrintHub(db, code: "HUB-B", location: "DENEBED-BELT-1", updatedAt: stockFixtureNow)
    try seedHubStockpile(db, location: "DENEBED-BELT-1", resources: denebedStock, fetchedAt: stockFixtureNow)
}

@Suite("Brain — per-theatre stock reporting")
struct BrainTheatreStockTests {
    @Test("two theatres with different footprint resources each report their own number")
    func eachTheatreReportsItsOwnStock() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in try seedTwoTheatreWorld(db, ainalramStock: 40_000, denebedStock: 900) }

        let report = await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(stockFixtureNow)
            $0.uuid = .incrementing
            $0.deviceRefresher = confirmingRefresher(database)
            $0.gameClient = fundedGameClient()
        } operation: {
            await Brain(now: stockFixtureNow).report()
        }

        #expect(report.theatres.map(\.depot).sorted() == ["AINALRAM-BELT-1", "DENEBED-BELT-1"])
        #expect(report.theatreLimits["AINALRAM-BELT-1"]?.hubStock == 40_000)
        #expect(report.theatreLimits["DENEBED-BELT-1"]?.hubStock == 900)
        // Never the OTHER theatre's number under this theatre's own heading.
        #expect(report.theatreLimits["AINALRAM-BELT-1"]?.hubStock != report.theatreLimits["DENEBED-BELT-1"]?.hubStock)
    }
}
