//
//  QueuedTargetRow.swift
//  Replicould — Directives feature
//
//  One row of the new-run target queue. In its own file per the house rule —
//  a row struct beside a `#Preview` crashes the Xcode 26 preview JIT.
//

import SwiftUI
import UI

struct QueuedTargetRow: View {
    let position: Int
    let designation: String
    let remove: () -> Void

    var body: some View {
        HStack(spacing: Space.s) {
            Text("\(position)")
                .font(.rcMicroMono)
                .foregroundStyle(.rcTextTertiary)
                .frame(width: 16, alignment: .trailing)
            Text(designation)
                .font(.rcMonoSmall)
                .foregroundStyle(.rcTextPrimary)
            Spacer(minLength: 0)
            Button(action: remove) {
                Image(systemName: "minus.circle")
                    .font(.system(size: IconSize.s))
                    .foregroundStyle(.rcTextTertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, Space.xxs)
    }
}
