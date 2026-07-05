//
//  MessageRow.swift
//  Replicould — Messages feature
//
//  A single inbox row for the master list. Kept in its own file (rather than
//  nested in `MessagesView`) so it compiles into the module ahead of time: an
//  Xcode 26 SwiftUI Previews bug crashes the preview agent (an assertion in
//  `ViewListTree.visitItem`) whenever a macOS `List` row is a custom `View`
//  type that the preview JIT-recompiles in the same file as the `#Preview`.
//  Living in a separate, prebuilt file sidesteps it with no change to how the
//  row renders.
//

import GameModels
import SwiftUI
import UI

struct MessageRow: View {
    let message: Message

    var body: some View {
        HStack(alignment: .top, spacing: Space.s) {
            Circle()
                .fill(message.isRead ? Color.clear : Color.rcAccent)
                .frame(width: 7, height: 7)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: Space.xs) {
                HStack(spacing: Space.s) {
                    Text(message.title)
                        .font(message.isRead ? .rcBody : .rcBodyEmph)
                        .foregroundStyle(.rcTextPrimary)
                        .lineLimit(1)
                    Spacer(minLength: Space.xs)
                    Text(message.createdAt, format: .relative(presentation: .named))
                        .font(.rcCaption)
                        .foregroundStyle(.rcTextTertiary)
                        .fixedSize()
                }
                Text(message.body)
                    .font(.rcCaption)
                    .foregroundStyle(.rcTextSecondary)
                    .lineLimit(2)
                // Story beats get an accent pill so they stand out from routine
                // system/achievement traffic in the inbox.
                if message.messageType == "story" {
                    Text("STORY")
                        .font(.rcMonoSmall)
                        .foregroundStyle(.rcAccent)
                        .rcPill(.accent)
                } else {
                    Text(message.messageType.uppercased())
                        .font(.rcMonoSmall)
                        .foregroundStyle(.rcTextTertiary)
                }
            }
        }
        .padding(.vertical, Space.xs)
    }
}
