//
//  NewDirectiveSheet.swift
//  Replicould — Directives feature
//
//  The launcher sheet. A pure renderer — eligibility, search, and the queue all
//  live in the reducer's state.
//

import ComposableArchitecture
import GameModels
import SwiftUI
import UI

public struct NewDirectiveSheet: View {
    @Bindable var store: StoreOf<NewDirectiveFeature>

    public init(store: StoreOf<NewDirectiveFeature>) {
        self.store = store
    }

    /// Title and action row are PINNED; everything between them scrolls.
    ///
    /// The queue is variable-length and the sheet's height is fixed, so the
    /// middle has to be the part that gives. It previously wasn't: a bare
    /// `ForEach` of queued targets grew without bound, and since the action row
    /// was the last child of a fixed-height `VStack`, a long enough queue
    /// collapsed the spacer between them and pushed Cancel/Launch outside the
    /// frame — where they render neither visibly nor hit-testably. Ten targets
    /// was enough.
    ///
    /// The action row must therefore stay OUTSIDE the `ScrollView`: that is what
    /// makes it unreachable-proof at any target count, rather than merely
    /// reachable at the counts that happen to fit today.
    ///
    /// No `Spacer` is needed any more — the `ScrollView` is greedy vertically and
    /// takes the slack itself when the content is short, which also removes the
    /// collapsing-spacer mechanism that caused the overflow.
    public var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            Text("New Survey Run")
                .font(.rcTitle)
                .foregroundStyle(.rcTextPrimary)

            ScrollView {
                VStack(alignment: .leading, spacing: Space.l) {
                    if store.eligibleVessels.isEmpty {
                        unstagedNotice
                    } else {
                        vesselPicker
                        targetPicker
                        Toggle("Return to origin when the queue empties", isOn: $store.returnToOrigin)
                            .font(.rcBody)
                            .foregroundStyle(.rcTextSecondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: Space.s) {
                Spacer()
                Button("Cancel") { store.send(.cancelTapped) }
                    .buttonStyle(RCButtonStyle(.secondary))
                Button("Launch") { store.send(.launchTapped) }
                    .buttonStyle(RCButtonStyle(.primary))
                    .disabled(!store.canLaunch)
            }
        }
        .padding(Space.xl)
        // Height stays explicit rather than a `minHeight`: a `ScrollView` has no
        // ideal height, so a min-only frame lets the sheet collapse to almost
        // nothing. 620 rather than the original 560 gives back the room the
        // "Nearest Unexplored" block now occupies.
        .frame(width: 520, height: 620)
    }

    /// Staging is the player's job, so the empty state says exactly what to do
    /// rather than offering a vessel that would stall on its first evaluation.
    private var unstagedNotice: some View {
        RCContentUnavailableView(
            "No Vessel Ready",
            systemImage: "shippingbox",
            description: Text("Stow an AMI Survey Controller and at least one adopted Survey Drone aboard a vessel, then start a run.")
        )
    }

    private var vesselPicker: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            RCSectionHeader("Vessel")
            Picker("Vessel", selection: $store.vesselCode) {
                Text("Choose…").tag(String?.none)
                ForEach(store.eligibleVessels) { vessel in
                    Text(vessel.deviceCode).tag(String?.some(vessel.deviceCode))
                }
            }
            .labelsHidden()
            .font(.rcMonoSmall)
        }
    }

    /// The nearest unexplored systems, offered before any search is typed. Sits
    /// in the same slot as `searchResults` and yields to it the moment the field
    /// has text.
    @ViewBuilder private var suggestions: some View {
        if !store.suggestedTargets.isEmpty {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text("Nearest Unexplored")
                    .font(.rcCaption)
                    .foregroundStyle(.rcTextTertiary)
                ForEach(store.suggestedTargets) { suggestion in
                    SuggestedTargetRow(suggestion: suggestion) {
                        store.send(.targetAdded(suggestion.designation))
                    }
                }
            }
        }
    }

    private var targetPicker: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            RCSectionHeader("Targets")
            RCField("Search systems", text: $store.search)
            if store.search.trimmingCharacters(in: .whitespaces).isEmpty {
                suggestions
            }
            if !store.searchResults.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(store.searchResults) { star in
                            Button {
                                store.send(.targetAdded(star.designation))
                            } label: {
                                HStack {
                                    Text(star.designation)
                                        .font(.rcMonoSmall)
                                        .foregroundStyle(.rcTextPrimary)
                                    Spacer()
                                    if star.explored {
                                        Text("explored")
                                            .font(.rcCaption)
                                            .foregroundStyle(.rcTextTertiary)
                                    }
                                }
                                .padding(.vertical, Space.xxs)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 120)
            }
            if store.targets.isEmpty {
                Text("No targets queued yet.")
                    .font(.rcCaption)
                    .foregroundStyle(.rcTextTertiary)
            } else {
                ForEach(Array(store.targets.enumerated()), id: \.offset) { index, target in
                    QueuedTargetRow(position: index + 1, designation: target) {
                        store.send(.targetRemoved(index))
                    }
                }
            }
        }
    }
}
