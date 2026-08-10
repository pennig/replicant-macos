import Foundation
import GameModels
import Testing
@testable import LogisticsFeature

// House idiom (see LogisticsFeatureTests): there is no `UUID(Int)` in this
// package's dependencies, so deterministic test IDs go through a string.
private func testUUID(_ n: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012X", n))!
}

@Suite struct YieldSummaryTests {
    private func yield(
        day: Int, units: Int, cost: ResourceCost, source: String = "A-1",
        state: HaulYield.BreakdownState = .exact, followsGap: Bool = false
    ) -> HaulYield {
        HaulYield(
            id: testUUID(day), directiveID: "D", controllerCode: "C", deviceCode: "F",
            sourceDesignation: source,
            collectedAt: Date(timeIntervalSince1970: TimeInterval(day) * 86_400),
            unitsCollected: units, perType: cost, breakdownState: state,
            followsGap: followsGap
        )
    }

    // The unavailable row's unitsCollected (100) and perType.total (0) disagree,
    // so summing perType.total instead of unitsCollected would total 200, not 300.
    @Test func itTotalsUnitsAndTrips() {
        let summary = YieldSummary(
            yields: [
                yield(day: 0, units: 100, cost: ResourceCost(), state: .unavailable),
                yield(day: 1, units: 200, cost: ResourceCost(rares: 200)),
            ],
            range: .all,
            now: Date(timeIntervalSince1970: 86_400)
        )
        #expect(summary.totalUnits == 300)
        #expect(summary.tripCount == 2)
    }

    // MID-1 wins on units alone while sitting 2nd by insertion, alphabetically
    // between the other two, and on the middle day — so only units sorts it first.
    @Test func itRanksSourcesByUnitsDescending() {
        let summary = YieldSummary(
            yields: [
                yield(day: 0, units: 10, cost: ResourceCost(), source: "ALPHA-1"),
                yield(day: 1, units: 900, cost: ResourceCost(), source: "MID-1"),
                yield(day: 2, units: 50, cost: ResourceCost(), source: "ZULU-1"),
            ],
            range: .all,
            now: Date(timeIntervalSince1970: 2 * 86_400)
        )
        #expect(summary.bySource.first?.designation == "MID-1")
    }

    // Both rows carry rares, so the 200 expected here is only reachable by
    // accumulating (50 + 150) — neither row alone is 200.
    @Test func resourceTotalsKeepDisplayOrder() {
        let summary = YieldSummary(
            yields: [
                yield(day: 0, units: 110, cost: ResourceCost(structural: 60, rares: 50)),
                yield(day: 1, units: 190, cost: ResourceCost(structural: 40, rares: 150)),
            ],
            range: .all,
            now: Date(timeIntervalSince1970: 86_400)
        )
        #expect(summary.byResource.map(\.key) == ResourceCost.displayOrder.map(\.key))
        #expect(summary.byResource.first { $0.key == "rares" }?.units == 200)
    }

    // Day 9 is one day outside the 30-day cutoff, day 10 lands exactly on it
    // (kept via `>=`) — an off-by-a-day cutoff or a `>`/`>=` slip moves 1,100.
    @Test func theRangeExcludesOlderRows() {
        let summary = YieldSummary(
            yields: [
                yield(day: 0, units: 1, cost: ResourceCost(structural: 1)),
                yield(day: 9, units: 10, cost: ResourceCost(structural: 10)),
                yield(day: 10, units: 100, cost: ResourceCost(structural: 100)),
                yield(day: 40, units: 1_000, cost: ResourceCost(structural: 1_000)),
            ],
            range: .month,
            now: Date(timeIntervalSince1970: 40 * 86_400)
        )
        #expect(summary.totalUnits == 1_100)
    }

    // 1 gapped vs 2 clean rows: `gapCount == tripCount` and an inverted
    // `followsGap` predicate both diverge from the correct answer here.
    @Test func gapsAreCountedSoTheChartCanSayItDoesNotKnow() {
        let summary = YieldSummary(
            yields: [
                yield(day: 0, units: 100, cost: ResourceCost(), followsGap: true),
                yield(day: 1, units: 50, cost: ResourceCost(), followsGap: false),
                yield(day: 2, units: 25, cost: ResourceCost(), followsGap: false),
            ],
            range: .all,
            now: Date(timeIntervalSince1970: 2 * 86_400)
        )
        #expect(summary.gapCount == 1)
    }
}
