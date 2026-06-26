//
//  AccountView.swift
//  Replicant
//
//  Account information, presented as a sheet from the main window. It reads the
//  signed-in session's account + API key from `MainFeature` and offers logout.
//

import ComposableArchitecture
import DependencyClients
import SQLiteData
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

#Preview {
    let _ = prepareDependencies {
        let database = try! SQLiteData.defaultDatabase()
        var migrator = DatabaseMigrator()
        Replicant.registerMigrations(&migrator)
        try! migrator.migrate(database)
        $0.defaultDatabase = database
    }
    AccountView(
        store: Store(initialState: MainFeature.State(apiKey: "rk_live_0123456789abcdef")) {
            MainFeature()
        }
    )
}

