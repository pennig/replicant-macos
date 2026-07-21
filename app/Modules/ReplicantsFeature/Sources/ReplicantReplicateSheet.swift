//
//  ReplicantReplicateSheet.swift
//  Replicould — Replicants feature
//
//  The "Replicate" confirmation sheet: a requirement checklist (met/unmet, with a
//  hint on each unmet line), a target picker when more than one empty matrix
//  qualifies, an optional name for the offspring, and a Replicate button gated on
//  every requirement being satisfied. Device/matrix codes render in a mono token.
//

import ComposableArchitecture
import GameModels
import SwiftUI
import UI

struct ReplicantReplicateSheet: View {
    @Bindable var store: StoreOf<ReplicantReplicateFeature>

    var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            header
            requirementsCard

            if !store.eligibility.targets.isEmpty {
                targetSection
                nameSection
            }

            if let error = store.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.rcBody)
                    .foregroundStyle(.rcError)
            }

            Spacer(minLength: 0)
            footer
        }
        .padding(Space.xl)
        .frame(minWidth: 460, minHeight: 520)
        .background(Color.rcWindowBackground)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text("Replicate")
                .font(.rcTitle)
                .foregroundStyle(.rcTextPrimary)
            HStack(spacing: Space.s) {
                Text(store.replicantName)
                    .font(.rcHeadline)
                    .foregroundStyle(.rcTextSecondary)
                Text(store.replicantCode)
                    .font(.rcMonoSmall)
                    .foregroundStyle(.rcTextTertiary)
            }
            Text("Spawn a new replicant in an empty matrix. The source replicant stays put — now there are two of you.")
                .font(.rcCaption)
                .foregroundStyle(.rcTextTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Requirements

    private var requirementsCard: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            RCSectionHeader("Requirements")
            VStack(spacing: 0) {
                ForEach(Array(store.eligibility.requirements.enumerated()), id: \.element.id) { index, requirement in
                    if index > 0 { Divider().overlay(Color.rcSeparator) }
                    requirementRow(requirement)
                }
            }
            .padding(.vertical, Space.xs)
            .background(cardBackground)
        }
    }

    private func requirementRow(_ requirement: ReplicationRequirement) -> some View {
        HStack(alignment: .top, spacing: Space.m) {
            Image(systemName: requirement.isMet ? "checkmark.circle.fill" : "circle")
                .font(.system(size: IconSize.m))
                .foregroundStyle(requirement.isMet ? Color.rcStatusReady : .rcWarning)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(requirement.label)
                    .font(.rcBody)
                    .foregroundStyle(.rcTextPrimary)
                if !requirement.isMet {
                    Text(requirement.hint)
                        .font(.rcCaption)
                        .foregroundStyle(.rcTextTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.m)
        .padding(.vertical, Space.s)
    }

    // MARK: Target + name

    @ViewBuilder
    private var targetSection: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            RCSectionHeader("Target Matrix")
            if store.eligibility.targets.count == 1, let target = store.eligibility.targets.first {
                HStack(spacing: Space.s) {
                    Image(systemName: "cube.box")
                        .font(.system(size: IconSize.m))
                        .foregroundStyle(.rcTextTertiary)
                    Text(target.deviceCode)
                        .font(.rcMono)
                        .foregroundStyle(.rcTextPrimary)
                        .textSelection(.enabled)
                }
            } else {
                RCValueSelect(
                    "Target",
                    systemImage: "cube.box",
                    options: store.eligibility.targets.map { (label: $0.deviceCode, value: Optional($0.deviceCode)) },
                    selection: $store.selectedTargetCode
                )
            }
        }
    }

    private var nameSection: some View {
        RCField(
            "New replicant name (optional)",
            text: $store.newName,
            placeholder: "Auto-assigned if left blank"
        )
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: Space.m) {
            Spacer(minLength: 0)
            Button("Cancel") { store.send(.cancelTapped) }
                .buttonStyle(RCButtonStyle(.secondary))
            Button {
                store.send(.confirmTapped)
            } label: {
                if store.isReplicating {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Replicate")
                }
            }
            .buttonStyle(RCButtonStyle(.primary))
            .disabled(!store.canReplicate)
        }
    }

    // MARK: Chrome

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
            .fill(.rcSurfaceRaised)
            .overlay(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .strokeBorder(.rcSeparator, lineWidth: Hairline.thin)
            )
    }
}
