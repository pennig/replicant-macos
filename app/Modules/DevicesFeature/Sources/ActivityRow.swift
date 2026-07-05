//
//  ActivityRow.swift
//  Replicould — Devices feature
//
//  A single operation row for the Operations Log list. Kept in its own file
//  (rather than nested in `ActivityView`) so it compiles into the module ahead of
//  time: an Xcode 26 SwiftUI Previews bug crashes the preview agent (an assertion
//  in `ViewListTree.visitItem`) whenever a macOS `List` row is a custom `View`
//  type that the preview JIT recompiles in the same file as the `#Preview`. Living
//  in a separate, prebuilt file sidesteps it with no change to how the row renders.
//

import GameModels
import SwiftUI
import UI

struct ActivityRow: View {
    // Fully qualified to disambiguate from `Foundation.Operation`.
    let operation: GameModels.Operation

    var body: some View {
        HStack(spacing: Space.s) {
            VStack(alignment: .leading, spacing: Space.xs) {
                HStack(spacing: Space.s) {
                    Text(operation.kind.capitalized)
                        .font(.rcBodyEmph)
                        .foregroundStyle(.rcTextPrimary)
                    Text(operation.entityCode)
                        .font(.rcMonoSmall)
                        .foregroundStyle(.rcTextTertiary)
                }
                Text(operation.status.rawValue)
                    .font(.rcCaption)
                    .foregroundStyle(color(for: operation.status))
            }
            Spacer(minLength: Space.s)
            if let completesAt = operation.completesAt,
               operation.status == .active {
                Text(completesAt, format: .relative(presentation: .named))
                    .font(.rcMonoSmall)
                    .foregroundStyle(.rcTextTertiary)
            }
        }
        .padding(.vertical, Space.xs)
    }

    private func color(for status: OperationStatus) -> Color {
        switch status {
        case .active, .enqueued, .optimistic:
            return .rcAccent
        case .completed:
            return .rcStatusReady
        case .rejected, .failed:
            return .rcError
        default:
            return .rcTextTertiary
        }
    }
}
