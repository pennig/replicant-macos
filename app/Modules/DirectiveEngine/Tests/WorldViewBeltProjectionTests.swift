//
//  WorldViewBeltProjectionTests.swift
//  DirectiveEngine
//

import Foundation
import GameDatabase
import SQLiteData
import Testing
import UniverseModels
@testable import DirectiveEngine

@Suite struct WorldViewBeltProjectionTests {
    /// A surveyed system whose belts span every classification route: density
    /// alone, richness fallback, and an unclassifiable belt that must be dropped.
    private func seed(_ database: any DatabaseWriter) throws {
        let system = StarSystem(
            designation: "SOL", systemScanned: true,
            belts: [
                Belt(designation: "SOL-BELT-1", density: "dense"),
                Belt(designation: "SOL-BELT-2", density: nil, richness: ["rares": "high"]),
                Belt(designation: "SOL-BELT-3", density: "unknowable", richness: ["carbon": "???"]),
            ]
        )
        let unscanned = StarSystem(
            designation: "VEGA", systemScanned: false,
            belts: [Belt(designation: "VEGA-BELT-1", density: "dense")]
        )
        let scannedRow = try SystemDetail(system: system, hydratedAt: .distantPast)
        let unscannedRow = try SystemDetail(system: unscanned, hydratedAt: .distantPast)
        try database.write { db in
            try SystemDetail.upsert { scannedRow }.execute(db)
            try SystemDetail.upsert { unscannedRow }.execute(db)
        }
    }

    @Test func classifiesEachBeltAndDropsTheUnclassifiable() throws {
        let database = try GameDatabase.bootstrap()
        try seed(database)

        let belts = try database.read { db in try WorldView.beltsBySystem(in: db) }
        #expect(belts.keys.sorted() == ["SOL"], "an unsurveyed system is out of scope")
        let sol = try #require(belts["SOL"])
        #expect(sol.map(\.designation).sorted() == ["SOL-BELT-1", "SOL-BELT-2"])
        #expect(sol.first { $0.designation == "SOL-BELT-1" }?.beltClass == .rich)
        let byRichness = try #require(sol.first { $0.designation == "SOL-BELT-2" })
        #expect(byRichness.beltClass == .rich)
        #expect(byRichness.richness == ["rares": "high"])
    }

    /// A belt carrying no `richness` object must classify off density alone
    /// rather than being dropped by a failed decode of a missing field.
    @Test func aBeltWithNoRichnessStillClassifies() throws {
        let database = try GameDatabase.bootstrap()
        let system = StarSystem(
            designation: "RIGEL", systemScanned: true,
            belts: [Belt(designation: "RIGEL-BELT-1", density: "sparse", richness: [:])]
        )
        let row = try SystemDetail(system: system, hydratedAt: .distantPast)
        try database.write { db in
            try SystemDetail.upsert { row }.execute(db)
        }

        let belts = try database.read { db in try WorldView.beltsBySystem(in: db) }
        #expect(belts["RIGEL"]?.map(\.beltClass) == [.sparse])
    }

    /// One malformed blob must degrade to "no belt data for that system", never
    /// fail the read — `json_each` raises on invalid JSON, so the query has to
    /// keep it from ever seeing one.
    @Test func aMalformedBlobDegradesInsteadOfFailingTheRead() throws {
        let database = try GameDatabase.bootstrap()
        try seed(database)
        // Seed through the model, then corrupt the blob behind its back — the
        // column list of an INSERT rejects the qualified names symbol
        // interpolation renders.
        let wreck = try SystemDetail(
            system: StarSystem(
                designation: "WRECK", systemScanned: true,
                belts: [Belt(designation: "WRECK-BELT-1", density: "dense")]
            ),
            hydratedAt: .distantPast
        )
        try database.write { db in
            try SystemDetail.upsert { wreck }.execute(db)
            try #sql("UPDATE systemDetails SET systemJSON = 'not json at all' WHERE designation = 'WRECK'")
                .execute(db)
        }

        let belts = try database.read { db in try WorldView.beltsBySystem(in: db) }
        #expect(belts["WRECK"] == nil)
        #expect(belts["SOL"]?.count == 2, "the healthy system's belts still come through")
    }

    /// A system with no belts at all is absent from the map, matching the decode
    /// path — `surveyedSystems` is what tells that from "never looked".
    @Test func aSystemWithNoBeltsIsAbsent() throws {
        let database = try GameDatabase.bootstrap()
        let system = StarSystem(designation: "TAU", systemScanned: true, belts: [])
        let row = try SystemDetail(system: system, hydratedAt: .distantPast)
        try database.write { db in
            try SystemDetail.upsert { row }.execute(db)
        }

        let belts = try database.read { db in try WorldView.beltsBySystem(in: db) }
        #expect(belts["TAU"] == nil)
    }
}
