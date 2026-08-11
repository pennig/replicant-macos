//
//  YieldCharts.swift
//  Replicould — Logistics feature
//
//  Composition over time, and the two magnitude breakdowns.
//

import Charts
import GameModels
import SwiftUI
import UI

/// One stacked segment: a day, a resource, and its units.
struct YieldPoint: Identifiable, Equatable {
    let day: Date
    let key: String
    let units: Int
    /// Stable across reloads — the pair is unique within the series.
    var id: String { "\(day.timeIntervalSince1970)-\(key)" }
}

/// Pure chart math kept off the `View` — a static/nested member of a SwiftUI
/// `View` traps `swift test` (headless metadata realization), so this stays a
/// plain top-level namespace the views delegate to.
enum YieldChartMath {
    static func points(byDay: [(day: Date, perType: ResourceCost)]) -> [YieldPoint] {
        byDay.flatMap { entry in
            ResourceCost.displayOrder.compactMap { slot in
                let units = entry.perType.amount(for: slot.key)
                return units > 0 ? YieldPoint(day: entry.day, key: slot.key, units: units) : nil
            }
        }
    }

    /// The largest segment of each day — the only one direct-labelled. A
    /// number on every point is noise; none at all leaves the CVD gate unrelieved.
    static func labelledIDs(_ points: [YieldPoint]) -> Set<String> {
        Set(
            Dictionary(grouping: points, by: \.day)
                .compactMap { $0.value.max { $0.units < $1.units }?.id }
        )
    }
}

struct YieldOverTimeChart: View {
    let summary: YieldSummary

    private var points: [YieldPoint] { YieldChartMath.points(byDay: summary.byDay) }
    private var labelledIDs: Set<String> { YieldChartMath.labelledIDs(points) }

    var body: some View {
        Chart(points) { point in
            BarMark(
                x: .value("Day", point.day, unit: .day),
                y: .value("Units", point.units)
            )
            .foregroundStyle(by: .value("Resource", point.key))
            .cornerRadius(Radius.textBadge)
            .annotation(position: .overlay) {
                if labelledIDs.contains(point.id) {
                    Text("\(point.units)")
                        .font(.rcMicroMono)
                        .foregroundStyle(.rcTextPrimary)
                }
            }
        }
        .chartForegroundStyleScale(
            domain: ResourceCost.displayOrder.map(\.key),
            range: ResourceCost.displayOrder.map { Color.rcResource($0.key) }
        )
        .chartLegend(position: .bottom)
        .chartYAxis { AxisMarks(position: .leading) }
        .frame(minHeight: ChartSize.overTime)
        .overlay(alignment: .topTrailing) {
            if summary.gapCount > 0 {
                Text("\(summary.gapCount) gap\(summary.gapCount == 1 ? "" : "s") — unobserved, not empty")
                    .font(.rcCaption)
                    .foregroundStyle(.rcTextTertiary)
            }
        }
    }
}

struct YieldBreakdownChart: View {
    let title: String
    /// Sequential single hue: this compares magnitude, not identity.
    let rows: [(label: String, units: Int)]
    let monospacedLabels: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text(title).font(.rcSectionLabel).foregroundStyle(.rcTextSecondary)
            Chart(rows.filter { $0.units > 0 }, id: \.label) { row in
                BarMark(
                    x: .value("Units", row.units),
                    y: .value("Label", row.label)
                )
                .foregroundStyle(Color.rcAccent)
                .cornerRadius(Radius.textBadge)
                .annotation(position: .trailing) {
                    Text("\(row.units)").font(.rcMonoSmall).foregroundStyle(.rcTextSecondary)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisValueLabel {
                        if let label = value.as(String.self) {
                            Text(label).font(monospacedLabels ? .rcMonoSmall : .rcCaption)
                                .foregroundStyle(.rcTextSecondary)
                        }
                    }
                }
            }
            .chartXAxis(.hidden)
            .frame(minHeight: ChartSize.breakdown)
        }
    }
}
