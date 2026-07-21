//
//  LocationEventRow.swift
//  LocationEventsFeature
//
//  A single quest row for the Location Events list. Kept in its own file (rather
//  than nested in `LocationEventsListView`) so it compiles into the module ahead
//  of time: an Xcode 26 SwiftUI Previews bug crashes the preview agent (an
//  assertion in `ViewListTree.visitItem`) whenever a macOS `List` row is a custom
//  `View` type that the preview JIT recompiles in the same file as the `#Preview`.
//  Living in a separate, prebuilt file sidesteps it with no change to rendering.
//

import GameModels
import SwiftUI
import UI

struct LocationEventRow: View {
    let event: LocationEvent

    var body: some View {
        HStack(spacing: Space.s) {
            Image(systemName: "flag")
                .font(.system(size: IconSize.m))
                .foregroundStyle(event.isActive ? .rcAccent : .rcTextTertiary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(event.title.isEmpty ? event.designation : event.title)
                    .font(.rcBodyEmph)
                    .foregroundStyle(.rcTextPrimary)
                Text(event.locationLabel)
                    .font(.rcMonoSmall)
                    .foregroundStyle(.rcTextTertiary)
            }

            Spacer(minLength: Space.s)

            if event.tier > 0 {
                Text("T\(event.tier)")
                    .font(.rcMonoSmall)
                    .foregroundStyle(.rcTextSecondary)
                    .rcPill(.neutral)
            }
            StatusBadge(event.displayStatus)
        }
        .padding(.vertical, 2)
    }
}
