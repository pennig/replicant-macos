//
//  CivilisationRow.swift
//  Replicould — Civilisations feature
//
//  A single civilisation row for the catalog list. Kept in its own file (rather
//  than nested in `CivilisationsListView`) so it compiles into the module ahead
//  of time: an Xcode 26 SwiftUI Previews bug crashes the preview agent whenever
//  a macOS `List` row is a custom `View` type that the preview JIT recompiles in
//  the same file as the `#Preview`. Living in a separate, prebuilt file
//  sidesteps it with no change to how the row renders.
//

import GameModels
import SwiftUI
import UI

struct CivilisationRow: View {
    let civilisation: Civilisation

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.s) {
                Text(civilisation.name)
                    .font(.rcBodyEmph)
                    .foregroundStyle(.rcTextPrimary)
                    .lineLimit(1)
                Spacer(minLength: Space.xs)
                if let reputation = civilisation.totalReputation {
                    Text("REP \(reputation.formatted())")
                        .font(.rcMonoSmall)
                        .foregroundStyle(.rcTextTertiary)
                }
            }
            Text("\(BlueprintPresentation.displayName(civilisation.trait)) · \(civilisation.government)")
                .font(.rcCaption)
                .foregroundStyle(.rcTextSecondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, Space.xs)
    }

}
