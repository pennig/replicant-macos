//
//  GoldenSchemaTests.swift
//  GameDatabaseTests
//
//  Snapshots the schema a fresh database ends up with. Migrations are
//  append-only, so editing a shipped CREATE TABLE no longer wipes and
//  rebuilds — the edit simply never runs on an existing database and the
//  schema goes quietly stale. This test is what makes that loud.
//
//  Regenerate deliberately:
//    RC_REGENERATE_SCHEMA_FIXTURE=1 swift test --test-product GameDatabaseTests …
//  It rewrites the fixture AND still fails, so the change lands in a diff.
//

import Foundation
import SQLiteData
import Testing

@testable import GameDatabase

@Suite struct GoldenSchemaTests {
    static var fixtureURL: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "Fixtures/schema.sql")
    }

    /// `grdb_migrations` is excluded — it is GRDB-owned, and including it
    /// would couple this fixture to a library upgrade.
    ///
    /// GRDB's `Row` type isn't re-exported through `SQLiteData` (only a
    /// handful of GRDB symbols are, via `@_exported import`), so this reads
    /// the raw SQL the same way `Star.createStars` and friends write it:
    /// `#sql(…, as:)` decoded straight to `String`, via StructuredQueries'
    /// `Statement.fetchAll(_:)`.
    static func dumpSchema(_ database: any DatabaseWriter) throws -> String {
        try database.read { db in
            let sqlStatements = try #sql(
                """
                SELECT sql FROM sqlite_master
                WHERE sql IS NOT NULL
                  AND name NOT LIKE 'sqlite_%'
                  AND name <> 'grdb_migrations'
                ORDER BY type, name
                """,
                as: String.self
            )
            .fetchAll(db)
            return sqlStatements.map { $0 + ";" }.joined(separator: "\n\n") + "\n"
        }
    }

    @Test func freshSchemaMatchesTheGoldenFixture() throws {
        let actual = try Self.dumpSchema(try GameDatabase.bootstrap())

        if ProcessInfo.processInfo.environment["RC_REGENERATE_SCHEMA_FIXTURE"] == "1" {
            try FileManager.default.createDirectory(
                at: Self.fixtureURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try actual.write(to: Self.fixtureURL, atomically: true, encoding: .utf8)
            Issue.record("Regenerated \(Self.fixtureURL.lastPathComponent) — review the diff and re-run without the flag.")
            return
        }

        let expected = try String(contentsOf: Self.fixtureURL, encoding: .utf8)
        #expect(actual == expected)
    }
}
