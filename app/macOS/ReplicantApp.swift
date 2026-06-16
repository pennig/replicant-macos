//
//  ReplicantApp.swift
//  Replicant
//
//  Created by Matt Pennig on 6/12/26.
//

import ComposableArchitecture
import SwiftUI

@main
struct ReplicantApp: App {
    /// A single root store shared across every scene, so state (e.g. the
    /// appearance preference and the active session) stays consistent.
    @State private var store = Store(initialState: AppFeature.State()) {
        AppFeature()
    }

    var body: some Scene {
        WindowGroup {
            AppView(store: store)
        }

        // The Account window — opened from the sidebar footer.
        Window("Account", id: ReplicantWindow.account) {
            AccountWindowRoot(store: store)
        }
        .defaultSize(width: 420, height: 360)
        .windowResizability(.contentSize)

        // The Preferences window (⌘,). Applies to every window except the
        // first-launch screen, which is always dark.
        Settings {
            PreferencesView(store: store.scope(state: \.preferences, action: \.preferences))
                .preferredColorScheme(store.preferences.appearance.colorScheme)
        }
    }
}
