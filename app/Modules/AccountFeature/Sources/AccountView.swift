//
//  AccountView.swift
//  Replicould — Account feature
//
//  The account sheet: a three-tab screen (Profile · Settings · Achievements)
//  presented from the sidebar footer. A pure renderer over `AccountFeature` — it
//  seeds itself and loads achievements via `.task`, and every mutation flows
//  through the store.
//

import ComposableArchitecture
import GameModels
import SwiftUI
import UI

public struct AccountView: View {
    @Bindable var store: StoreOf<AccountFeature>
    @Environment(\.dismiss) private var dismiss

    public init(store: StoreOf<AccountFeature>) {
        self.store = store
    }

    public var body: some View {
        NavigationStack {
            TabView(selection: $store.selectedTab) {
                ProfileTab(store: store) { dismiss() }
                    .tabItem { Label("Profile", systemImage: "person.crop.circle") }
                    .tag(AccountFeature.Tab.profile)

                SettingsTab(store: store)
                    .tabItem { Label("Settings", systemImage: "slider.horizontal.3") }
                    .tag(AccountFeature.Tab.settings)

                AchievementsTab(store: store)
                    .tabItem { Label("Achievements", systemImage: "trophy") }
                    .tag(AccountFeature.Tab.achievements)
            }
            .navigationTitle("Account")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(minWidth: 460, minHeight: 480)
        .task { store.send(.task) }
    }
}
