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

// MARK: - Row
//
// The row content (`LocationRow`) is hosted per cell by the AppKit-backed
// `LocationsOutlineView`; indentation, the disclosure chevron, and selection
// styling live in `LocationOutlineRowContent` there.

struct LocationRow: View {
    let node: LocationNode

    var body: some View {
        HStack(spacing: Space.s) {
            Image(systemName: node.kind.symbol)
                .font(.system(size: 13))
                .foregroundStyle(iconColor)
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
                    if let count = badge.count {
                        Text("\(count)").font(.rcMonoSmall)
                    }
                }
                .foregroundStyle(.rcTextSecondary)
            }
        }
        .padding(.vertical, 2)
    }

    /// Icon tint by recon depth: scanned = accent, visited = primary, aware = tertiary.
    private var iconColor: Color {
        switch node.recon {
        case .scanned: .rcAccent
        case .visited: .rcTextPrimary
        case .aware:   .rcTextSecondary
        }
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
