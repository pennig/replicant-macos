//
//  AccountView.swift
//  Replicant
//
//  Account information, presented as a sheet from the main window. It reads the
//  signed-in session's account + API key from `MainFeature` and offers logout.
//

import ComposableArchitecture
import SwiftUI

struct AccountView: View {
    let store: StoreOf<MainFeature>
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    LabeledContent("Name", value: store.account.name)
                    LabeledContent("Email", value: store.account.email)
                    LabeledContent("Replicants", value: "\(store.account.replicantCount)")
                }
                Section("API Key") {
                    Text(store.apiKey)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Section {
                    Button("Log Out", role: .destructive) {
                        store.send(.logoutButtonTapped)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Account")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(minWidth: 380, minHeight: 360)
    }
}
