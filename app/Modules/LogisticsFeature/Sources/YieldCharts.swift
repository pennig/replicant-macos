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

    /// How many sources a folded breakdown shows before the remainder bar.
    static let sourceCap = 8

    /// The first `cap` sources plus one aggregate remainder bar, in input order.
    /// At `cap + 1` or fewer the input returns unfolded — an "All Others (1)"
    /// bucket is worse than the row it hides.
    static func foldedSources(
        _ sources: [(designation: String, units: Int)], cap: Int = YieldChartMath.sourceCap
    ) -> [(label: String, units: Int, isAggregate: Bool)] {
        let unfolded = sources.map { (label: $0.designation, units: $0.units, isAggregate: false) }
        guard sources.count > cap + 1 else { return unfolded }
        let remainder = sources.dropFirst(cap)
        return unfolded.prefix(cap) + [(
            label: "All Others (\(remainder.count))",
            units: remainder.reduce(0) { $0 + $1.units },
            isAggregate: true
        )]
    }

    /// Keys of slices holding at least `minShare` of the total — the only ones
    /// direct-labelled; two palette slots need the label as their contrast relief.
    static func labelledResourceKeys(
        _ rows: [(key: String, units: Int)], minShare: Double = 0.1
    ) -> Set<String> {
        let total = rows.reduce(0) { $0 + $1.units }
        guard total > 0 else { return [] }
        return Set(rows.filter { Double($0.units) / Double(total) >= minShare }.map(\.key))
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
    let sources: [(designation: String, units: Int)]
    @Binding var showAll: Bool

    var body: some View {
        let filtered = sources.filter { $0.units > 0 }
        let folded = YieldChartMath.foldedSources(filtered)
        // A range change can drop the source count below the fold threshold
        // while `showAll` is still set, so expansion is gated on both.
        let expanded = showAll && folded.last?.isAggregate == true
        let rows = expanded
            ? filtered.map { (label: $0.designation, units: $0.units, isAggregate: false) }
            : folded
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.s) {
                Text(title).font(.rcSectionLabel).foregroundStyle(.rcTextSecondary)
                if folded.last?.isAggregate == true {
                    Button(expanded ? "Show top \(YieldChartMath.sourceCap)" : "Show all \(filtered.count)") {
                        showAll.toggle()
                    }
                    .buttonStyle(.plain)
                    .font(.rcCaption)
                    .foregroundStyle(.rcTextSecondary)
                }
            }
            let height = CGFloat(rows.count) * ChartSize.breakdownRow
            if expanded {
                ScrollView { chart(rows).frame(height: height) }
                    .frame(maxHeight: ChartSize.breakdownMax)
            } else {
                chart(rows).frame(height: max(height, ChartSize.breakdown))
            }
        }
    }

    private func chart(_ rows: [(label: String, units: Int, isAggregate: Bool)]) -> some View {
        Chart(rows, id: \.label) { row in
            BarMark(
                x: .value("Units", row.units),
                y: .value("Label", row.label)
            )
            // The remainder bar reads as "everything else", not another source.
            .foregroundStyle(row.isAggregate ? Color.rcTextTertiary : Color.rcAccent)
            .cornerRadius(Radius.textBadge)
            .annotation(position: .trailing) {
                Text("\(row.units)").font(.rcMonoSmall).foregroundStyle(.rcTextSecondary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisValueLabel {
                    if let label = value.as(String.self) {
                        Text(label).font(.rcMonoSmall).foregroundStyle(.rcTextSecondary)
                    }
                }
            }
        }
        .chartXAxis(.hidden)
    }
}

struct ResourceDonutChart: View {
    let title: String
    /// `ResourceCost.displayOrder` order — palette-validated for ring adjacency.
    let rows: [(key: String, units: Int)]

    var body: some View {
        let filtered = rows.filter { $0.units > 0 }
        let labelled = YieldChartMath.labelledResourceKeys(filtered)
        let total = filtered.reduce(0) { $0 + $1.units }
        VStack(alignment: .leading, spacing: Space.s) {
            Text(title).font(.rcSectionLabel).foregroundStyle(.rcTextSecondary)
            Chart(filtered, id: \.key) { row in
                SectorMark(
                    angle: .value("Units", row.units),
                    innerRadius: .ratio(0.62),
                    angularInset: 1.5
                )
                .cornerRadius(Radius.textBadge)
                .foregroundStyle(by: .value("Resource", row.key))
                .annotation(position: .overlay) {
                    if labelled.contains(row.key) {
                        Text("\(row.units)").font(.rcMicroMono).foregroundStyle(.rcTextPrimary)
                    }
                }
            }
            .chartForegroundStyleScale(
                domain: ResourceCost.displayOrder.map(\.key),
                range: ResourceCost.displayOrder.map { Color.rcResource($0.key) }
            )
            .chartLegend(position: .bottom)
            .chartBackground { proxy in
                GeometryReader { geometry in
                    if let plot = proxy.plotFrame {
                        let frame = geometry[plot]
                        VStack(spacing: 0) {
                            Text("\(total)").font(.rcHeadline).monospacedDigit()
                            Text("units").font(.rcCaption).foregroundStyle(.rcTextSecondary)
                        }
                        .position(x: frame.midX, y: frame.midY)
                    }
                }
            }
            .frame(minHeight: ChartSize.breakdown)
        }
    }
}
