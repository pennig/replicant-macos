//
//  TheatreRecordTests.swift
//  Replicould — GameModelsTests
//
//  The `theatres` table: the migration lands and a row survives a round trip.
//

import Foundation
import GameDatabase
import SQLiteData
import Testing
@testable import GameModels

@Suite struct TheatreRecordTests {
    @Test func theDepotIsTheIdentity() {
        let row = TheatreRecord(
            depot: "AINALRAM-BELT-1", system: "AINALRAM", origin: "derived",
            establishedAt: Date(timeIntervalSince1970: 100)
        )
        #expect(row.id == "AINALRAM-BELT-1")
    }

    @Test func theTableRoundTrips() async throws {
        let database = try GameDatabase.bootstrap()
        let row = TheatreRecord(
            depot: "DENEBED-BELT-1", system: "DENEBED", origin: "systemHub",
            establishedAt: Date(timeIntervalSince1970: 500)
        )
        try await database.write { db in try TheatreRecord.upsert { row }.execute(db) }
        let read = try await database.read { db in try TheatreRecord.all.fetchAll(db) }
        #expect(read == [row])
    }

    /// One row per system: re-establishing a system's depot replaces it rather
    /// than leaving two rows to disagree about which depot is current.
    @Test func aSystemsRowIsReplaceable() async throws {
        let database = try GameDatabase.bootstrap()
        let first = TheatreRecord(
            depot: "OMEROPE-BELT-1", system: "OMEROPE", origin: "derived",
            establishedAt: Date(timeIntervalSince1970: 100)
        )
        let second = TheatreRecord(
            depot: "OMEROPE-2-L4", system: "OMEROPE", origin: "pinned",
            establishedAt: Date(timeIntervalSince1970: 900)
        )
        try await database.write { db in
            try TheatreRecord.upsert { first }.execute(db)
            try TheatreRecord.where { $0.system.eq("OMEROPE") }.delete().execute(db)
            try TheatreRecord.upsert { second }.execute(db)
        }
        let read = try await database.read { db in try TheatreRecord.all.fetchAll(db) }
        #expect(read == [second])
    }
}
