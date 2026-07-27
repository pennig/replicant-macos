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
    @Test func freshSchemaMatchesTheGoldenFixture() throws {
        let actual = try SchemaDump.dump(try GameDatabase.bootstrap())

        if ProcessInfo.processInfo.environment["RC_REGENERATE_SCHEMA_FIXTURE"] == "1" {
            try FileManager.default.createDirectory(
                at: SchemaDump.goldenFixtureURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try actual.write(to: SchemaDump.goldenFixtureURL, atomically: true, encoding: .utf8)
            Issue.record("Regenerated \(SchemaDump.goldenFixtureURL.lastPathComponent) — review the diff and re-run without the flag.")
            return
        }

        let expected = try String(contentsOf: SchemaDump.goldenFixtureURL, encoding: .utf8)
        #expect(actual == expected)
    }
}
