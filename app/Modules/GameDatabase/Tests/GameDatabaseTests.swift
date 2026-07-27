//
//  GameDatabaseTests.swift
//  GameDatabaseTests
//

import Foundation
import GameModels
import SQLiteData
import Testing
import UniverseModels

@testable import GameDatabase

@Suite struct GameDatabaseTests {
    /// The composed migrator runs cleanly AND every `@Table` model's full
    /// column list matches the schema it actually got — for all 18 tables,
    /// not a sample of two.
    ///
    /// A `SELECT count(*)` (this test's previous form) validates neither
    /// half of that: it compiles to `SELECT count(*) FROM …`, which mentions
    /// no column names at all. Add a property to a `@Table` struct and skip
    /// the matching `ALTER TABLE`, and `fetchCount` keeps passing — the
    /// mismatch only surfaces later, as a `@FetchAll` throwing "no such
    /// column" in the running app. `.all.fetchAll` prepares the real,
    /// generated `SELECT` (every column the struct declares) against the
    /// live schema, so a missing column fails right here, at prepare time.
    @Test func bootstrapComposesEverySchema() throws {
        let database = try GameDatabase.bootstrap()
        try database.read { db in
            _ = try Message.all.fetchAll(db)
            _ = try Blueprint.all.fetchAll(db)
            _ = try Civilisation.all.fetchAll(db)
            _ = try Star.all.fetchAll(db)
            _ = try SystemDetail.all.fetchAll(db)
            _ = try LocationFootprint.all.fetchAll(db)
            _ = try SiteAssay.all.fetchAll(db)
            _ = try LocationEvent.all.fetchAll(db)
            _ = try Replicant.all.fetchAll(db)
            _ = try KnownReplicant.all.fetchAll(db)
            _ = try Device.all.fetchAll(db)
            _ = try Directive.all.fetchAll(db)
            _ = try DirectiveLogEntry.all.fetchAll(db)
            _ = try FTLLinkRecord.all.fetchAll(db)
            _ = try BobnetMessage.all.fetchAll(db)
            _ = try BobnetChannel.all.fetchAll(db)
            // Qualified: `Operation` would otherwise be ambiguous with Foundation's.
            _ = try GameModels.Operation.all.fetchAll(db)
            _ = try EventLog.all.fetchAll(db)
        }
    }
}
