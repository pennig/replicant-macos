//
//  ResourceRadar.swift
//  Replicould — Blueprints feature
//
//  The Print Cost and Print Time lockups for the blueprint inspector's cost/time
//  band, plus the six-axis radar chart at the heart of Print Cost. Each radar axis
//  is one resource category (in `ResourceCost.displayOrder`); the plotted radius is
//  a *logarithmic* fraction of that axis's maximum across all available blueprints,
//  so a cheap resource never looks maxed next to a 4,500-unit one and the
//  differences stay legible at a glance. Vertices carry the same periodic-table
//  abbreviation shown beside each category in the adjacent legend, tying every
//  point back to its row.
//

import GameModels
import SwiftUI
import UI

// MARK: - Geometry

/// Shared polar math so the grid shape, the data polygon, and the overlaid
/// vertex/index markers all agree on centre, radius, and axis angles.
private enum RadarMath {
    /// Room reserved around the plot for the abbreviation badges.
    static let inset: CGFloat = 20

    static func geometry(in size: CGSize) -> (center: CGPoint, radius: CGFloat) {
        let side = min(size.width, size.height)
        return (CGPoint(x: size.width / 2, y: size.height / 2), max(0, side / 2 - inset))
    }

    /// The point on `axis` (0 at the top, clockwise) at `fraction` of `radius`.
    static func point(axis: Int, count: Int, fraction: Double, center: CGPoint, radius: CGFloat) -> CGPoint {
        let angle = -Double.pi / 2 + (Double(axis) / Double(count)) * 2 * Double.pi
        let r = radius * CGFloat(fraction)
        return CGPoint(x: center.x + r * CGFloat(cos(angle)), y: center.y + r * CGFloat(sin(angle)))
    }

    /// A value's logarithmic fraction of its axis maximum. `log1p` keeps 0 → 0
    /// while compressing the long tail so mid-range costs stay readable.
    static func logFraction(_ value: Int, max: Int) -> Double {
        guard max > 0, value > 0 else { return 0 }
        return log1p(Double(value)) / log1p(Double(max))
    }
}

// MARK: - Shapes

/// The concentric guide rings + radial spokes behind the data polygon.
private struct RadarGridShape: Shape {
    let rings: [Double]
    let axisCount: Int

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let (center, radius) = RadarMath.geometry(in: rect.size)
        for ring in rings {
            for axis in 0..<axisCount {
                let point = RadarMath.point(axis: axis, count: axisCount, fraction: ring, center: center, radius: radius)
                if axis == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            path.closeSubpath()
        }
        for axis in 0..<axisCount {
            path.move(to: center)
            path.addLine(to: RadarMath.point(axis: axis, count: axisCount, fraction: 1, center: center, radius: radius))
        }
        return path
    }
}

/// The filled polygon connecting each axis's plotted value.
private struct RadarPolygonShape: Shape {
    let fractions: [Double]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let (center, radius) = RadarMath.geometry(in: rect.size)
        for (axis, fraction) in fractions.enumerated() {
            let point = RadarMath.point(axis: axis, count: fractions.count, fraction: fraction, center: center, radius: radius)
            if axis == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
}

// MARK: - Index badge

/// The small abbreviation node shared between the radar's vertices and the legend
/// rows — the visual tie between a plotted point and its category.
struct RadarIndexBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundStyle(.rcTextSecondary)
            .frame(width: 18, height: 18)
            .background(Circle().fill(.rcSurfaceRaisedStrong))
            .overlay(Circle().strokeBorder(.rcSeparator, lineWidth: Hairline.thin))
    }
}

// MARK: - Radar

/// A six-axis logarithmic radar for one blueprint's build cost. `fractions` are
/// pre-normalized (0…1) per axis, in `ResourceCost.displayOrder`; `labels` are the
/// matching abbreviations drawn at each vertex.
struct ResourceRadar: View {
    /// Log-normalized value per axis, in display order.
    let fractions: [Double]
    /// Per-axis vertex abbreviations, in display order.
    let labels: [String]

    /// A cost's logarithmic fraction of its axis maximum, for callers building
    /// the `fractions` array from raw amounts + per-axis maxima.
    static func logFraction(_ value: Int, max: Int) -> Double {
        RadarMath.logFraction(value, max: max)
    }

