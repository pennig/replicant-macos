//
//  DirectiveGroupHeader.swift
//  Replicould — Directives feature
//
//  A group's one line while it is closed: what the automation is, where it
//  works, how many rows it holds, and whether it is asking for the operator.
//

import SwiftUI
import UI

struct DirectiveGroupHeader: View {
    let group: DirectiveGroup
    let isExpanded: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: Space.xs) {
                Image(systemName: "chevron.right")
                    .font(.system(size: IconSize.s))
                    .foregroundStyle(.rcTextTertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: IconSize.s)
                Text(group.title)
                    .font(.rcBodyEmph)
                    .foregroundStyle(.rcTextPrimary)
                if let designation = group.designation {
                    Text("▸")
                        .font(.rcCaption)
                        .foregroundStyle(.rcTextTertiary)
                    Text(designation)
                        .font(.rcBodyEmphMono)
                        .foregroundStyle(.rcTextPrimary)
                        .lineLimit(1)
                }
                Spacer(minLength: Space.s)
                attentionLabel
                Text("\(group.rows.count)")
                    .font(.rcMicroMono)
                    .foregroundStyle(.rcTextTertiary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(group.title), \(group.rows.count) directives")
        .accessibilityAddTraits(isExpanded ? .isSelected : [])
    }

    /// Named as well as toned — the word carries the state, the colour only
    /// reinforces it.
    @ViewBuilder
    private var attentionLabel: some View {
        switch group.attention {
        case .needsAttention:
            Label("needs attention", systemImage: "exclamationmark.triangle.fill")
                .font(.rcCaption)
                .foregroundStyle(.rcWarning)
        case .paused:
            Label("paused", systemImage: "pause.circle.fill")
                .font(.rcCaption)
                .foregroundStyle(.rcTextSecondary)
        case .working:
            EmptyView()
        }
    }
}
