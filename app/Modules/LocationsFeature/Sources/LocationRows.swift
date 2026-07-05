//
//  LocationRows.swift
//  LocationsFeature
//
//  The row views for the locations catalog list: a recursive outline row plus the
//  leaf row and its recon dot. Kept in their own file (rather than nested in
//  `LocationsListView`) so they compile into the module ahead of time: an Xcode 26
//  SwiftUI Previews bug crashes the preview agent (an assertion in
//  `ViewListTree.visitItem`) whenever a macOS `List` row is a custom `View` type
//  that the preview JIT recompiles in the same file as the `#Preview`. Living in a
//  separate, prebuilt file sidesteps it with no change to how the rows render.
//

import SwiftUI
import UI
import UniverseModels

// MARK: - Recursive outline row

/// One node and (lazily, on expand) its children. Leaves render a plain tagged
/// row; nodes with children render a `DisclosureGroup` whose contents are only
/// built when the user expands it — so an unexpanded system costs one row.
struct LocationOutlineRow: View {
    let node: LocationNode

    var body: some View {
        if let children = node.children, !children.isEmpty {
            DisclosureGroup {
                ForEach(children) { LocationOutlineRow(node: $0) }
            } label: {
                LocationRow(node: node).tag(node.id)
            }
        } else {
            LocationRow(node: node)
                .tag(node.id)
                .listRowSeparator(.hidden)
        }
    }
}

// MARK: - Row

struct LocationRow: View {
    let node: LocationNode

    var body: some View {
        HStack(spacing: Space.s) {
            Image(systemName: node.kind.symbol)
                .font(.system(size: 13))
                .foregroundStyle(node.recon == .aware ? .rcTextTertiary : .rcAccent)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(node.title)
                    .font(node.kind == .system ? .rcBodyEmph : .rcBody)
                    .foregroundStyle(.rcTextPrimary)
                if let subtitle = node.subtitle {
                    Text(subtitle)
                        .font(.rcCaption)
                        .foregroundStyle(.rcTextTertiary)
                }
            }

            Spacer(minLength: Space.s)

            ForEach(node.badges) { badge in
                HStack(spacing: 2) {
                    Image(systemName: badge.symbol).font(.system(size: 9))
                    Text("\(badge.count)").font(.rcMonoSmall)
                }
                .foregroundStyle(.rcTextSecondary)
            }

            ReconDot(recon: node.recon)
        }
        .padding(.vertical, 2)
    }
}

/// Small filled dot conveying recon depth (scanned = full, aware = faint).
struct ReconDot: View {
    let recon: Recon
    var body: some View {
        Circle()
            .fill(.rcAccent.opacity(recon.dim))
            .frame(width: 6, height: 6)
            .help(recon.label)
    }
}
