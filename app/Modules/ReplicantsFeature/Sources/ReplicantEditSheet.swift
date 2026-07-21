//
//  ReplicantEditSheet.swift
//  Replicould — Replicants feature
//
//  The profile editor sheet for one of the account's own replicants. Hand-built
//  from the design-system controls (`RCField`, `RCSegmentedControl`,
//  `RCButtonStyle`) on the window-background token — matching the app's other
//  confirmation sheets (e.g. `PrintPlanSheet`) rather than a grouped `Form`, so
//  it reads correctly in both color schemes. Save is gated on an actual change.
//

import ComposableArchitecture
import SwiftUI
import UI

struct ReplicantEditSheet: View {
    @Bindable var store: StoreOf<ReplicantEditFeature>

    var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: Space.l) {
                    RCField("Name", text: $store.name, placeholder: "What should we call this replicant?")
                    RCField("Pronouns", text: $store.pronouns, placeholder: "e.g. they/them", hint: "Public, max 50 characters")
                    ThemedTextEditor(label: "Description", text: $store.descriptionText)
                    ThemedTextEditor(label: "Plan", text: $store.plan)
                    ThemedTextEditor(label: "Project", text: $store.project)
                    cohortSection
                    npcSection
                }
                .padding(.vertical, Space.xs)
            }

            if let error = store.saveError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.rcBody)
                    .foregroundStyle(.rcError)
            }

            footer
        }
        .padding(Space.xl)
        .frame(width: 480, height: 620)
        .background(Color.rcWindowBackground)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text("Edit Replicant")
                .font(.rcTitle)
                .foregroundStyle(.rcTextPrimary)
            Text(store.replicantCode)
                .font(.rcMonoSmall)
                .foregroundStyle(.rcTextTertiary)
                .textSelection(.enabled)
        }
    }

    // MARK: Cooperation + NPC

    private var cohortSection: some View {
        VStack(alignment: .leading, spacing: Space.xs + 2) {
            Text("COHORT PERMISSION")
                .font(.rcFieldLabel).kerning(0.5)
                .foregroundStyle(.rcTextTertiary)
            RCSegmentedControl(
                selection: $store.cohortPermission,
                options: ["private", "public"],
                label: { $0.capitalized }
            )
        }
    }

    private var npcSection: some View {
        Toggle(isOn: $store.isNPC) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Mark as NPC")
                    .font(.rcBody)
                    .foregroundStyle(.rcTextPrimary)
                Text("Suppresses this replicant's BobNet chatter.")
                    .font(.rcCaption)
                    .foregroundStyle(.rcTextTertiary)
            }
        }
        .toggleStyle(.switch)
        .tint(.rcAccent)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: Space.m) {
            Spacer(minLength: 0)
            Button("Cancel") { store.send(.cancelTapped) }
                .buttonStyle(RCButtonStyle(.secondary))
            Button {
                store.send(.saveTapped)
            } label: {
                if store.isSaving {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Save")
                }
            }
            .buttonStyle(RCButtonStyle(.primary))
            .disabled(!store.canSave)
        }
    }
}

/// A labelled multi-line input styled like `RCField` (via the shared
/// `RCFieldStyle`), for the longer lore fields.
private struct ThemedTextEditor: View {
    let label: String
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs + 2) {
            Text(label.uppercased())
                .font(.rcFieldLabel).kerning(0.5)
                .foregroundStyle(.rcTextTertiary)
            TextField(label, text: $text, axis: .vertical)
                .focused($focused)
                .lineLimit(2...6)
                .rcField(focused: focused)
        }
    }
}
