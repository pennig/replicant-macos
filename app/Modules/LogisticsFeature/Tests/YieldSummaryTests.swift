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
    private func yield(day: Int, units: Int, cost: ResourceCost, source: String = "A-1", followsGap: Bool = false) -> HaulYield {
        HaulYield(
            id: testUUID(day), directiveID: "D", controllerCode: "C", deviceCode: "F",
            sourceDesignation: source,
            collectedAt: Date(timeIntervalSince1970: TimeInterval(day) * 86_400),
            unitsCollected: units, perType: cost, breakdownState: .exact,
            followsGap: followsGap
        )
    }

    @Test func itTotalsUnitsAndTrips() {
        let summary = YieldSummary(
            yields: [
                yield(day: 0, units: 100, cost: ResourceCost(structural: 100)),
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

    @Test func resourceTotalsKeepDisplayOrder() {
        let summary = YieldSummary(
            yields: [yield(day: 0, units: 300, cost: ResourceCost(structural: 100, rares: 200))],
            range: .all,
            now: Date(timeIntervalSince1970: 0)
        )
        #expect(summary.byResource.map(\.key) == ResourceCost.displayOrder.map(\.key))
        #expect(summary.byResource.first { $0.key == "rares" }?.units == 200)
    }

    @Test func theRangeExcludesOlderRows() {
        let summary = YieldSummary(
            yields: [
                yield(day: 0, units: 100, cost: ResourceCost()),
                yield(day: 40, units: 500, cost: ResourceCost()),
            ],
            range: .month,
            now: Date(timeIntervalSince1970: 40 * 86_400)
        )
        #expect(summary.totalUnits == 500)
    }

    // A second, non-gapped row rules out a `gapCount == tripCount` bug —
    // with one row of each kind, that confound would also read 1.
    @Test func gapsAreCountedSoTheChartCanSayItDoesNotKnow() {
        let summary = YieldSummary(
            yields: [
                yield(day: 0, units: 100, cost: ResourceCost(), followsGap: true),
                yield(day: 1, units: 50, cost: ResourceCost(), followsGap: false),
            ],
            range: .all,
            now: Date(timeIntervalSince1970: 86_400)
        )
        #expect(summary.gapCount == 1)
    }
}
