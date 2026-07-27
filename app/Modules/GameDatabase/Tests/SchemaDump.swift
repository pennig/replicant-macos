//
//  SchemaDump.swift
//  GameDatabaseTests
//
//  Shared "dump the schema as SQL" helper. Two suites need the identical
//  fixture comparison: `GoldenSchemaTests` (a fresh bootstrap) and
//  `DatabaseEraseResetTests` (post-erase-and-replay) — reset must land on
//  exactly the schema a fresh bootstrap does, so both read this one fixture.
//

import Foundation
import SQLiteData

enum SchemaDump {
    static var goldenFixtureURL: URL {
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
    ///
    /// Ordered `type, name` for a small, stable diff — NOT execution order.
    /// The four `CREATE INDEX` statements sort ahead of the tables they
    /// index, so this text cannot be replayed against a blank database as-is;
    /// a future baseline squash (`SchemaMigration`'s `merging:` initialiser)
    /// that uses this fixture as its migration body must reorder statements
    /// into `CREATE TABLE` before `CREATE INDEX`.
    static func dump(_ database: any DatabaseWriter) throws -> String {
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
}
