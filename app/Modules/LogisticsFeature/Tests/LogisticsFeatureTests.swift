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
    @Test func theLedgerLoadsNewestFirst() async throws {
        let database = try GameDatabase.bootstrap()
        // Deliberately decorrelated from id, insertion, and unitsCollected
        // order, so only a `collectedAt` sort reproduces this expectation.
        let fixture: [(id: Int, collectedAt: TimeInterval, units: Int)] = [
            (id: 2, collectedAt: 200, units: 900),
            (id: 0, collectedAt: 300, units: 100),
            (id: 1, collectedAt: 100, units: 500),
        ]
        try await database.write { db in
            for row in fixture {
                try HaulYield.upsert {
                    HaulYield(
                        id: testUUID(row.id), directiveID: "D1", controllerCode: "C",
                        deviceCode: "F", sourceDesignation: "ACHERNUR-BELT-1",
                        collectedAt: Date(timeIntervalSince1970: row.collectedAt),
                        unitsCollected: row.units,
                        perType: ResourceCost(structural: row.units),
                        breakdownState: .exact
                    )
                }
                .execute(db)
            }
        }
        // `@FetchAll` fetches at init, so the ordering is assertable without
        // sending anything.
        let state = withDependencies {
            $0.defaultDatabase = database
        } operation: {
            LogisticsFeature.State()
        }
        #expect(state.yields.map(\.unitsCollected) == [100, 900, 500])
    }
}
