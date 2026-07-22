//
//  BobnetMessageRow.swift
//  Replicould — Bobnet feature
//
//  A single chatter row for the channel-detail pane. Kept in its own file (rather
//  than nested in `BobnetChannelDetailView`) so it compiles into the module ahead
//  of time: an Xcode 26 SwiftUI Previews bug crashes the preview agent (an
//  assertion in `ViewListTree.visitItem`) whenever a macOS list/stack row is a
//  custom `View` type that the preview JIT recompiles in the same file as the
//  `#Preview`. Living in a separate, prebuilt file sidesteps it with no change to
//  how the row renders. Adapted from the old `BobnetRow` — the channel tag is
//  dropped here, since the channel is the pane's context.
//

import GameModels
import SwiftUI
import UI

struct BobnetMessageRow: View {
    let message: BobnetMessage

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.s) {
                Text(message.replicantName)
                    .font(.rcBodyEmph)
                    .foregroundStyle(.rcTextPrimary)
                // The originating star is a designation code → mono.
                if let star = message.currentStar {
                    Text(star)
                        .font(.rcMonoSmall)
                        .foregroundStyle(.rcTextTertiary)
                }
                Spacer(minLength: Space.s)
                Text(message.time, format: .relative(presentation: .named))
                    .font(.rcMonoSmall)
                    .foregroundStyle(.rcTextTertiary)
                    .fixedSize()
            }
            Text(message.message)
                .font(.rcBody)
                .foregroundStyle(.rcTextSecondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
