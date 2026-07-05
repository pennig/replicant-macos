//
//  BlueprintRow.swift
//  Replicould — Blueprints feature
//
//  A single blueprint row for the catalog list. Kept in its own file (rather than
//  nested in `BlueprintsListView`) so it compiles into the module ahead of time:
//  an Xcode 26 SwiftUI Previews bug crashes the preview agent (an assertion in
//  `ViewListTree.visitItem`) whenever a macOS `List` row is a custom `View` type
//  that the preview JIT recompiles in the same file as the `#Preview`. Living in
//  a separate, prebuilt file sidesteps it with no change to how the row renders.
//

import GameModels
import SwiftUI
import UI

struct BlueprintRow: View {
    let blueprint: Blueprint

    var body: some View {
        HStack(spacing: Space.s) {
            RCGlyphTile(Image.rcSymbol("device.\(blueprint.deviceType)"))
            VStack(alignment: .leading, spacing: Space.xs) {
                HStack(spacing: Space.s) {
                    Text(BlueprintPresentation.displayName(blueprint.deviceType))
                        .font(.rcBodyEmph)
                        .foregroundStyle(.rcTextPrimary)
                        .lineLimit(1)
                    Spacer(minLength: Space.xs)
                    Label(BlueprintPresentation.printTimeText(blueprint.printTime), systemImage: "clock")
                        .font(.rcMonoSmall)
                        .foregroundStyle(.rcTextTertiary)
                        .labelStyle(.titleAndIcon)
                }
                Text(blueprint.shortDescription)
                    .font(.rcCaption)
                    .foregroundStyle(.rcTextSecondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, Space.xs)
    }

}
