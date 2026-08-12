//
//  BrainWhyDetailView.swift
//  Replicould — Directives feature
//
//  The brain's full tick report, in the detail pane. The counterpart to
//  `BrainWhyView`, which is now only the one-line status strip that opens this.
//
//  The split is what makes the surface scale. `brain-robustness-bar` clause 8
//  asks for a live derived "why" view, and as the brain learns goals beyond
//  tendMesh it will have steadily more to say — more rails, more candidates,
//  more per-goal findings. None of that could keep landing in a header pinned
//  above the Directives list: header height is subtracted from the list on
//  every screen, and a header that grows with the brain's vocabulary would
//  eventually be the whole window. Here it scrolls.
//
//  **Nothing on this pane is line-limited**, which is the other half of the
//  split. In chrome an unbounded wrapping line reports its zero-width wrap
//  height as the window's minimum height (the chrome-min-height note); inside a
//  `ScrollView` that minimum is clamped to nothing, so the text can wrap as far
//  as it likes and the operator reads the whole sentence.
//

import DirectiveEngine
import SwiftUI
import UI

/// A read-only report. Actions (retry/cancel) ride the run rows, so — like the
/// header it opens from — this surface never dispatches anything.
public struct BrainWhyDetailView: View {
    let why: BrainWhy
    /// Ranked new-theatre-site proposals, already computed and held by the
    /// caller — never ranked here (see `TheatreSiteRanking.rank`'s own cost
    /// warning).
    let candidateSites: [TheatreSiteRanking.Candidate]

    public init(why: BrainWhy, candidateSites: [TheatreSiteRanking.Candidate] = []) {
        self.why = why
        self.candidateSites = candidateSites
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.l) {
                gate

                // Unconditional: `limitPressure` is never empty (the two
                // standing rails report every tick, healthy or not), so a guard
                // would be dead code.
                section("Limits") {
                    ForEach(why.limitPressure) { pressure in
                        Text(pressure.detail)
                            .font(.rcBody)
                            // A 429 was done TO us; the other two are choices we
                            // made. They must not read alike.
                            .foregroundStyle(pressure.isImposed ? .rcWarning : .rcTextSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                // One section per recognised theatre.
                if !why.theatreGroups.isEmpty {
                    section("Theatres") {
                        ForEach(why.theatreGroups) { group in
                            BrainWhyTheatreGroupView(group: group)
                        }
                    }
                }
                // The flat fallback — see `BrainWhy.flatSectionsVisible`.
                if why.flatSectionsVisible {
                    section("Survey") {
                        why.survey.spans
                            .styled(prose: .rcBody, designation: .rcMono)
                            .foregroundStyle(surveyColor(why.survey.kind))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(why.goals) { goal in
                        section(goal.goal.title) {
                            goal.spans
                                .styled(prose: .rcBody, designation: .rcMono)
                                .foregroundStyle(goalColor(goal.kind))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                // Empty until the first mine is installed — unlike `goals`,
                // there is nothing to report before one exists.
                if !why.mineHealth.isEmpty {
                    section("Mine Health") {
                        ForEach(why.mineHealth) { health in
                            health.spans
                                .styled(prose: .rcBody, designation: .rcMono)
                                .foregroundStyle(goalColor(health.kind))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                // Empty only when prune did not run at all — not when the mesh
                // is healthy, which is why a tidy mesh still gets a line.
                if !why.pruneNotes.isEmpty {
                    section("Mesh") {
                        ForEach(why.pruneNotes) { note in
                            note.spans
                                .styled(prose: .rcBody, designation: .rcMono)
                                // A step back for the states that merely describe
                                // a mesh at rest. Never `.rcWarning`: that is the
                                // escalation colour, and prune never escalates.
                                .foregroundStyle(note.isObservation ? .rcTextTertiary : .rcTextSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                // Ranked new-theatre proposals — empty until the operator has
                // opened this pane at least once this session.
                if !candidateSites.isEmpty {
                    section("Prospective Theatres") {
                        ForEach(candidateSites) { candidate in
                            BrainWhyCandidateRowView(candidate: candidate)
                        }
                    }
                }

                // The whole ranked field, uncapped — see `BrainWhy.candidates`.
                // This is the part that most needed the scroll: one entry per
                // reachable first hop can run to dozens.
                if !why.candidates.isEmpty {
                    section("Ranked Candidates") {
                        ForEach(why.candidates) { candidate in
                            BrainWhyRowView(row: candidate)
                        }
                    }
                }
            }
            .padding(Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The headline, at the prominence the pane's other headers use — the same
    /// sentence the status strip shows, no longer truncated.
    private var gate: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            Image(systemName: why.isEscalated ? "exclamationmark.triangle.fill" : "brain.head.profile")
                .font(.system(size: IconSize.l))
                .foregroundStyle(why.isEscalated ? .rcWarning : .rcTextSecondary)
            why.topGoalGate
                .styled(prose: .rcTitle, designation: .rcTitleMono)
                .foregroundStyle(.rcTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(why.gateText)
    }

    /// Idle reads as a quiet observation and a halt gets `limitPressure`'s own
    /// warning weight; everything else, `.paused` included, stays neutral so
    /// a deliberate pause never reads as a fault.
    private func surveyColor(_ kind: BrainWhySurvey.Kind) -> Color {
        switch kind {
        case .idle: .rcTextTertiary
        case .halted: .rcWarning
        case .running, .paused, .ready: .rcTextSecondary
        }
    }

    /// `surveyColor`'s rule over the production goals' own kind vocabulary.
    private func goalColor(_ kind: BrainWhyGoal.Kind) -> Color {
        switch kind {
        case .idle: .rcTextTertiary
        case .halted: .rcWarning
        case .running, .paused, .ready: .rcTextSecondary
        }
    }

    @ViewBuilder
    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            RCSectionHeader(title)
            content()
        }
    }
}
