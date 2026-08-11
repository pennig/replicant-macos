import Foundation
import GameDatabase
import SQLiteData
import Testing
@testable import GameModels

/// Deterministic test UUIDs. The house idiom is an explicit `uuidString`;
/// there is no `UUID(Int)` in this package's dependencies.
func testUUID(_ n: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012X", n))!
}

@Suite struct HaulYieldTests {
    @Test func anOpenPickupHasNoDelivery() {
        let yield = HaulYield(
            id: testUUID(0),
            directiveID: "D1",
            controllerCode: "7D1569BF",
            deviceCode: "F7B455B6",
            sourceDesignation: "ACHERNUR-BELT-1",
            collectedAt: Date(timeIntervalSince1970: 0),
            unitsCollected: 345,
            perType: ResourceCost(structural: 200, rares: 145),
            breakdownState: .exact
        )
        #expect(yield.isOpen)
        #expect(yield.perType.structural == 200)
    }

    @Test func theTableRoundTrips() async throws {
        let database = try GameDatabase.bootstrap()
        let row = HaulYield(
            id: testUUID(1),
            directiveID: "D1",
            controllerCode: "7D1569BF",
            deviceCode: "F7B455B6",
            sourceDesignation: "ACHERNUR-BELT-1",
            collectedAt: Date(timeIntervalSince1970: 0),
            unitsCollected: 100,
            perType: ResourceCost(conductive: 100),
            breakdownState: .exact
        )
        try await database.write { db in try HaulYield.upsert { row }.execute(db) }
        let read = try await database.read { db in try HaulYield.all.fetchAll(db) }
        #expect(read == [row])
    }
}
