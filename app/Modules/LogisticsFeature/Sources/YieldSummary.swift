//
//  YieldSummary.swift
//  Replicould — Logistics feature
//
//  Every figure the screen shows, folded from the ledger by SQLite rather than
//  by Swift — see `HaulYieldDigest`, which is the only thing that builds one.
//
//  The split is the point of the type: every figure but `rows` covers the
//  WHOLE window, and `rows` is a display slice the ledger table alone reads.
//  A table bound must never become a chart bound.
//

import Foundation
import GameModels

struct YieldSummary: Equatable, Sendable {
    /// One resource's units across the window, in `ResourceCost.displayOrder`.
    struct ResourceTotal: Equatable, Sendable, Identifiable {
        let key: String
        let units: Int
        var id: String { key }
    }

    /// One source's units across the window, ranked by units descending.
    struct SourceTotal: Equatable, Sendable, Identifiable {
        let designation: String
        let units: Int
        var id: String { designation }
    }

    /// One local day's composition — the over-time chart's stack.
    struct DayTotal: Equatable, Sendable, Identifiable {
        let day: Date
        let perType: ResourceCost
        var id: Date { day }
    }

    var totalUnits: Int = 0
    var tripCount: Int = 0
    var gapCount: Int = 0
    var unitsPerDay: Double = 0
    var byResource: [ResourceTotal] = []
    var bySource: [SourceTotal] = []
    var byDay: [DayTotal] = []
    /// The newest trips in the window, capped at `HaulYieldDigest.tableRowLimit`
    /// — the ledger table's rows. `tripCount` is the honest count; this is not.
    var rows: [HaulYield] = []

    /// In-window trips the table does not list, for its "n more" line.
    var hiddenRowCount: Int { max(0, tripCount - rows.count) }

    /// Units per day over the *observed* span, never the requested range: a
    /// 30-day filter over two days of data must not divide by 30.
    static func unitsPerDay(totalUnits: Int, first: Date?, last: Date?) -> Double {
        guard let first, let last else { return Double(totalUnits) }
        let span = Swift.max(1, last.timeIntervalSince(first) / 86_400)
        return Double(totalUnits) / span
    }
}
