//
//  SchemaMigrationTests.swift
//  GameModelsTests
//

import Foundation
import SQLiteData
import Testing

@testable import GameModels

@Suite struct SchemaMigrationTests {
    /// A registered migration runs, and GRDB records it under the exact
    /// identifier string it was given — the string existing databases key on.
    @Test func registersUnderItsIdentifier() throws {
        let migration = SchemaMigration("Create 'widgets' table") { db in
            try #sql(#"CREATE TABLE "widgets" ("id" TEXT PRIMARY KEY NOT NULL) STRICT"#)
                .execute(db)
        }

        var migrator = DatabaseMigrator()
        migration.register(in: &migrator)

        let database = try DatabaseQueue()
        try migrator.migrate(database)

        let applied = try database.read { try migrator.appliedIdentifiers($0) }
        #expect(applied == ["Create 'widgets' table"])
    }

    /// The merging initialiser hands the migration body the set of previously
    /// applied identifiers it supersedes, and drops their rows. This is the
    /// mechanism the future baseline squash relies on.
    @Test func mergingMigrationSupersedesOldIdentifiers() throws {
        let database = try DatabaseQueue()

        var old = DatabaseMigrator()
        SchemaMigration("v1") { db in
            try #sql(#"CREATE TABLE "widgets" ("id" TEXT PRIMARY KEY NOT NULL) STRICT"#)
                .execute(db)
        }
        .register(in: &old)
        try old.migrate(database)

        nonisolated(unsafe) var seenApplied: Set<String>?
        var merged = DatabaseMigrator()
        SchemaMigration("Baseline", merging: ["v1"]) { _, appliedIDs in
            seenApplied = appliedIDs
        }
        .register(in: &merged)
        try merged.migrate(database)

        #expect(seenApplied == ["v1"])
        let applied = try database.read { try merged.appliedIdentifiers($0) }
        #expect(applied == ["Baseline"])
    }
}
