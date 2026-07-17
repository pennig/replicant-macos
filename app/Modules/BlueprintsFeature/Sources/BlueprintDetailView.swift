//
//  BlueprintDetailView.swift
//  Replicould — Blueprints feature
//
//  The blueprint inspector for the split view's detail column: header, full
//  description, build-cost breakdown (resource line items + print time), feature
//  and directive chips, and a capacities readout. Read-only — printing is a
//  per-device command surfaced elsewhere. Observes the `Blueprint` table, so a
//  refresh re-renders the pane automatically.
//

import ComposableArchitecture
import GameDatabase
import GameModels
import SQLiteData
import SwiftUI
import UI

public struct BlueprintDetailView: View {
    let store: StoreOf<BlueprintsFeature>
    @FetchAll(Blueprint.all) private var blueprints
    /// The measured Print Cost lockup height, mirrored onto the Print Time lockup
    /// so it renders as a square that matches the cost lockup's height.
    @State private var costHeight: CGFloat = 0

    public init(store: StoreOf<BlueprintsFeature>) {
        self.store = store
    }

    private var blueprint: Blueprint? {
        guard let deviceType = store.selectedDeviceType else { return nil }
        return blueprints.first { $0.deviceType == deviceType }
    }

    public var body: some View {
        if let blueprint {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.xl) {
                    header(blueprint)
                    description(blueprint)
                    costAndTime(blueprint)
                    capabilities(blueprint)
                    capacities(blueprint)
                }
                .padding(Space.xl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(BlueprintPresentation.displayName(blueprint.deviceType))
        } else {
            ContentUnavailableView(
                "No Blueprint Selected",
                systemImage: SidebarSymbol.blueprints,
                description: Text("Select a blueprint to inspect it.")
            )
        }
    }

    // MARK: Header

