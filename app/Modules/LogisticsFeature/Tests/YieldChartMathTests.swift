import Foundation
import GameModels
import Testing
@testable import LogisticsFeature

@Suite struct YieldChartMathTests {
    // Every nonzero field present, in insertion order that does NOT match
    // `displayOrder` — only an order derived from `displayOrder` itself
    // reproduces this sequence.
    @Test func pointsFollowDisplayOrderAndDropZeros() {
        let day = Date(timeIntervalSince1970: 0)
        let cost = ResourceCost(carbon: 0, silicates: 5, structural: 10, rares: 0, conductive: 20, volatiles: 0)
        let points = YieldChartMath.points(byDay: [(day: day, perType: cost)])
        #expect(points.map(\.key) == ["structural", "conductive", "silicates"])
        #expect(points.map(\.units) == [10, 20, 5])
    }

    @Test func pointIDsAreStableAndUniquePerDayResourcePair() {
        let day = Date(timeIntervalSince1970: 12_345)
        let cost = ResourceCost(structural: 1)
        let points = YieldChartMath.points(byDay: [(day: day, perType: cost)])
        #expect(points.first?.id == "12345.0-structural")
    }

    // Two days, each with a clearly distinct winner — catches an
    // implementation that finds one global maximum instead of one per day.
    @Test func labelsExactlyOneSegmentPerDay() {
        let dayA = Date(timeIntervalSince1970: 0)
        let dayB = Date(timeIntervalSince1970: 86_400)
        let points = YieldChartMath.points(byDay: [
            (day: dayA, perType: ResourceCost(structural: 100, rares: 10)),
            (day: dayB, perType: ResourceCost(structural: 5, rares: 200)),
        ])
        let labelled = YieldChartMath.labelledIDs(points)
        let labelledKeys = points.filter { labelled.contains($0.id) }.map(\.key).sorted()
        #expect(labelled.count == 2)
        #expect(labelledKeys == ["rares", "structural"])
    }

    // A tie must resolve toward `displayOrder`'s earlier entry (structural
    // before conductive) — flip the tiebreak and this fails.
    @Test func aTieBreaksTowardTheEarlierDisplayOrderSlot() {
        let day = Date(timeIntervalSince1970: 0)
        let points = YieldChartMath.points(byDay: [
            (day: day, perType: ResourceCost(structural: 50, conductive: 50)),
        ])
        let labelled = YieldChartMath.labelledIDs(points)
        #expect(labelled == [points.first { $0.key == "structural" }!.id])
    }

    @Test func aDayWithNoUnitsLabelsNothing() {
        let day = Date(timeIntervalSince1970: 0)
        let points = YieldChartMath.points(byDay: [(day: day, perType: ResourceCost())])
        #expect(points.isEmpty)
        #expect(YieldChartMath.labelledIDs(points).isEmpty)
    }
}
