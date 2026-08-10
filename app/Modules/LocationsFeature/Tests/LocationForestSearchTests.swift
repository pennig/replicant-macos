//
//  LocationForestSearchTests.swift
//  LocationsFeature
//

import Foundation
import GameDatabase
import SQLiteData
import Testing
import UniverseModels
@testable import LocationsFeature

@Suite struct LocationForestSearchTests {
    private func star(_ designation: String) -> Star {
        Star(
            designation: designation, spectralType: "G2", color: "white",
            positionX: 0, positionY: 0, positionZ: 0, estimatedPlanets: 1,
            explored: true, hasLife: nil, entryPoint: nil, createdAt: .distantPast
        )
    }

    /// SOL is hydrated (so it carries a scanned subtitle and children); VEGA is
    /// hydrated but must not match a "SOL" search; RIGEL is census-only.
    private func seed(_ database: any DatabaseWriter) throws {
        let sol = StarSystem(
            designation: "SOL", systemScanned: true, planetsScanned: 1, planetsTotal: 1,
            planets: [Planet(designation: "SOL-3", type: "Terrestrial", recon: .scanned)]
        )
        let vega = StarSystem(
            designation: "VEGA", systemScanned: true, planetsScanned: 2, planetsTotal: 2,
            planets: [Planet(designation: "VEGA-1", type: "Gas Giant", recon: .scanned)]
        )
        let solRow = try SystemDetail(system: sol, hydratedAt: .distantPast)
        let vegaRow = try SystemDetail(system: vega, hydratedAt: .distantPast)
        try database.write { db in
            for s in ["SOL", "SOLARIS", "VEGA", "RIGEL"] {
                try Star.upsert { star(s) }.execute(db)
            }
            try SystemDetail.upsert { solRow }.execute(db)
            try SystemDetail.upsert { vegaRow }.execute(db)
        }
    }

    /// A searched system keeps its hydrated detail. The blob query is narrowed by
    /// the same pattern as the star query, so a mismatch between the two would
    /// silently downgrade a hydrated system to a census leaf — this is what
    /// catches that.
    @Test func aSearchedSystemKeepsItsHydratedDetail() throws {
        let database = try GameDatabase.bootstrap()
        try seed(database)

        let value = try database.read { db in
            try LocationForest(search: "SOL", sort: .alphabetical, filter: .all, activeReplicantCode: nil)
                .fetch(db)
        }
        #expect(value.nodes.map(\.id) == ["SOL", "SOLARIS"])
        let sol = try #require(value.nodes.first { $0.id == "SOL" })
        #expect(sol.children?.map(\.id) == ["SOL-3"], "the hydrated blob still builds children")
        #expect(sol.subtitle?.contains("1/1 scanned") == true)
        let solaris = try #require(value.nodes.first { $0.id == "SOLARIS" })
        #expect(solaris.children == nil, "census-only, and VEGA's blob must not leak onto it")
    }

    /// An empty search still sees every system and every blob.
    @Test func anEmptySearchSeesEverything() throws {
        let database = try GameDatabase.bootstrap()
        try seed(database)

        let value = try database.read { db in
            try LocationForest(search: "", sort: .alphabetical, filter: .all, activeReplicantCode: nil)
                .fetch(db)
        }
        #expect(value.nodes.map(\.id) == ["RIGEL", "SOL", "SOLARIS", "VEGA"])
        #expect(value.nodes.first { $0.id == "VEGA" }?.children?.map(\.id) == ["VEGA-1"])
    }

    /// The explored filter counts a hydrated blob as explored, and that check
    /// reads the same narrowed rows — a system matching the search must not fall
    /// out of the explored set because its blob was filtered away.
    @Test func theExploredFilterStillSeesTheNarrowedBlobs() throws {
        let database = try GameDatabase.bootstrap()
        try seed(database)
        // Clear the census flag on both matches: SOLARIS then has nothing left to
        // prove it explored, while SOL survives on its blob alone.
        try database.write { db in
            try Star.where { $0.designation.in(["SOL", "SOLARIS"]) }
                .update { $0.explored = false }
                .execute(db)
        }

        let value = try database.read { db in
            try LocationForest(search: "SOL", sort: .alphabetical, filter: .explored, activeReplicantCode: nil)
                .fetch(db)
        }
        #expect(value.nodes.map(\.id) == ["SOL"])
    }
}
