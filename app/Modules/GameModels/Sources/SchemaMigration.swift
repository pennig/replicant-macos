//
//  SchemaMigration.swift
//  GameModels
//
//  One schema change, as a value. Ordering lives in `GameDatabase.manifest`
//  (an array whose index IS the order), deliberately NOT in `identifier` —
//  GRDB persists the identifier, so renaming one would make an existing
//  database treat the migration as unapplied and re-run its CREATE TABLE
//  against a table that already exists. Keeping order and identity separate
//  is what lets migrations be reordered on paper without touching real data.
//

import Foundation
import SQLiteData

public struct SchemaMigration: Sendable {
    /// The string GRDB writes to `grdb_migrations`. Immutable once shipped.
    public let identifier: String

    /// Identifiers this migration supersedes. Empty for every ordinary
    /// migration; populated only by a baseline squash.
    public let mergedIdentifiers: Set<String>

    private let body: @Sendable (Database, Set<String>) throws -> Void

    /// The ordinary case: a migration that runs the same way every time.
    public init(
        _ identifier: String,
        migrate: @escaping @Sendable (Database) throws -> Void
    ) {
        self.identifier = identifier
        self.mergedIdentifiers = []
        self.body = { db, _ in try migrate(db) }
    }

    /// The squash case. The body receives the subset of `merging` that was
    /// already applied, so it can skip work an older migration chain did.
    public init(
        _ identifier: String,
        merging mergedIdentifiers: Set<String>,
        migrate: @escaping @Sendable (Database, Set<String>) throws -> Void
    ) {
        self.identifier = identifier
        self.mergedIdentifiers = mergedIdentifiers
        self.body = migrate
    }

    /// Registers this migration with GRDB. Registration order is the caller's
    /// responsibility — see `GameDatabase.manifest`.
    public func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration(
            identifier,
            merging: mergedIdentifiers,
            migrate: body
        )
    }
}
