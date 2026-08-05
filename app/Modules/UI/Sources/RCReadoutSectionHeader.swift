//
//  RCReadoutSectionHeader.swift
//  Replicould — UI
//
//  A collapsible list section header that doubles as a readout: title, member
//  count, an optional warning marker, and a thin stacked bar of the section's
//  composition. Domain-free on purpose — the caller supplies already-coloured
//  `Share` values, so this file knows nothing about devices or status strings.
//
//  Rides the same Liquid Glass band as `SelectableList`'s built-in inline
//  header, so a pinned (sticky) instance blurs the rows scrolling beneath it.
//

import SwiftUI

public struct RCReadoutSectionHeader: View {

    /// One segment of the stacked bar.
    public struct Share: Identifiable, Equatable {
        public let label: String
        public let count: Int
        public let color: Color
        public var id: String { label }

        public init(label: String, count: Int, color: Color) {
            self.label = label
            self.count = count
            self.color = color
        }
    }

    private let title: String
    private let count: Int
    private let isCollapsed: Bool
    private let isWarning: Bool
    private let shares: [Share]
    private let onToggle: () -> Void

    public init(
        title: String,
        count: Int,
        isCollapsed: Bool,
        isWarning: Bool = false,
        shares: [Share] = [],
        onToggle: @escaping () -> Void
    ) {
        self.title = title
        self.count = count
        self.isCollapsed = isCollapsed
        self.isWarning = isWarning
        self.shares = shares
        self.onToggle = onToggle
    }

    private var total: Int { shares.reduce(0) { $0 + $1.count } }

    public var body: some View {
        Button(action: onToggle) {
            VStack(alignment: .leading, spacing: Space.xs) {
                HStack(spacing: Space.s) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: IconSize.s))
                        .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                        .foregroundStyle(.rcTextTertiary)
                    Text(title.uppercased())
                        .font(.rcSectionLabel)
                        .kerning(1)
                        .foregroundStyle(.rcTextTertiary)
                    Text("\(count)")
                        .font(.rcMonoSmall)
                        .foregroundStyle(.rcTextTertiary)
                    if isWarning {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: IconSize.s))
                            .foregroundStyle(.rcWarning)
                    }
                    Spacer(minLength: Space.xs)
                }
                if total > 0 {
                    shareBar
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .padding(.horizontal, Space.l)
            .padding(.vertical, Space.s)
            .glassEffect(.regular, in: Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            isWarning
                ? Text("\(title), ^[\(count) item](inflect: true), needs attention")
                : Text("\(title), ^[\(count) item](inflect: true)")
        )
        .accessibilityValue(isCollapsed ? Text("Collapsed") : Text("Expanded"))
        .accessibilityAddTraits(.isHeader)
    }

    /// The composition bar. `GeometryReader` is fenced inside an explicit
    /// `frame(height:)` so it can never report an unbounded ideal height — a
    /// header is chrome, and chrome that reports a tall minimum pins the whole
    /// window's minimum height (see the chrome-min-height memory note).
    private var shareBar: some View {
        GeometryReader { proxy in
            HStack(spacing: Hairline.regular) {
                ForEach(shares) { share in
                    Rectangle()
                        .fill(share.color)
                        .frame(
                            width: max(
                                Hairline.regular,
                                proxy.size.width * CGFloat(share.count) / CGFloat(max(total, 1))
                            )
                        )
                }
            }
        }
        .frame(height: BarThickness.readout)
        .clipShape(Capsule())
    }
}