    var body: some View {
        GeometryReader { proxy in
            let (center, radius) = RadarMath.geometry(in: proxy.size)
            ZStack {
                RadarGridShape(rings: [0.5, 1.0], axisCount: fractions.count)
                    .stroke(.rcSeparator, lineWidth: Hairline.thin)

                RadarPolygonShape(fractions: fractions)
                    .fill(.rcAccent.opacity(0.18))
                RadarPolygonShape(fractions: fractions)
                    .stroke(.rcAccent, lineWidth: 1.5)

                ForEach(fractions.indices, id: \.self) { axis in
                    // Data vertex.
                    Circle()
                        .fill(.rcAccent)
                        .frame(width: 5, height: 5)
                        .position(RadarMath.point(axis: axis, count: fractions.count,
                                                  fraction: fractions[axis], center: center, radius: radius))
                    // Abbreviation just outside the plot, tying back to the legend.
                    RadarIndexBadge(text: labels.indices.contains(axis) ? labels[axis] : "")
                        .position(RadarMath.point(axis: axis, count: fractions.count,
                                                  fraction: 1, center: center, radius: radius + 13))
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

// MARK: - Print Cost lockup

/// The Print Cost lockup: a keyed resource legend beside a logarithmic radar. The
/// radar is sized to the legend's measured height so the two read as one unit; the
/// legend is a `Grid` that hugs its content and never wraps, so when horizontal
/// space is scarce the neighbouring Print Time lockup yields instead.
struct PrintCostLockup: View {
    let resources: ResourceCost
    /// The largest cost across every resource of every blueprint — the shared
    /// scale for all six axes, so magnitudes compare across categories.
    let scaleMax: Int

    @State private var legendHeight: CGFloat = 0

    private var items: [(key: String, label: String, abbr: String, amount: Int)] {
        resources.orderedItems
    }

    private var fractions: [Double] {
        items.map { ResourceRadar.logFraction($0.amount, max: scaleMax) }
    }

    var body: some View {
        RCReadoutCard("Print Cost") {
            if items.allSatisfy({ $0.amount == 0 }) {
                Text("No listed resource cost.")
                    .font(.rcBody)
                    .foregroundStyle(.rcTextTertiary)
            } else {
                HStack(alignment: .center, spacing: Space.l) {
                    legend
                        .onGeometryChange(for: CGFloat.self) { proxy in
                            proxy.size.height
                        } action: { height in
                            legendHeight = height
                        }
                    ResourceRadar(fractions: fractions, labels: items.map(\.abbr))
                        .frame(width: legendHeight, height: legendHeight)
                }
            }
        }
    }

    /// The keyed resource grid: abbreviation badge · category · cost. The category
    /// column stretches to fill available width, pushing costs to the right; every
    /// cell is single-line so nothing wraps.
    private var legend: some View {
        Grid(alignment: .leading, horizontalSpacing: Space.s, verticalSpacing: Space.xs) {
            ForEach(items, id: \.key) { item in
                GridRow {
                    RadarIndexBadge(text: item.abbr)
                    Text(item.label)
                        .font(.rcBody)
                        .foregroundStyle(.rcTextSecondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("\(item.amount)")
                        .font(.rcMono)
                        .foregroundStyle(item.amount == 0 ? .rcTextTertiary : .rcTextPrimary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize()
                        .gridColumnAlignment(.trailing)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Print Time lockup

/// The Print Time lockup: the build duration with large numerals and small unit
/// signifiers, ringed by a progress arc scaled to the longest print time in the
/// catalog, centred within a square card that matches the Print Cost lockup's
/// height.
struct PrintTimeLockup: View {
    let printTime: Int
    /// The longest print time across all blueprints — the full-ring value.
    let maxPrintTime: Int

    private var components: [(value: Int, unit: String)] {
        BlueprintPresentation.printTimeComponents(printTime)
    }

    private var fraction: Double {
        guard maxPrintTime > 0 else { return 0 }
        return min(1, Double(printTime) / Double(maxPrintTime))
    }

    var body: some View {
        RCReadoutCard("Print Time") {
            ZStack {
                Circle()
                    .stroke(.rcSeparator, lineWidth: 5)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(.rcAccent, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                value
                    .padding(Space.m)
            }
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var value: some View {
        VStack(spacing: 2) {
            ForEach(components.indices, id: \.self) { index in
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text("\(components[index].value)")
                        .font(.system(size: 30, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.rcTextPrimary)
                    Text(components[index].unit)
                        .font(.rcBody)
                        .foregroundStyle(.rcTextTertiary)
                }
            }
        }
    }
}
