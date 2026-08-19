import Foundation
import GameDatabase
import GameModels
import SQLiteData
import Testing
@testable import LogisticsFeature

// House idiom (see LogisticsFeatureTests): there is no `UUID(Int)` in this
// package's dependencies, so deterministic test IDs go through a string.
private func testUUID(_ n: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012X", n))!
}

/// The digest folds in SQLite now, so every expectation here goes through a
/// real database rather than a Swift initializer.
@Suite struct YieldSummaryTests {
    private func yield(
        id: Int, at: Date, units: Int, cost: ResourceCost = ResourceCost(),
        source: String = "A-1", state: HaulYield.BreakdownState = .exact,
        followsGap: Bool = false
    ) -> HaulYield {
        HaulYield(
            id: testUUID(id), directiveID: "D", controllerCode: "C", deviceCode: "F",
            sourceDesignation: source, collectedAt: at, unitsCollected: units,
            perType: cost, breakdownState: state, followsGap: followsGap
        )
    }

    private func day(_ n: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(n) * 86_400) }

    private func summary(
        of rows: [HaulYield],
        range: LogisticsFeature.TimeRange = .all,
        now: Date = Date(timeIntervalSince1970: 0),
        rowLimit: Int = HaulYieldDigest.tableRowLimit
    ) async throws -> YieldSummary {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            for row in rows { try HaulYield.upsert { row }.execute(db) }
        }
        return try await database.read { db in
            try HaulYieldDigest(range: range, now: now, rowLimit: rowLimit).fetch(db)
        }
    }

    // The unavailable row's unitsCollected (100) and perType.total (0) disagree,
    // so summing perType.total instead of unitsCollected would total 200, not 300.
    @Test func itTotalsUnitsAndTrips() async throws {
        let summary = try await summary(of: [
            yield(id: 0, at: day(0), units: 100, state: .unavailable),
            yield(id: 1, at: day(1), units: 200, cost: ResourceCost(rares: 200)),
        ])
        #expect(summary.totalUnits == 300)
        #expect(summary.tripCount == 2)
    }

    // MID-1 wins on units alone while sitting 2nd by insertion, alphabetically
    // between the other two, and on the middle day — so only units sorts it first.
    @Test func itRanksSourcesByUnitsDescending() async throws {
        let summary = try await summary(of: [
            yield(id: 0, at: day(0), units: 10, source: "ALPHA-1"),
            yield(id: 1, at: day(1), units: 900, source: "MID-1"),
            yield(id: 2, at: day(2), units: 50, source: "ZULU-1"),
        ])
        #expect(summary.bySource.map(\.designation) == ["MID-1", "ZULU-1", "ALPHA-1"])
    }

    // Both rows carry rares, so the 200 expected here is only reachable by
    // accumulating (50 + 150) — neither row alone is 200.
    @Test func resourceTotalsKeepDisplayOrder() async throws {
        let summary = try await summary(of: [
            yield(id: 0, at: day(0), units: 110, cost: ResourceCost(structural: 60, rares: 50)),
            yield(id: 1, at: day(1), units: 190, cost: ResourceCost(structural: 40, rares: 150)),
        ])
        #expect(summary.byResource.map(\.key) == ResourceCost.displayOrder.map(\.key))
        #expect(summary.byResource.first { $0.key == "rares" }?.units == 200)
    }

    // The six `json_extract` sums are positional, so a transposed pair in the
    // SQL would swap two resources silently. Six distinct values, one row: any
    // permutation of the projection fails this.
    @Test func theSixResourceSumsDecodeOntoTheirOwnResource() async throws {
        let cost = ResourceCost(
            carbon: 4, silicates: 3, structural: 1, rares: 5, conductive: 2, volatiles: 6
        )
        let summary = try await summary(of: [yield(id: 0, at: day(0), units: 21, cost: cost)])
        let units = Dictionary(
            uniqueKeysWithValues: summary.byResource.map { ($0.key, $0.units) }
        )
        #expect(units == [
            "structural": 1, "conductive": 2, "silicates": 3,
            "carbon": 4, "rares": 5, "volatiles": 6,
        ])
    }

    // Day 9 is one day outside the 30-day cutoff, day 10 lands exactly on it
    // (kept via `>=`) — an off-by-a-day cutoff or a `>`/`>=` slip moves 1,100.
    @Test func theRangeExcludesOlderRows() async throws {
        let summary = try await summary(
            of: [
                yield(id: 0, at: day(0), units: 1, cost: ResourceCost(structural: 1)),
                yield(id: 1, at: day(9), units: 10, cost: ResourceCost(structural: 10)),
                yield(id: 2, at: day(10), units: 100, cost: ResourceCost(structural: 100)),
                yield(id: 3, at: day(40), units: 1_000, cost: ResourceCost(structural: 1_000)),
            ],
            range: .month,
            now: day(40)
        )
        #expect(summary.totalUnits == 1_100)
    }

    // −23h sits inside the 24h window and −25h outside; the `>=` cutoff keeps
    // exactly the two in-window rows (1 + 10) and drops the 100.
    @Test func theDayRangeKeepsOnlyTheLastTwentyFourHours() async throws {
        let now = day(40)
        let at = { (hoursAgo: Int) in now.addingTimeInterval(-TimeInterval(hoursAgo) * 3_600) }
        let summary = try await summary(
            of: [
                yield(id: 1, at: at(1), units: 1),
                yield(id: 2, at: at(23), units: 10),
                yield(id: 3, at: at(25), units: 100),
            ],
            range: .day,
            now: now
        )
        #expect(summary.totalUnits == 11)
        #expect(summary.tripCount == 2)
    }

    // 1 gapped vs 2 clean rows: `gapCount == tripCount` and an inverted
    // `followsGap` predicate both diverge from the correct answer here.
    @Test func gapsAreCountedSoTheChartCanSayItDoesNotKnow() async throws {
        let summary = try await summary(of: [
            yield(id: 0, at: day(0), units: 100, followsGap: true),
            yield(id: 1, at: day(1), units: 50),
            yield(id: 2, at: day(2), units: 25),
        ])
        #expect(summary.gapCount == 1)
    }

    // Two days of data under a 30-day filter: dividing by the requested range
    // would report 50/day, and dividing by trips 1,500.
    @Test func unitsPerDaySpansTheObservedWindowNotTheRequestedOne() async throws {
        let summary = try await summary(
            of: [
                yield(id: 0, at: day(38), units: 1_000),
                yield(id: 1, at: day(40), units: 2_000),
            ],
            range: .month,
            now: day(40)
        )
        #expect(summary.unitsPerDay == 1_500)
    }

    // Three trips, two local days — the over-time chart's stack. Grouping in UTC
    // instead of local time splits or merges days for any non-UTC operator.
    @Test func daysBucketByLocalMidnight() async throws {
        let calendar = Calendar.current
        let noon = calendar.startOfDay(for: Date(timeIntervalSince1970: 40 * 86_400))
            .addingTimeInterval(12 * 3_600)
        let summary = try await summary(
            of: [
                yield(id: 0, at: noon, units: 10, cost: ResourceCost(carbon: 10)),
                yield(id: 1, at: noon.addingTimeInterval(3_600), units: 5, cost: ResourceCost(carbon: 5)),
                yield(id: 2, at: noon.addingTimeInterval(86_400), units: 7, cost: ResourceCost(rares: 7)),
            ],
            now: noon.addingTimeInterval(2 * 86_400)
        )
        #expect(summary.byDay.map(\.day) == [
            calendar.startOfDay(for: noon),
            calendar.startOfDay(for: noon.addingTimeInterval(86_400)),
        ])
        #expect(summary.byDay.map(\.perType.carbon) == [15, 0])
        #expect(summary.byDay.map(\.perType.rares) == [0, 7])
    }

    @Test func anEmptyLedgerFoldsToZeroesRatherThanFailing() async throws {
        let summary = try await summary(of: [])
        #expect(summary.tripCount == 0)
        #expect(summary.totalUnits == 0)
        #expect(summary.unitsPerDay == 0)
        #expect(summary.byDay.isEmpty)
        #expect(summary.bySource.isEmpty)
        #expect(summary.rows.isEmpty)
    }
}
