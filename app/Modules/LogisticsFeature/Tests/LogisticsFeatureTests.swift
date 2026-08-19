import ComposableArchitecture
import Foundation
import GameDatabase
import GameModels
import SQLiteData
import Testing
@testable import LogisticsFeature

// House idiom (see GameModels' HaulYieldTests): there is no `UUID(Int)` in
// this package's dependencies, so deterministic test IDs go through a string.
private func testUUID(_ n: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012X", n))!
}

@Suite struct LogisticsFeatureTests {
    private let now = Date(timeIntervalSince1970: 1_000 * 86_400)

    private func seeded(
        _ rows: [HaulYield]
    ) async throws -> (state: LogisticsFeature.State, database: any DatabaseWriter) {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            for row in rows { try HaulYield.upsert { row }.execute(db) }
        }
        // `@Fetch` fetches at init, so the digest is assertable without sending
        // anything — but only under a clock the fixture's dates sit beneath.
        let state = withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(now)
        } operation: {
            LogisticsFeature.State()
        }
        return (state, database)
    }

    private func state(seeding rows: [HaulYield]) async throws -> LogisticsFeature.State {
        try await seeded(rows).state
    }

    private func yield(id: Int, minutesAgo: Int, units: Int, source: String = "ACHERNUR-BELT-1")
        -> HaulYield
    {
        HaulYield(
            id: testUUID(id), directiveID: "D1", controllerCode: "C", deviceCode: "F",
            sourceDesignation: source,
            collectedAt: now.addingTimeInterval(-TimeInterval(minutesAgo) * 60),
            unitsCollected: units, perType: ResourceCost(structural: units),
            breakdownState: .exact
        )
    }

    @Test func theLedgerLoadsNewestFirst() async throws {
        // Deliberately decorrelated from id, insertion, and unitsCollected
        // order, so only a `collectedAt` sort reproduces this expectation.
        let state = try await state(seeding: [
            yield(id: 2, minutesAgo: 20, units: 900),
            yield(id: 0, minutesAgo: 10, units: 100),
            yield(id: 1, minutesAgo: 30, units: 500),
        ])
        #expect(state.summary.rows.map(\.unitsCollected) == [100, 900, 500])
    }

    // The charts must count past the table's bound, or a busy day's window is
    // charted as whatever slice the table happened to list.
    @Test func theChartsCountTheWholeWindowWhileTheTableStops() async throws {
        let overflow = HaulYieldDigest.tableRowLimit + 150
        let state = try await state(
            seeding: (0..<overflow).map { yield(id: $0, minutesAgo: $0, units: 3) }
        )
        #expect(state.summary.tripCount == overflow)
        #expect(state.summary.totalUnits == overflow * 3)
        #expect(state.summary.rows.count == HaulYieldDigest.tableRowLimit)
        #expect(state.summary.hiddenRowCount == 150)
    }

    // The table's bound is a number, not "whatever the fixture has": 100 rows
    // listed out of 250 is only correct if `tableRowLimit` is 100.
    @Test func theTableBoundIsOneHundredRows() {
        #expect(HaulYieldDigest.tableRowLimit == 100)
    }

    @MainActor
    @Test func changingTheRangeRefoldsTheWindow() async throws {
        let (state, database) = try await seeded([
            yield(id: 0, minutesAgo: 60, units: 10),
            yield(id: 1, minutesAgo: 60 * 24 * 3, units: 400),
        ])
        #expect(state.summary.tripCount == 2)
        let store = TestStore(initialState: state) {
            LogisticsFeature()
        } withDependencies: {
            $0.defaultDatabase = database
            $0.date = .constant(now)
        }
        await store.send(.binding(.set(\.range, .day))) { $0.range = .day }
        // The reload lands asynchronously through `@Fetch`, which the store does
        // not observe — the digest itself is what this asserts.
        await store.finish()
        #expect(store.state.summary.tripCount == 1)
        #expect(store.state.summary.totalUnits == 10)
    }
}
