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

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            Text("New Survey Run")
                .font(.rcTitle)
                .foregroundStyle(.rcTextPrimary)

            if store.eligibleVessels.isEmpty {
                unstagedNotice
            } else {
                vesselPicker
                targetPicker
                Toggle("Return to origin when the queue empties", isOn: $store.returnToOrigin)
                    .font(.rcBody)
                    .foregroundStyle(.rcTextSecondary)
            }

            Spacer(minLength: 0)

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
        .frame(width: 520, height: 560)
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
