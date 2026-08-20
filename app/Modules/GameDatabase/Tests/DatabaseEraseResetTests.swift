//
//  DatabaseEraseResetTests.swift
//  GameDatabaseTests
//
//  `GameDatabase.bootstrap()`'s reset branch (erase, then replay every
//  migration) only runs when `context == .live`, which no test can reach:
//  overriding `\.context` to `.live` isn't a workaround either, because
//  `SQLiteData.defaultDatabase()` would then open the real Application
//  Support database instead of a disposable one. `GameDatabase.reset(_:)` is
//  the extracted seam that makes the erase branch directly testable.
//

import Foundation
import GameModels
import SQLiteData
import Testing
import UniverseModels

@testable import GameDatabase

@Suite struct DatabaseEraseResetTests {
    @Test func resetErasesRowsAndReplaysToACompleteEmptySchema() throws {
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
        #expect(try database.read { try Star.fetchCount($0) } == 1)

        try GameDatabase.reset(database)

        // The rows are gone...
        #expect(try database.read { try Star.fetchCount($0) } == 0)

        // ...and every migration in `GameDatabase.manifest` replayed to the
        // SAME schema a fresh bootstrap produces — not just "some" schema.
        // This also pins erase-before-migrate ordering: reversed, `migrate`
        // on an already-up-to-date database is a no-op and the following
        // `erase()` would drop `grdb_migrations` too, leaving no schema at
        // all (and the `fetchCount` above would have thrown "no such table"
        // rather than returning 0).
        let actual = try SchemaDump.dump(database)
        let golden = try String(contentsOf: SchemaDump.goldenFixtureURL, encoding: .utf8)
        #expect(actual == golden)
    }
}
