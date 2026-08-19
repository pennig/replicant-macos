//
//  HaulYieldDigest.swift
//  Replicould — Logistics feature
//
//  The ledger screen's one read: four statements that fold a time window in
//  SQLite and hand back a `YieldSummary`. What it returns is fixed in size
//  however large the window grows — see `.claude/memory/`'s
//  logistics-window-aggregation note for why the fold cannot live in Swift.
//

import Foundation
import GameModels
import SQLiteData

struct HaulYieldDigest: FetchKeyRequest {
    typealias Value = YieldSummary

    /// How many ledger rows the table lists. The charts are not bound by this
    /// — `YieldSummary.tripCount` counts the whole window, and the table says
    /// how many trips it is not showing.
    static let tableRowLimit = 100

    /// Oldest `collectedAt` the window admits; nil is "All".
    let cutoff: Date?
    let rowLimit: Int

    init(cutoff: Date?, rowLimit: Int = HaulYieldDigest.tableRowLimit) {
        self.cutoff = cutoff
        self.rowLimit = rowLimit
    }

    init(
        range: LogisticsFeature.TimeRange,
        now: Date,
        rowLimit: Int = HaulYieldDigest.tableRowLimit
    ) {
        self.init(
            cutoff: range.days.map { now.addingTimeInterval(-Double($0) * 86_400) },
            rowLimit: rowLimit
        )
    }

    func fetch(_ db: Database) throws -> YieldSummary {
        var summary = YieldSummary()

        if let totals = try #sql(
            """
            SELECT COUNT(*), \
            COALESCE(SUM(\(HaulYield.unitsCollected)), 0), \
            COALESCE(SUM(\(HaulYield.followsGap)), 0), \
            MIN(\(HaulYield.collectedAt)), \
            MAX(\(HaulYield.collectedAt)), \
            \(Self.resourceSums) \
            FROM \(HaulYield.self)\(window)
            """,
            as: TotalsRow.self
        )
        .fetchOne(db) {
            summary.totalUnits = totals.totalUnits
            summary.tripCount = totals.tripCount
            summary.gapCount = totals.gapCount
            summary.byResource = ResourceCost.displayOrder.map {
                YieldSummary.ResourceTotal(key: $0.key, units: totals.perType.amount(for: $0.key))
            }
            summary.unitsPerDay = YieldSummary.unitsPerDay(
                totalUnits: totals.totalUnits,
                first: totals.firstCollectedAt,
                last: totals.lastCollectedAt
            )
        }

        // Units descending, then designation ascending — the same tie-break the
        // breakdown chart used when it sorted in Swift.
        summary.bySource = try #sql(
            """
            SELECT \(HaulYield.sourceDesignation), \
            COALESCE(SUM(\(HaulYield.unitsCollected)), 0) AS "units" \
            FROM \(HaulYield.self)\(window) \
            GROUP BY \(HaulYield.sourceDesignation) \
            ORDER BY "units" DESC, \(HaulYield.sourceDesignation) ASC
            """,
            as: SourceRow.self
        )
        .fetchAll(db)
        .map { YieldSummary.SourceTotal(designation: $0.designation, units: $0.units) }

        // 'localtime' so a day boundary means the operator's midnight, matching
        // the `Calendar.current.startOfDay` bucketing this replaced. Dates are
        // stored as UTC text, so grouping without it files every trip made
        // after local midnight under the following day.
        let dayRows = try #sql(
            """
            SELECT date(\(HaulYield.collectedAt), 'localtime') AS "day", \
            \(Self.resourceSums) \
            FROM \(HaulYield.self)\(window) \
            GROUP BY "day" ORDER BY "day" ASC
            """,
            as: DayRow.self
        )
        .fetchAll(db)
        let parser = Self.dayParser()
        summary.byDay = dayRows.compactMap { row in
            parser.date(from: row.day).map { YieldSummary.DayTotal(day: $0, perType: row.perType) }
        }

        if let cutoff {
            summary.rows = try HaulYield
                .where { $0.collectedAt >= cutoff }
                .order { $0.collectedAt.desc() }
                .limit(rowLimit)
                .fetchAll(db)
        } else {
            summary.rows = try HaulYield
                .order { $0.collectedAt.desc() }
                .limit(rowLimit)
                .fetchAll(db)
        }

        return summary
    }

    /// The window clause, empty for "All" — one definition, three statements.
    private var window: QueryFragment {
        guard let cutoff else { return "" }
        return " WHERE \(HaulYield.collectedAt) >= \(bind: cutoff)"
    }

    /// The six per-resource sums, in the order `TotalsRow`/`DayRow` decode
    /// them positionally — a transposed pair here swaps two resources silently.
    private static let resourceSums: QueryFragment = """
        COALESCE(SUM(json_extract(\(HaulYield.perType), '$.structural')), 0), \
        COALESCE(SUM(json_extract(\(HaulYield.perType), '$.conductive')), 0), \
        COALESCE(SUM(json_extract(\(HaulYield.perType), '$.silicates')), 0), \
        COALESCE(SUM(json_extract(\(HaulYield.perType), '$.carbon')), 0), \
        COALESCE(SUM(json_extract(\(HaulYield.perType), '$.rares')), 0), \
        COALESCE(SUM(json_extract(\(HaulYield.perType), '$.volatiles')), 0)
        """

    /// `date(…, 'localtime')` yields a local calendar day; parsing it back in
    /// the current time zone lands on that day's local midnight.
    private static func dayParser() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        return formatter
    }
}

// MARK: - Projections

@Selection
struct TotalsRow {
    let tripCount: Int
    let totalUnits: Int
    let gapCount: Int
    let firstCollectedAt: Date?
    let lastCollectedAt: Date?
    let structural: Int
    let conductive: Int
    let silicates: Int
    let carbon: Int
    let rares: Int
    let volatiles: Int

    var perType: ResourceCost {
        ResourceCost(
            carbon: carbon, silicates: silicates, structural: structural,
            rares: rares, conductive: conductive, volatiles: volatiles
        )
    }
}

@Selection
struct SourceRow {
    let designation: String
    let units: Int
}

@Selection
struct DayRow {
    let day: String
    let structural: Int
    let conductive: Int
    let silicates: Int
    let carbon: Int
    let rares: Int
    let volatiles: Int

    var perType: ResourceCost {
        ResourceCost(
            carbon: carbon, silicates: silicates, structural: structural,
            rares: rares, conductive: conductive, volatiles: volatiles
        )
    }
}
