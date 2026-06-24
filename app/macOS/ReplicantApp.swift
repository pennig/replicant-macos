//
//  ReplicantApp.swift
//  Replicant
//
//  Created by Matt Pennig on 6/12/26.
//

import ComposableArchitecture
import MessagesFeature
import SQLiteData
import StarMapFeature
import SwiftUI
import UI

@main
struct ReplicantApp: App {
    /// A single root store shared across every scene, so state (e.g. the
    /// appearance preference and the active session) stays consistent.
    @State private var store = Store(initialState: AppFeature.State()) {
        AppFeature()
    }

    @Environment(\.openWindow) private var openWindow

    init() {
        // Open the local database and run migrations before any view that
        // observes it appears. SQLiteData vends an on-disk store in the app and
        // an in-memory one in previews/tests.
        prepareDependencies { try? $0.bootstrapDatabase() }
    }

    var body: some Scene {
        // The first-launch / sign-in window. It lives in its own window so the
        // login ⇄ main transition is a clean window hand-off, and so it can pin
        // itself to dark independently of the signed-in appearance preference.
        // Shown at launch only when there's no stored session. It's transient,
        // so it never participates in state restoration.
        Window("Welcome", id: WindowID.login) {
            LoginWindow(store: store)
                .background(WindowConfigurator())
        }
        .defaultLaunchBehavior(store.isLoggedOut ? .presented : .suppressed)
        .restorationBehavior(.disabled)

        // The signed-in main experience, in its own window so it can follow the
        // appearance preference via `preferredColorScheme`. Shown at launch when
        // a session was restored synchronously from the Keychain.
        Window("Dashboard", id: WindowID.main) {
            MainWindow(store: store)
                .background(WindowConfigurator())
        }
        .defaultLaunchBehavior(store.isLoggedOut ? .suppressed : .presented)
        .commands {
            // Power-user direct API access, reachable once signed in.
            CommandMenu("Tools") {
                Button("Raw API Access") {
                    openWindow(id: WindowID.rawAPI)
                }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(store.isLoggedOut)
            }
        }

        // The direct API access window for power users. Opened on demand from the
        // Tools menu (never at launch) and follows the appearance preference.
        Window("Raw API Access", id: WindowID.rawAPI) {
            RawAPIWindow(store: store)
                .background(WindowConfigurator())
        }
        .defaultLaunchBehavior(.suppressed)

        // The Preferences window (⌘,), which follows the same appearance
        // preference as the main window.
        Settings {
            PreferencesView(store: store.scope(state: \.preferences, action: \.preferences))
                .background(WindowConfigurator())
                .applyAppAppearance(store.preferences.appearance)
        }
    }
}

/// Identifiers for the app's top-level windows.
enum WindowID {
    static let login = "login"
    static let main = "main"
    static let rawAPI = "rawAPI"
}

// MARK: - Database bootstrap

extension DependencyValues {
    /// Opens the default database and runs every feature's migrations. Called
    /// once from the app entry point's `prepareDependencies`. SQLiteData vends an
    /// in-memory store automatically in test and preview contexts. The app owns
    /// this composition so each feature contributes its own table schema.
    mutating func bootstrapDatabase() throws {
        let database = try SQLiteData.defaultDatabase()
        var migrator = DatabaseMigrator()
        #if DEBUG
        migrator.eraseDatabaseOnSchemaChange = true
        #endif
        Message.registerMigrations(&migrator)
        Star.registerMigrations(&migrator)
        try migrator.migrate(database)
        defaultDatabase = database
    }
}
