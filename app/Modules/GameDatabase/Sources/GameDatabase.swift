//
//  GameDatabase.swift
//  GameDatabase
//
//  Owns the app's SQLite schema composition. Every feature's `@Table` migration
//  is registered here in one place, so the database used by the app, by Xcode
//  previews, and by tests all share a single schema and can never drift.
//

import Dependencies
import Foundation
import GameModels
import SQLiteData
import UniverseModels
import os

/// The single composition point for the app's database schema.
public enum GameDatabase {
    /// A migrator with every feature's table registered. Ordered so that tables
    /// referenced by others are created first.
    ///
    /// Adding a table? Decide its logout fate at the same time: account-scoped
    /// tables need a clear registered in `ReplicantApp.registerSessionCleanup()`
    /// (or `AccountManager`'s own teardown), or a second account on this
    /// machine inherits the first's rows — and "table is empty" cold-load
    /// gates then skip the fetch. `EventLog` is the one deliberate exemption
    /// (user-managed diagnostic ledger).
    public static func migrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        #if DEBUG
        migrator.eraseDatabaseOnSchemaChange = true
        #endif
        Message.registerMigrations(&migrator)
        Blueprint.registerMigrations(&migrator)
        Civilisation.registerMigrations(&migrator)
        Star.registerMigrations(&migrator)
        SystemDetail.registerMigrations(&migrator)
        LocationFootprint.registerMigrations(&migrator)
        LocationEvent.registerMigrations(&migrator)
        Replicant.registerMigrations(&migrator)
        KnownReplicant.registerMigrations(&migrator)
        Device.registerMigrations(&migrator)
        Directive.registerMigrations(&migrator)
        DirectiveLogEntry.registerMigrations(&migrator)
        FTLLinkRecord.registerMigrations(&migrator)
        BobnetMessage.registerMigrations(&migrator)
        BobnetChannel.registerMigrations(&migrator)
        // Qualified: `Operation` would otherwise be ambiguous with Foundation's.
        GameModels.Operation.registerMigrations(&migrator)
        EventLog.registerMigrations(&migrator)
        return migrator
    }

    /// Opens the default database and runs every migration, returning the writer.
    ///
    /// SQLiteData vends an in-memory store automatically in test and preview
    /// contexts, so the same call bootstraps production, previews, and tests.
    /// The writer is returned so tests can read and write it directly.
    public static func bootstrap() throws -> any DatabaseWriter {
        let database = try SQLiteData.defaultDatabase(configuration: configuration)
        try migrator().migrate(database)
        return database
    }

    /// Shared connection configuration. In DEBUG it traces executed SQL, routing
    /// to the logger when live and the console in previews, and staying silent in
    /// tests. Statements emitted by triggers (prefixed `--`) are skipped.
    public static var configuration: Configuration {
        let configuration = Configuration()
        #if DEBUG
//        configuration.prepareDatabase { db in
//            db.trace(options: .profile) { event in
//                @Dependency(\.context) var context
//                let sql = event.expandedDescription
//                guard !sql.hasPrefix("--") else { return }
//                switch context {
//                case .live: logger.debug("\(sql)")
//                case .preview: print(sql)
//                case .test: break
//                }
//            }
//        }
        #endif
        return configuration
    }
}

extension DependencyValues {
    /// Opens the default database and runs every feature's migrations. Called
    /// once from the app entry point's `prepareDependencies`, and from Xcode
    /// previews and tests that need the full schema.
    public mutating func bootstrapDatabase() throws {
        defaultDatabase = try GameDatabase.bootstrap()
    }

    /// Bootstraps the database and seeds it in one step — convenient for Xcode
    /// previews. Use `db.seed { … }` inside the closure to list rows to insert.
    public mutating func bootstrapDatabase(
        seed: (Database) throws -> Void
    ) throws {
        let database = try GameDatabase.bootstrap()
        try database.write { try seed($0) }
        defaultDatabase = database
    }
}

private let logger = Logger(subsystem: "name.pennig.replicould", category: "GameDatabase")
