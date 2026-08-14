//
//  EventLogObservationLifetimeTests.swift
//  EventLogFeatureTests
//
//  GRDB fetches a non-constant-region observation on the WRITER connection, so
//  a live `EventLogFeature.State` puts its display query in front of every
//  event the app ingests. Holding one must therefore be the window's business.
//

import ConcurrencyExtras
import Dependencies
import Foundation
import GameDatabase
import GameModels
import SQLiteData
import Testing

@testable import EventLogFeature

@Suite("Event log observation lifetime")
struct EventLogObservationLifetimeTests {
    /// A pool that counts how many times the ledger is *read*, so a re-fetch
    /// triggered by an ingestion write is directly observable.
    private func tracingPool() throws -> (any DatabaseWriter, LockIsolated<Int>) {
        let reads = LockIsolated(0)
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            db.trace { event in
                let sql = "\(event)"
                guard sql.contains("SELECT"), sql.contains("\"eventLogs\"") else { return }
                reads.withValue { $0 += 1 }
            }
        }
        let pool = try DatabasePool(
            path: NSTemporaryDirectory() + UUID().uuidString + ".db",
            configuration: configuration
        )
        try GameDatabase.migrator().migrate(pool)
        return (pool, reads)
    }

    private func record(_ id: String, into database: any DatabaseWriter) async throws {
        try await database.write { db in
            try EventLog.upsert {
                EventLog(
                    id: id, event: "ami.mining.digest", category: "ami",
                    receivedAt: Date(), provenance: "catchUp", isHandled: true
                )
            }
            .execute(db)
        }
    }

    @Test func aLiveStateReReadsTheLedgerOnEveryIngestionWrite() async throws {
        let (database, reads) = try tracingPool()
        try await withDependencies { $0.defaultDatabase = database } operation: {
            let state = EventLogFeature.State()
            _ = state.events
            try await Task.sleep(for: .milliseconds(200))

            reads.setValue(0)
            try await record("1", into: database)

            #expect(reads.value > 0)
            _ = state.events   // keep the observation alive to the end of the check
        }
    }

    /// The fix: with no state held, ingestion writes reach nothing to re-fetch.
    @Test func aReleasedStateStopsReadingTheLedger() async throws {
        let (database, reads) = try tracingPool()
        try await withDependencies { $0.defaultDatabase = database } operation: {
            var state: EventLogFeature.State? = EventLogFeature.State()
            _ = state?.events
            try await Task.sleep(for: .milliseconds(200))

            state = nil
            try await Task.sleep(for: .milliseconds(200))

            reads.setValue(0)
            try await record("1", into: database)
            try await record("2", into: database)

            #expect(reads.value == 0)
        }
    }
}
