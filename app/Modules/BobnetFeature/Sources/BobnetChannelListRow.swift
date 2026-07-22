//
//  BobnetChannelListRow.swift
//  Replicould — Bobnet feature
//
//  A single channel row for the channels pane. Kept in its own file (rather than
//  nested in `BobnetChannelsView`) so it compiles into the module ahead of time:
//  an Xcode 26 SwiftUI Previews bug crashes the preview agent (an assertion in
//  `ViewListTree.visitItem`) whenever a macOS `List` row is a custom `View` type
//  that the preview JIT recompiles in the same file as the `#Preview`. Living in
//  a separate, prebuilt file sidesteps it with no change to how the row renders.
//

import SwiftUI
import UI

struct BobnetChannelListRow: View {
    let row: BobnetChannelRow

    var body: some View {
        HStack(spacing: Space.s) {
            // Channel names are designation-style codes → mono at list-row prominence.
            Text(row.name)
                .font(.rcBodyEmphMono)
                .foregroundStyle(.rcTextPrimary)
                .lineLimit(1)

            Spacer(minLength: Space.s)

            if let activity = row.lastActivity {
                Text(activity, format: .relative(presentation: .named))
                    .font(.rcMonoSmall)
                    .foregroundStyle(.rcTextTertiary)
                    .fixedSize()
            }

            if row.unreadCount > 0 {
                UnreadBadge(count: row.unreadCount)
            }
        }
        .padding(.vertical, Space.xs)
    }
}

/// The trailing unread count: a `.rcMonoSmall` number in a solid-accent capsule.
/// The sidebar's own badge (`SidebarCategoryBadge`) is internal to
/// `SidebarFeature` and not reusable here, so this is the brief's fallback
/// treatment — accent fill with the on-accent text token.
private struct UnreadBadge: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(.rcMonoSmall)
            .foregroundStyle(.rcAccentOnColor)
            .monospacedDigit()
            .padding(.vertical, 1)
            .padding(.horizontal, Space.xs + 2)
            .background(Capsule().fill(.rcAccent))
    }
}
