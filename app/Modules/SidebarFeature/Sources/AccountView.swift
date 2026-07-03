//
//  AccountView.swift
//  Replicould — Sidebar feature
//
//  Account information, presented as a sheet from the sidebar footer. It reads
//  the signed-in session's account + API key from `SidebarFeature` and offers
//  logout (which bubbles up to the app root to tear the session down).
//

import ComposableArchitecture
import GameModels
import SwiftUI

struct AccountView: View {
    let store: StoreOf<SidebarFeature>
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    LabeledContent("Name", value: store.account.name)
                    LabeledContent("Email", value: store.account.email)
                    LabeledContent("Replicants", value: "\(store.replicants.count)")
                }
                Section("API Key") {
                    Text(store.apiKey)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Account")
            .toolbar {
                ToolbarItem(placement: .destructiveAction) {
                    Button("Log Out", role: .destructive) {
                        dismiss()
                        store.send(.logoutButtonTapped)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(minWidth: 380, minHeight: 360)
    }
}
