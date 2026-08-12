//
//  BrainWhyTheatreGroupView.swift
//  Replicould — Directives feature
//
//  One theatre's section inside `BrainWhyDetailView`. Split into its own
//  file per the list-row-preview-crash rule.
//

import SwiftUI
import UI

struct BrainWhyTheatreGroupView: View {
    let group: BrainWhyTheatreGroup

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(group.depot)
                .font(.rcHeadlineMono)
                .foregroundStyle(.rcTextPrimary)
            if group.goalLines.isEmpty {
                ForEach(group.shortfallLines, id: \.self) { line in
                    Text(line)
                        .font(.rcBody)
                        .foregroundStyle(.rcWarning)
                }
            } else {
                ForEach(group.goalLines) { line in
                    HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                        Text(line.label)
                            .font(.rcCaption)
                            .foregroundStyle(.rcTextTertiary)
                            .frame(width: Space.xl * 2, alignment: .leading)
                        line.spans
                            .styled(prose: .rcBody, designation: .rcMono)
                            .foregroundStyle(color(line.kind))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    /// Matches `BrainWhyDetailView.goalColor`'s rule: idle is a quiet
    /// observation, halted is the one warning weight, everything else neutral.
    private func color(_ kind: BrainWhyGoal.Kind) -> Color {
        switch kind {
        case .idle: .rcTextTertiary
        case .halted: .rcWarning
        case .running, .paused, .ready: .rcTextSecondary
        }
    }
}
