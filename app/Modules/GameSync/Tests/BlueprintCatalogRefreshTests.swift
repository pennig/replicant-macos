//
//  BlueprintCatalogRefreshTests.swift
//  Replicould — GameSync
//

import Dependencies
import Foundation
import GameDatabase
import GameModels
import GameServices
import SQLiteData
import Testing
@testable import GameSync

private struct FetchError: Error {}

@Suite("Blueprint catalog refresh")
struct BlueprintCatalogRefreshTests {
    @Test("never refreshed before is due")
    func neverRefreshedIsDue() {
        #expect(DeadlineScheduler.blueprintCatalogDue(
            lastAt: nil, now: Date(timeIntervalSince1970: 1_000), interval: 3600
        ))
    }

    @Test("inside the interval is not due")
    func insideIntervalIsNotDue() {
        let lastAt = Date(timeIntervalSince1970: 1_000)
        #expect(!DeadlineScheduler.blueprintCatalogDue(
            lastAt: lastAt, now: lastAt.addingTimeInterval(3599), interval: 3600
        ))
    }

    @Test("past the interval is due again")
    func pastIntervalIsDueAgain() {
        let lastAt = Date(timeIntervalSince1970: 1_000)
        #expect(DeadlineScheduler.blueprintCatalogDue(
            lastAt: lastAt, now: lastAt.addingTimeInterval(3600), interval: 3600
        ))
    }

    /// A failed fetch degrades to a silent no-op — never a crash, never a
    /// write — per the refresh's "costs efficiency, never correctness" contract.
    @Test("a failing fetch is a silent no-op that writes nothing")
    func failingFetchWritesNothing() async throws {
        let database = try GameDatabase.bootstrap()
        await withDependencies {
            $0.defaultDatabase = database
            $0.blueprintsClient.fetchAll = { throw FetchError() }
        } operation: {
            await DeadlineScheduler(reconciler: Reconciler()).refreshBlueprintCatalog()
        }
        let count = try await database.read { db in try Blueprint.fetchCount(db) }
        #expect(count == 0)
    }

    @Test("a successful fetch upserts the rows")
    func successfulFetchUpsertsRows() async throws {
        let database = try GameDatabase.bootstrap()
        await withDependencies {
            $0.defaultDatabase = database
            $0.blueprintsClient.fetchAll = { Blueprint.previewCatalog }
        } operation: {
            await DeadlineScheduler(reconciler: Reconciler()).refreshBlueprintCatalog()
        }
        let count = try await database.read { db in try Blueprint.fetchCount(db) }
        #expect(count == Blueprint.previewCatalog.count)
    }
}
