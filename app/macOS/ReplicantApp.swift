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
        // The first-launch / sign-in window. It lives in its own window so the
        // login ⇄ main transition is a clean window hand-off, and so it can pin
        // itself to dark independently of the signed-in appearance preference.
        // Shown at launch only when there's no stored session. It's transient,
        // so it never participates in state restoration.
        Window("Welcome", id: WindowID.login) {
            LoginWindow(store: store)
        }
        .defaultLaunchBehavior(store.isLoggedOut ? .presented : .suppressed)
        .restorationBehavior(.disabled)

        // The signed-in main experience, in its own window so it can follow the
        // appearance preference via `preferredColorScheme`. Shown at launch when
        // a session was restored synchronously from the Keychain.
        Window("Dashboard", id: WindowID.main) {
            MainWindow(store: store)
        }
        .defaultLaunchBehavior(store.isLoggedOut ? .suppressed : .presented)

        // The Preferences window (⌘,), which follows the same appearance
        // preference as the main window.
        Settings {
            PreferencesView(store: store.scope(state: \.preferences, action: \.preferences))
                .preferredColorScheme(store.preferences.appearance.colorScheme)
        }
    }
}

/// Identifiers for the app's top-level windows.
enum WindowID {
    static let login = "login"
    static let main = "main"
}