    private func header(_ blueprint: Blueprint) -> some View {
        HStack(spacing: Space.m) {
            ZStack {
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .fill(.rcSurfaceRaised)
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                            .strokeBorder(.rcSeparator, lineWidth: 0.5)
                    )
                Image.rcSymbol("device.\(blueprint.deviceType)")
                    .font(.system(size: 26, weight: .regular))
                    .foregroundStyle(.rcTextPrimary, .rcAccent, .rcTextSecondary)
            }
            .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: Space.xs) {
                Text(BlueprintPresentation.displayName(blueprint.deviceType))
                    .font(.rcTitle)
                    .foregroundStyle(.rcTextPrimary)
                Text(blueprint.deviceType)
                    .font(.rcMono)
                    .foregroundStyle(.rcTextTertiary)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Description

    private func description(_ blueprint: Blueprint) -> some View {
        Text(blueprint.fullDescription)
            .font(.rcBody)
            .foregroundStyle(.rcTextSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Cost & time

    /// The cost/time band: a Print Cost lockup (keyed legend + logarithmic radar)
    /// that fills the available width — stretching the category-name column — and a
    /// square Print Time lockup, sized to the cost lockup's measured height.
    private func costAndTime(_ blueprint: Blueprint) -> some View {
        HStack(alignment: .top, spacing: Space.m) {
            PrintCostLockup(
                resources: blueprint.resources,
                // A single scale across every resource of every blueprint, so a
                // 1,500 cost always plots smaller than a 3,000 one regardless of
                // which resource each happens to be.
                scaleMax: ResourceCost.overallMaximum(across: blueprints.map(\.resources))
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { height in
                costHeight = height
            }

            PrintTimeLockup(
                printTime: blueprint.printTime,
                maxPrintTime: blueprints.map(\.printTime).max() ?? 0
            )
            .frame(width: costHeight, height: costHeight)
        }
    }

    // MARK: Capabilities (features + directives)

    @ViewBuilder
    private func capabilities(_ blueprint: Blueprint) -> some View {
        if !blueprint.features.isEmpty {
            Section(label: "Features") {
                ChipFlow(blueprint.features.map(BlueprintPresentation.displayName))
            }
        }
        if !blueprint.directives.isEmpty {
            Section(label: "Directives") {
                ChipFlow(blueprint.directives.map(BlueprintPresentation.displayName))
            }
        }
    }

    // MARK: Capacities

    @ViewBuilder
    private func capacities(_ blueprint: Blueprint) -> some View {
        let rows = capacityRows(blueprint)
        if !rows.isEmpty {
            Section(label: "Capacities") {
                VStack(spacing: Space.s) {
                    ForEach(rows, id: \.label) { row in
                        HStack {
                            Text(row.label)
                                .font(.rcBody)
                                .foregroundStyle(.rcTextSecondary)
                            Spacer()
                            Text(row.value)
                                .font(.rcMono)
                                .foregroundStyle(.rcTextPrimary)
                        }
                    }
                }
            }
        }
    }

    private func capacityRows(_ blueprint: Blueprint) -> [(label: String, value: String)] {
        var rows: [(label: String, value: String)] = []
        if blueprint.stowCapacity > 0 { rows.append(("Stow capacity", "\(blueprint.stowCapacity)")) }
        if blueprint.cargoCapacity > 0 { rows.append(("Cargo capacity", "\(blueprint.cargoCapacity)")) }
        if blueprint.attachCapacity > 0 { rows.append(("Attach capacity", "\(blueprint.attachCapacity)")) }
        if blueprint.queueSize > 0 { rows.append(("Print queue", "\(blueprint.queueSize)")) }
        if blueprint.strength > 0 { rows.append(("Strength", "\(Int(blueprint.strength))")) }
        if let hubs = blueprint.currentHubs { rows.append(("System hubs", "\(hubs)")) }
        return rows
    }
}

// MARK: - Section container

/// A titled section with the design system's uppercase section label.
private struct Section<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Text(label.uppercased())
                .font(.rcSectionLabel)
                .tracking(0.8)
                .foregroundStyle(.rcTextTertiary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Chip flow

/// A wrapping row of pill chips for features / directives.
private struct ChipFlow: View {
    let labels: [String]

    init(_ labels: [String]) {
        self.labels = labels
    }

    var body: some View {
        FlowLayout(spacing: Space.s) {
            ForEach(labels, id: \.self) { label in
                Text(label)
                    .font(.rcCaption)
                    .foregroundStyle(.rcTextSecondary)
                    .padding(.horizontal, Space.s)
                    .padding(.vertical, Space.xs)
                    .background(.rcSurfaceRaisedStrong, in: Capsule())
                    .overlay(Capsule().strokeBorder(.rcSeparator, lineWidth: 0.5))
            }
        }
    }
}

/// A minimal flow layout: lays subviews left-to-right, wrapping to the next row
/// when the proposed width is exceeded.
private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var totalWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0, rowWidth + spacing + size.width > maxWidth {
                totalHeight += rowHeight + spacing
                totalWidth = max(totalWidth, rowWidth)
                rowWidth = size.width
                rowHeight = size.height
            } else {
                rowWidth += (rowWidth > 0 ? spacing : 0) + size.width
                rowHeight = max(rowHeight, size.height)
            }
        }
        totalHeight += rowHeight
        totalWidth = max(totalWidth, rowWidth)
        return CGSize(width: maxWidth == .infinity ? totalWidth : maxWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let maxWidth = bounds.width
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width - bounds.minX > maxWidth {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Preview

#Preview {
    let _ = prepareDependencies {
        try! $0.bootstrapDatabase { db in
            try db.seed { Blueprint.previewCatalog }
        }
    }
    BlueprintDetailView(
        store: Store(initialState: BlueprintsFeature.State(selectedDeviceType: "heaven_vessel")) {
            BlueprintsFeature()
        }
    )
    .frame(width: 640, height: 760)
}
