//
//  SuggestedTargetRow.swift
//  Replicould — Directives feature
//
//  One row of the launcher's nearest-unexplored suggestions. Its own file: a
//  list-row struct sharing a file with a `#Preview` wedges the Xcode 26 preview
//  JIT (see the list-row-preview-crash memory note).
//

import DirectiveEngine
import SwiftUI
import UI

struct SuggestedTargetRow: View {
    let suggestion: SurveyTargetSuggestions.Suggestion
    let add: () -> Void

    var body: some View {
        Button(action: add) {
            HStack {
                // A designation is a code, so it renders mono — project rule.
                Text(suggestion.designation)
                    .font(.rcMonoSmall)
                    .foregroundStyle(.rcTextPrimary)
                Spacer()
                Text(String(format: "%.1f ly", suggestion.distanceLY))
                    .font(.rcCaption)
                    .foregroundStyle(.rcTextTertiary)
            }
            .padding(.vertical, Space.xxs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
