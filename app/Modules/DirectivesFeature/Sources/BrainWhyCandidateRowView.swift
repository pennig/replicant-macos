//
//  BrainWhyCandidateRowView.swift
//  Replicould — Directives feature
//
//  One `TheatreSiteRanking.Candidate` inside `BrainWhyDetailView`. Read-only,
//  like the pane it sits in — establishing a theatre is Logistics' job. Own
//  file per the list-row-preview-crash rule.
//

import DirectiveEngine
import SwiftUI
import UI

struct BrainWhyCandidateRowView: View {
    let candidate: TheatreSiteRanking.Candidate

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            Text(candidate.system)
                .font(.rcBodyEmphMono)
                .foregroundStyle(.rcTextPrimary)
            // The brain's own graph facts, verbatim — not restated prose.
            ForEach(candidate.reasons, id: \.self) { reason in
                Text(reason)
                    .font(.rcCaption)
                    .foregroundStyle(.rcTextSecondary)
            }
        }
    }
}
