import API
import ComposableArchitecture
import Foundation
import GameDatabase
import GameModels
import SQLiteData
import Testing
import Utils
@testable import GameServices

@Suite struct LogisticsIngestionTests {
    private func digestEvent(carried: Int, collected: Int = 0, delivered: Int = 0) -> GameEventEnvelope {
        GameEventEnvelope(
            id: "1-0",
            category: "ami",
            event: "ami.transport.digest",
            deviceCode: "8D53C9B1",
            payload: [
                "report": .object([
                    "cargo_carried": .number(Double(carried)),
                    "cargo_capacity": .number(500),
                    "collect": .string("ACHERNUR-BELT-1"),
                    "deliver": .string("AINALRAM-BELT-1"),
                ]),
                "activity": .object([
                    "counts": .object([
                        "transport.collected": .number(Double(collected)),
                        "transport.delivered": .number(Double(delivered)),
                    ])
                ]),
                "devices": .array([
                    .object([
                        "device_code": .string("F7B455B6"),
                        "last_event": .string(collected > 0 ? "transport.collected" : "transport.delivered"),
                    ])
                ]),
            ]
        )
    }

    private func testUUID(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012X", n))!
    }

    /// The freighter, holding whatever `cargo` the case needs.
    private func freighter(cargo: [(String, Int)]) -> Device {
        Device(
            deviceCode: "F7B455B6", deviceType: "cargo_freighter", replicantCode: "R1",
            status: "idle", location: "ACHERNUR-BELT-1", locationName: nil,
            operationalCapacity: 100, queueSize: 0, stowedInDeviceCode: nil,
            controllerDeviceCode: "8D53C9B1", attachedToDeviceCode: nil,
            createdAt: Date(timeIntervalSince1970: 0),
            availableCommands: [], features: [], tags: [],
            detail: .object([
                "cargo": .array(cargo.map { entry in
                    .object([
                        "resource_type": .string(entry.0),
                        "quantity": .number(Double(entry.1)),
                    ])
                })
            ]),
            updatedAt: Date(timeIntervalSince1970: 100),
            firstSeenAt: Date(timeIntervalSince1970: 0)
        )
    }

    private func seedDirectiveAndBaseline(_ database: any DatabaseWriter) async throws {
        try await database.write { db in
            try Directive.upsert {
                Directive(
                    id: "D1", kind: .haulRun, status: .running,
                    deviceCode: "8D53C9B1", fleetTag: "auto:mine:ACHERNUR-BELT-1",
                    targets: ["ACHERNUR-BELT-1"], targetIndex: 0, step: "hauling",
                    stepStartedAt: Date(timeIntervalSince1970: 0),
                    returnToOrigin: false, originDesignation: nil, attentionReason: nil,
                    createdAt: Date(timeIntervalSince1970: 0),
                    updatedAt: Date(timeIntervalSince1970: 0)
                )
            }
            .execute(db)
            // One CLOSED row: it gives the controller a history (so the machine
            // decides rather than seeds) with an open total of zero.
            try HaulYield.upsert {
                HaulYield(
                    id: self.testUUID(9), directiveID: "D1", controllerCode: "8D53C9B1",
                    deviceCode: "F7B455B6", sourceDesignation: "SEED",
                    collectedAt: Date(timeIntervalSince1970: 0), unitsCollected: 10,
                    perType: ResourceCost(), breakdownState: .exact,
                    destinationDesignation: "AINALRAM-BELT-1",
                    deliveredAt: Date(timeIntervalSince1970: 1), unitsDelivered: 10
                )
            }
            .execute(db)
            // The controller's single freighter — the count the two-freighter
            // degradation check reads.
            try Device.upsert { self.freighter(cargo: []) }.execute(db)
        }
    }

    @Test func aRiseWritesAPickupWithItsBreakdown() async throws {
        let database = try GameDatabase.bootstrap()
        try await seedDirectiveAndBaseline(database)
        let ingestion = LogisticsIngestion()

        try await withDependencies {
            $0.defaultDatabase = database
            $0.uuid = .incrementing
            $0.date = .constant(Date(timeIntervalSince1970: 100))
            $0.deviceRefresher = DeviceRefreshClient { code, priority in
                #expect(code == "F7B455B6")
                #expect(priority == .high)
                return self.freighter(cargo: [("structural", 200), ("rares", 145)])
            }
        } operation: {
            await ingestion.eventRoutes[0].apply(digestEvent(carried: 345, collected: 1))
        }

        let rows = try await database.read { db in
            try HaulYield.where { $0.sourceDesignation.eq("ACHERNUR-BELT-1") }.fetchAll(db)
        }
        #expect(rows.count == 1)
        #expect(rows[0].unitsCollected == 345)
        #expect(rows[0].perType == ResourceCost(structural: 200, rares: 145))
        #expect(rows[0].breakdownState == .exact)
        #expect(rows[0].directiveID == "D1")
        #expect(rows[0].isOpen)
    }

