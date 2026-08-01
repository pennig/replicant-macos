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

    /// `addLinkMetrics` deliberately CLEARS `ftlLinks`. Pre-migration rows carry
    /// no distance or range, and `DirectFTLLinks` fails open on missing metrics,
    /// so leaving them would have every stale closure pair classify as a real
    /// link — reproducing the hairball the metrics exist to remove. The mesh is
    /// a wholesale-rebuilt cache, so dropping it is safe.
    ///
    /// The other half of the assertion matters just as much: clearing that one
    /// table must not touch anything else.
    @Test func linkMetricsMigrationClearsOnlyTheMesh() throws {
        // Bootstrap to the state *before* the metrics migration, so the rows
        // being cleared are genuinely pre-migration rows.
        let priorManifest = GameDatabase.manifest.filter {
            $0.identifier != "Add link metrics to 'ftlLinks'"
        }
        #expect(
            priorManifest.count == GameDatabase.manifest.count - 1,
            "the migration under test is missing from the manifest")

        let database = try DatabaseQueue()
        try GameDatabase.migrator(priorManifest).migrate(database)

        try database.write { db in
            // Raw SQL, not `FTLLinkRecord.insert`: the model now carries the
            // metrics columns, which by definition do not exist yet in the
            // pre-migration schema. Writing the old shape is the whole point —
            // this is the row a real upgrade would find sitting there.
            try #sql(
                """
                INSERT INTO "ftlLinks" ("id", "a", "b", "updatedAt")
                VALUES ('AINALRAM|TENEGSHE', 'AINALRAM', 'TENEGSHE', '2026-07-01 00:00:00.000')
                """
            )
            .execute(db)
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
        #expect(try database.read { try FTLLinkRecord.fetchCount($0) } == 1)

        try GameDatabase.migrator().migrate(database)

        #expect(
            try database.read { try FTLLinkRecord.fetchCount($0) } == 0,
            "metricless mesh rows survived the migration and would classify as direct")
        #expect(
            try database.read { try Star.fetchCount($0) } == 1,
            "clearing the mesh took unrelated rows with it")
    }
}
