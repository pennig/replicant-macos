//
//  ReplicantApp.swift
//  Replicant
//
//  Created by Matt Pennig on 6/12/26.
//

import API
import AccountManager
import ComposableArchitecture
import DependencyClients
import GameSync
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
        registerSessionCleanup()
        registerGameSync()
    }

    /// Wire the relay ingestion service (`GameSync`): register the routes that
    /// map relay event types onto feature tables, hook start/stop into the
    /// session lifecycle, and kick it off now for a session restored
    /// synchronously at launch (which never fires `onLogin`). This is the
    /// composition root opting features into real-time ingestion — `GameSync`
    /// itself stays feature-agnostic.
    private func registerGameSync() {
        @Dependency(\.accountManager) var accountManager
        @Dependency(\.gameSync) var gameSync

        // "message": a relay message event is a thin notification (no id or
        // read-state — its content lives at the envelope's top level), so the
        // route triggers one authoritative inbox read instead of upserting from
        // the event. The resulting rows land in the same `Message` table the
        // Messages feature observes via @FetchAll, making the inbox live with no
        // change to that feature. Request coalescing/TTL arrives with the Phase 4
        // poll coordinator.
        gameSync.registerRoute(
            RelayRoute(id: "message", type: "message") { _ in
                @Dependency(\.messagesClient) var messagesClient
                @Dependency(\.defaultDatabase) var database
                guard let page = try? await messagesClient.fetch(nil, 50, false) else { return }
                try? await database.write { db in
                    for message in page.messages {
                        try Message.upsert { message }.execute(db)
                    }
                }
            }
        )

        // Start consuming the relay on login, stop on logout.
        accountManager.registerHandler(
            SessionLifecycleHandler(
                id: "gameSync",
                onLogin: { await gameSync.start() },
                onLogout: { await gameSync.stop() }
            )
        )

        // A returning user's session is restored from the Keychain without a
        // login, so start the relay here too (start() is idempotent).
        if accountManager.restoredAPIKey() != nil {
            Task { await gameSync.start() }
        }
    }

    /// Register each feature's logout cleanup with the `AccountManager`, so
    /// signing out wipes their locally-persisted tables (the account profile and
    /// replicant roster are cleared by the manager itself). This is where the
    /// composition root opts features into the session lifecycle.
    private func registerSessionCleanup() {
        @Dependency(\.accountManager) var accountManager
        accountManager.registerHandler(
            SessionLifecycleHandler(id: "messages", onLogout: {
                @Dependency(\.defaultDatabase) var database
                try? await database.write { db in try Message.delete().execute(db) }
            })
        )
        accountManager.registerHandler(
            SessionLifecycleHandler(id: "stars", onLogout: {
                @Dependency(\.defaultDatabase) var database
                try? await database.write { db in try Star.delete().execute(db) }
            })
        )
        accountManager.registerHandler(
            SessionLifecycleHandler(id: "devices", onLogout: {
                @Dependency(\.defaultDatabase) var database
                try? await database.write { db in try Device.delete().execute(db) }
            })
        )
        accountManager.registerHandler(
            SessionLifecycleHandler(id: "bobnet", onLogout: {
                @Dependency(\.defaultDatabase) var database
                try? await database.write { db in try BobnetMessage.delete().execute(db) }
            })
        )
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
                .ignoresSafeArea(.container, edges: .top)
        }
        .defaultSize(width: 640, height: 520)
        .defaultLaunchBehavior(store.isLoggedOut ? .presented : .suppressed)
        .restorationBehavior(.disabled)
        .commandsRemoved()

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
        Replicant.registerMigrations(&migrator)
        Device.registerMigrations(&migrator)
        BobnetMessage.registerMigrations(&migrator)
        try migrator.migrate(database)
        defaultDatabase = database
    }
}
