//
//  MigrationSafetyTests.swift
//  GameDatabaseTests
//
//  The regression that motivated append-only migrations: adding a table used
//  to erase the whole database, taking the rate-limited stars catalogue and
//  the click-to-rehydrate location tables with it.
//

import Foundation
import GameModels
import SQLiteData
import Testing
import UniverseModels

@testable import GameDatabase

@Suite struct MigrationSafetyTests {
    /// Adding a migration in the MIDDLE of the manifest must not cost existing
    /// rows. Mid-list is the case that matters: GRDB's erase check compares
    /// against a throwaway database migrated to the last APPLIED identifier,
    /// so a migration appended at the end always survived and only a
    /// mid-list one wiped.
    @Test func addingAMigrationPreservesExistingRows() throws {
        let database = try GameDatabase.bootstrap()

        try database.write { db in
            try Star.insert {
                Star(
                    designation: "SOL", spectralType: "G2", color: "yellow-white",
                    positionX: 0, positionY: 0, positionZ: 0, estimatedPlanets: 8,
                    explored: true, hasLife: true, entryPoint: nil,
                    createdAt: .distantPast
                )
            }
            .execute(db)
        }

        var extended = GameDatabase.manifest
        extended.insert(
            SchemaMigration("test-only mid-list table") { db in
                try #sql(#"CREATE TABLE "midListProbe" ("x" TEXT) STRICT"#).execute(db)
            },
            at: 1
        )
        try GameDatabase.migrator(extended).migrate(database)

        let survivingStars = try database.read { try Star.fetchCount($0) }
        #expect(survivingStars == 1, "a new mid-list migration erased the catalogue")
    }
}
