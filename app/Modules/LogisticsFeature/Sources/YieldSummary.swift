//
//  YieldSummary.swift
//  Replicould — Logistics feature
//
//  Every figure the screen shows, folded from the ledger rows in one pass.
//

import Foundation
import GameModels

struct YieldSummary {
    let totalUnits: Int
    let tripCount: Int
    let unitsPerDay: Double
    let byResource: [(key: String, units: Int)]
    let bySource: [(designation: String, units: Int)]
    let byDay: [(day: Date, perType: ResourceCost)]
    let gapCount: Int

    init(yields: [HaulYield], range: LogisticsFeature.TimeRange, now: Date, calendar: Calendar = .current) {
        let cutoff = range.days.map { now.addingTimeInterval(-Double($0) * 86_400) }
        let rows = cutoff.map { limit in yields.filter { $0.collectedAt >= limit } } ?? yields

        totalUnits = rows.reduce(0) { $0 + $1.unitsCollected }
        tripCount = rows.count
        gapCount = rows.count(where: \.followsGap)

        let summed = rows.reduce(into: ResourceCost()) { $0.add($1.perType) }
        byResource = ResourceCost.displayOrder.map { ($0.key, summed.amount(for: $0.key)) }

        var sources: [String: Int] = [:]
        for row in rows { sources[row.sourceDesignation, default: 0] += row.unitsCollected }
        bySource = sources
            .map { (designation: $0.key, units: $0.value) }
            .sorted { lhs, rhs in
                lhs.units == rhs.units ? lhs.designation < rhs.designation : lhs.units > rhs.units
            }

        var days: [Date: ResourceCost] = [:]
        for row in rows {
            days[calendar.startOfDay(for: row.collectedAt), default: ResourceCost()].add(row.perType)
        }
        byDay = days.map { (day: $0.key, perType: $0.value) }.sorted { $0.day < $1.day }

        // Span the observed window, never the requested range: a 30-day filter
        // over two days of data must not divide by 30.
        let span: Double
        if let first = rows.map(\.collectedAt).min(), let last = rows.map(\.collectedAt).max() {
            span = Swift.max(1, last.timeIntervalSince(first) / 86_400)
        } else {
            span = 1
        }
        unitsPerDay = Double(totalUnits) / span
    }
}
