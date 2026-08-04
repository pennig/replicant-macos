//
//  BrainWhyRowView.swift
//  Replicould — Directives feature
//
//  One candidate row inside the brain's why-view card. Split from
//  `BrainWhyRow` the same way `DirectiveRowView` is split from `DirectiveRow`
//  — and kept out of any file holding a `#Preview`, per the
//  list-row-preview-crash rule.
//
//  Every designation here renders in a mono token and every piece of prose
//  does not, which is possible because `BrainWhyRow` stores the two apart
//  rather than as one pre-composed sentence.
//

import SwiftUI
import UI

struct BrainWhyRowView: View {
    let row: BrainWhyRow

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
            Text("\(row.rank)")
                .font(.rcMicroMono)
                .foregroundStyle(.rcTextTertiary)
                // A gutter wide enough for a two-digit rank at micro-mono, so
                // the designations below stay left-aligned once the field
                // passes nine candidates.
                .frame(minWidth: Space.m, alignment: .trailing)

            Text(row.target)
                // The chosen candidate is the one the tick acted on, so it
                // carries list-row prominence; the runners-up sit a step back.
                .font(row.isChosen ? .rcBodyEmphMono : .rcMonoSmall)
                .foregroundStyle(row.isChosen ? .rcTextPrimary : .rcTextSecondary)

            if row.isChosen {
                Image(systemName: "arrow.up.forward.circle.fill")
                    .font(.system(size: IconSize.s))
                    .foregroundStyle(.rcAccent)
                    .accessibilityLabel("Launched")
            }

            Text(row.fact)
                .font(.rcCaption)
                .foregroundStyle(.rcTextSecondary)

            if !row.servedSpans.isEmpty {
                // Prose in the caption token, designations in its
                // prominence-matched mono sibling.
                row.servedSpans
                    .styled(prose: .rcCaption, designation: .rcMonoSmall)
                    .foregroundStyle(.rcTextTertiary)
                    // Bounded like the card's other lines (see `BrainWhyView`).
                    // Two, not three: up to five of these rows each pay the cap.
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        var parts = ["Rank \(row.rank)", row.target, row.fact]
        if row.isChosen { parts.append("launched") }
        if !row.servedTargets.isEmpty { parts.append("serves \(row.servedTargets.joined(separator: ", "))") }
        return parts.joined(separator: ", ")
    }
}
