//
//  BobnetRow.swift
//  Replicould — Devices feature
//
//  A single chatter row for the Bobnet list. Kept in its own file (rather than
//  nested in `BobnetView`) so it compiles into the module ahead of time: an
//  Xcode 26 SwiftUI Previews bug crashes the preview agent (an assertion in
//  `ViewListTree.visitItem`) whenever a macOS `List` row is a custom `View` type
//  that the preview JIT recompiles in the same file as the `#Preview`. Living in
//  a separate, prebuilt file sidesteps it with no change to how the row renders.
//

import GameModels
import SwiftUI
import UI

struct BobnetRow: View {
    let message: BobnetMessage

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.s) {
                Text(message.replicantName)
                    .font(.rcBodyEmph)
                    .foregroundStyle(.rcTextPrimary)
                Text(message.channel)
                    .font(.rcMonoSmall)
                    .foregroundStyle(.rcAccent)
                if let star = message.currentStar {
                    Text(star)
                        .font(.rcMonoSmall)
                        .foregroundStyle(.rcTextTertiary)
                }
                Spacer(minLength: Space.s)
                Text(message.time, format: .relative(presentation: .named))
                    .font(.rcMonoSmall)
                    .foregroundStyle(.rcTextTertiary)
            }
            Text(message.message)
                .font(.rcBody)
                .foregroundStyle(.rcTextSecondary)
                .textSelection(.enabled)
        }
        .padding(.vertical, Space.xs)
    }
}
