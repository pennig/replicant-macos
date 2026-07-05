//
//  GameDatabaseTests.swift
//  GameDatabaseTests
//

import Foundation
import GameModels
import SQLiteData
import Testing

@testable import GameDatabase

@Suite struct GameDatabaseTests {
    /// The composed migrator runs cleanly, proving every feature's table schema
    /// still compiles together and no two migrations collide.
    @Test func bootstrapComposesEverySchema() throws {
        let database = try GameDatabase.bootstrap()
        // A representative table from each models module is queryable.
        try database.read { db in
            _ = try Message.fetchCount(db)
            _ = try Device.fetchCount(db)
        }
    }
}