    @Test func aFailedDeviceReadStillRecordsTheTotal() async throws {
        let database = try GameDatabase.bootstrap()
        try await seedDirectiveAndBaseline(database)
        let ingestion = LogisticsIngestion()

        try await withDependencies {
            $0.defaultDatabase = database
            $0.uuid = .incrementing
            $0.date = .constant(Date(timeIntervalSince1970: 100))
            $0.deviceRefresher = DeviceRefreshClient { _, _ in nil }
        } operation: {
            await ingestion.eventRoutes[0].apply(digestEvent(carried: 345, collected: 1))
        }

        let rows = try await database.read { db in
            try HaulYield.where { $0.sourceDesignation.eq("ACHERNUR-BELT-1") }.fetchAll(db)
        }
        #expect(rows[0].unitsCollected == 345)
        #expect(rows[0].breakdownState == .unavailable)
        #expect(rows[0].perType == ResourceCost())
    }

    @Test func aSumThatDisagreesWithTheDeltaIsPartial() async throws {
        let database = try GameDatabase.bootstrap()
        try await seedDirectiveAndBaseline(database)
        let ingestion = LogisticsIngestion()

        try await withDependencies {
            $0.defaultDatabase = database
            $0.uuid = .incrementing
            $0.date = .constant(Date(timeIntervalSince1970: 100))
            $0.deviceRefresher = DeviceRefreshClient { _, _ in
                self.freighter(cargo: [("structural", 11)])
            }
        } operation: {
            await ingestion.eventRoutes[0].apply(digestEvent(carried: 345, collected: 1))
        }

        let rows = try await database.read { db in
            try HaulYield.where { $0.sourceDesignation.eq("ACHERNUR-BELT-1") }.fetchAll(db)
        }
        #expect(rows[0].unitsCollected == 345)
        #expect(rows[0].breakdownState == .partial)
    }

    @Test func aFallClosesEveryOpenRow() async throws {
        let database = try GameDatabase.bootstrap()
        try await seedDirectiveAndBaseline(database)
        try await database.write { db in
            for (index, units) in [(0, 400), (1, 100)] {
                try HaulYield.upsert {
                    HaulYield(
                        id: testUUID(100 + index), directiveID: "D1", controllerCode: "8D53C9B1",
                        deviceCode: "F7B455B6", sourceDesignation: "ACHERNUR-BELT-1",
                        collectedAt: Date(timeIntervalSince1970: TimeInterval(index)),
                        unitsCollected: units, perType: ResourceCost(), breakdownState: .exact
                    )
                }
                .execute(db)
            }
        }
        let ingestion = LogisticsIngestion()

        try await withDependencies {
            $0.defaultDatabase = database
            $0.uuid = .incrementing
            $0.date = .constant(Date(timeIntervalSince1970: 200))
            $0.deviceRefresher = DeviceRefreshClient { _, _ in nil }
        } operation: {
            await ingestion.eventRoutes[0].apply(digestEvent(carried: 0, delivered: 1))
        }

        let open = try await database.read { db in
            try HaulYield.where { $0.deliveredAt.isNot(nil).not() }.fetchAll(db)
        }
        #expect(open.isEmpty)
    }

    @Test func aSecondFreighterOnOneControllerDegradesToPartial() async throws {
        let database = try GameDatabase.bootstrap()
        try await seedDirectiveAndBaseline(database)
        try await database.write { db in
            var second = self.freighter(cargo: [])
            second.deviceCode = "AAAA1111"
            try Device.upsert { second }.execute(db)
        }
        let ingestion = LogisticsIngestion()

        try await withDependencies {
            $0.defaultDatabase = database
            $0.uuid = .incrementing
            $0.date = .constant(Date(timeIntervalSince1970: 100))
            $0.deviceRefresher = DeviceRefreshClient { _, _ in
                self.freighter(cargo: [("structural", 200), ("rares", 145)])
            }
        } operation: {
            await ingestion.eventRoutes[0].apply(digestEvent(carried: 345, collected: 1))
        }

        let rows = try await database.read { db in
            try HaulYield.where { $0.sourceDesignation.eq("ACHERNUR-BELT-1") }.fetchAll(db)
        }
        // The per-type sum matches the delta exactly, and it is STILL partial —
        // a matching sum proves nothing once two holds feed one figure.
        #expect(rows[0].perType.total == 345)
        #expect(rows[0].breakdownState == .partial)
    }

    @Test func theRowAfterAReconnectCarriesTheGapFlag() async throws {
        let database = try GameDatabase.bootstrap()
        try await seedDirectiveAndBaseline(database)
        let ingestion = LogisticsIngestion()

        try await withDependencies {
            $0.defaultDatabase = database
            $0.uuid = .incrementing
            $0.date = .constant(Date(timeIntervalSince1970: 100))
            $0.deviceRefresher = DeviceRefreshClient { _, _ in nil }
        } operation: {
            await ingestion.eventRoutes[0].gapRepair()
            await ingestion.eventRoutes[0].apply(digestEvent(carried: 345, collected: 1))
            await ingestion.eventRoutes[0].apply(digestEvent(carried: 500, collected: 1))
        }

        let rows = try await database.read { db in
            try HaulYield.where { $0.sourceDesignation.eq("ACHERNUR-BELT-1") }
                .order { $0.collectedAt }
                .fetchAll(db)
        }
        #expect(rows.count == 2)
        #expect(rows[0].followsGap)
        #expect(!rows[1].followsGap)
    }
}
