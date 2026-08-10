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
        try await database.write { db in
            for index in 0..<3 {
                try HaulYield.upsert {
                    HaulYield(
                        id: testUUID(index), directiveID: "D1", controllerCode: "C",
                        deviceCode: "F", sourceDesignation: "ACHERNUR-BELT-1",
                        collectedAt: Date(timeIntervalSince1970: TimeInterval(index)),
                        unitsCollected: 100 * (index + 1),
                        perType: ResourceCost(structural: 100 * (index + 1)),
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
        #expect(state.yields.map(\.unitsCollected) == [300, 200, 100])
    }
}
