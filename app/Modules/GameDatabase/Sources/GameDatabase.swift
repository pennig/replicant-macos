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
    /// Every migration, in order. **The array index is the order** — there is
    /// deliberately no sequence number, so there is no ordering key that can
    /// collide and no reliance on a sort (Swift's is not stable, and a tie
    /// would order non-deterministically between runs).
    ///
    /// Append new migrations to the END. Never edit an entry that has shipped:
    /// its identifier is already recorded in real databases, so an edit simply
    /// never runs and leaves the schema silently stale. The golden schema test
    /// exists to catch exactly that.
    ///
    /// This order reproduces the original per-table registration order, so the
    /// identifiers written to `grdb_migrations` are unchanged.
    ///
    /// Adding a table? Decide its logout fate at the same time: account-scoped
    /// tables need a clear registered in `ReplicantApp.registerSessionCleanup()`
    /// (or `AccountManager`'s own teardown), or a second account on this
    /// machine inherits the first's rows — and "table is empty" cold-load
    /// gates then skip the fetch. `EventLog` is the one deliberate exemption
    /// (user-managed diagnostic ledger).
    public static let manifest: [SchemaMigration] = [
        Message.createMessages,
        Message.addMessageCategories,
        Blueprint.createBlueprints,
        Civilisation.createCivilisations,
        Star.createStars,
        SystemDetail.createSystemDetails,
        LocationFootprint.createLocationFootprints,
        SiteAssay.createSiteAssays,
        LocationEvent.createLocationEvents,
        LocationEvent.addObjectivesMet,
        Replicant.createReplicants,
        KnownReplicant.createKnownReplicants,
        Device.createDevices,
        Directive.createDirectives,
        Directive.addControllerCode,
        DirectiveLogEntry.createDirectiveLogEntries,
        FTLLinkRecord.createFTLLinks,
        BobnetMessage.createBobnetMessages,
        BobnetChannel.createBobnetChannels,
        // Qualified: `Operation` would otherwise be ambiguous with Foundation's.
        GameModels.Operation.createOperations,
        EventLog.createEventLogs,
    ]

    /// Builds a migrator from `entries`. The parameter exists so tests can
    /// migrate a deliberately-modified manifest through the real code path.
    ///
    /// `eraseDatabaseOnSchemaChange` is deliberately NOT set. It wiped the
    /// database whenever a migration landed anywhere but the end of the list,
    /// which cost the stars catalogue repeatedly. A migration that throws now
    /// surfaces through `bootstrapDatabase`'s `withErrorReporting` instead.
    public static func migrator(_ entries: [SchemaMigration] = manifest) -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        for entry in entries {
            entry.register(in: &migrator)
        }
        return migrator
    }

    /// Opens the default database and runs every migration, returning the writer.
    ///
    /// SQLiteData vends an in-memory store automatically in test and preview
    /// contexts, so the same call bootstraps production, previews, and tests.
    /// The writer is returned so tests can read and write it directly.
    ///
    /// Honours a requested reset (see `DatabaseReset`) before migrating. The
    /// check is skipped outside `.live`: tests and previews already get a
    /// fresh in-memory store, where erasing would be meaningless.
    public static func bootstrap() throws -> any DatabaseWriter {
        let database = try SQLiteData.defaultDatabase(configuration: configuration)
        @Dependency(\.context) var context
        if context == .live,
           DatabaseReset.consumeRequest(
               defaults: .standard,
               environment: ProcessInfo.processInfo.environment
           )
        {
            logger.warning("Reset requested — erasing the local database before migrating.")
            try database.erase()
        }
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
