//
//  SettingsTab.swift
//  Replicould — Account feature
//
//  Editable account preferences (name, timezone, replicant cooperation, bobnet
//  channels), saved via `PATCH /v1/accounts/me`. The notification matrix and
//  email changes are intentionally out of scope this pass.
//

import ComposableArchitecture
import SwiftUI
import UI

struct SettingsTab: View {
    @Bindable var store: StoreOf<AccountFeature>

    var body: some View {
        Form {
            Section("Profile") {
                TextField("Name", text: $store.draftName)
                TextField("Timezone", text: $store.draftTimezone)
                    .help("IANA name (e.g. America/Chicago) or a UTC±N offset")
            }

            Section("Replicant Cooperation") {
                Picker("Mode", selection: $store.draftCooperation) {
                    Text("Individual").tag("individual")
                    Text("Shared").tag("shared")
                }
                .pickerStyle(.radioGroup)
                Text(cooperationHelp)
                    .font(.rcCaption)
                    .foregroundStyle(.rcTextSecondary)
            }

            Section("Bobnet Channels") {
                TextField("Channels", text: $store.draftChannelsText, axis: .vertical)
                    .lineLimit(1...3)
                Text("Comma-separated, e.g. #general, #trade")
                    .font(.rcCaption)
                    .foregroundStyle(.rcTextTertiary)
            }

            Section("Notifications") {
                Text("Notification preferences aren't editable here yet.")
                    .font(.rcCaption)
                    .foregroundStyle(.rcTextTertiary)
            }

            if let error = store.saveError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.rcBody)
                        .foregroundStyle(.rcError)
                }
            }

            Section {
                HStack {
                    Spacer()
                    Button {
                        store.send(.saveSettings)
                    } label: {
                        if store.isSaving {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Save Changes")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.isSaving || !store.hasUnsavedChanges)
                }
            }
        }
        .formStyle(.grouped)
    }

    /// A one-line explanation of the selected cooperation mode.
    private var cooperationHelp: String {
        switch store.draftCooperation {
        case "shared":
            "All your replicants can freely operate on each other's devices."
        default:
            "Each replicant controls only its own devices."
        }
    }
}
