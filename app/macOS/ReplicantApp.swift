//
//  ReplicantApp.swift
//  Replicant
//
//  Created by Matt Pennig on 6/12/26.
//

import API
import AccountManager
import AppKit
import BlueprintsFeature
import ComposableArchitecture
import GameDatabase
import GameModels
import GameServices
import GameSync
import LocationEventsFeature
import MessagesFeature
import SQLiteData
import SwiftUI
import UI
import UniverseModels
import Utils

@main
struct ReplicantApp: App {
    @State private var store: StoreOf<AppFeature>
    @Environment(\.openWindow) private var openWindow

    init() {
        // A failed schema bootstrap is a silently broken app (every @FetchAll
        // reads an empty void) — report it loudly instead of `try?`-ing it
        // away (V3.6-T3). The app still launches; the report names the cause.
        prepareDependencies { dependencies in
            withErrorReporting { try dependencies.bootstrapDatabase() }
        }
        // Construct the root store *after* the database is prepared
        _store = State(initialValue: Store(initialState: AppFeature.State()) { AppFeature() })
        // Order matters: `AccountManager` runs logout handlers in REGISTRATION
        // order, so ingestion teardown (the "gameSync" handler) must come
        // before the table wipes — a still-running route or gap repair would
        // otherwise repopulate freshly-cleared tables (and a live pipeline
        // frame would re-persist the just-cleared event cursor).
        registerGameSync()
        registerSessionCleanup()
    }

    /// Wire the event-stream ingestion service (`GameSync`): register each
    /// owning module's declared ingestion policy, hook start/stop into the
    /// session lifecycle, and kick it off now for a session restored
    /// synchronously at launch (which never fires `onLogin`). This is the
    /// composition root opting features into real-time ingestion — the
    /// *policies* (which events matter, what refresh they debounce into) live
    /// in the modules that own the tables (`MessagesIngestion`,
    /// `LocationsIngestion`, `LocationEventsIngestion`, `FTLMeshRefresher`);
    /// only the wiring lives here, and `GameSync` stays feature-agnostic.
    private func registerGameSync() {
        @Dependency(\.accountManager) var accountManager
        @Dependency(\.gameSync) var gameSync
        @Dependency(\.domainFreshness) var domainFreshness

        // The non-device domains' refresh policies (V3.5): each names the
        // authoritative re-read its event routes debounce into. Routes only
        // `invalidate(domain)` — a synchronous mark + trailing debounce — so
        // no refresh ever runs on the router's dispatch path (where a slow
        // read would head-of-line-block all event ingestion).
        domainFreshness.register(.inbox, MessagesIngestion.domainRegistration)
        domainFreshness.register(.locationEvents, LocationEventsIngestion.domainRegistration)
        domainFreshness.register(.ftlMesh, FTLMeshRefresher.domainRegistration)

        // The declared event routes. `locationsIngestion` is an instance: its
        // passive-scan debounce is mutable state with a teardown obligation
        // (cancelled in the logout handler below).
        let locationsIngestion = LocationsIngestion()
        for route in MessagesIngestion.eventRoutes { gameSync.registerRoute(route) }
        for route in locationsIngestion.eventRoutes { gameSync.registerRoute(route) }
        gameSync.registerRoute(LocationEventsIngestion.eventRoute)

        // Start consuming the stream on login, stop on logout. Registered FIRST
        // (init calls `registerGameSync()` before `registerSessionCleanup()`)
        // so ingestion is fully torn down before any table wipe runs.
        accountManager.registerHandler(
            SessionLifecycleHandler(
                id: "gameSync",
                onLogin: { await gameSync.start() },
                onLogout: {
                    await gameSync.stop()
                    // The route debounces live outside the engine's
                    // cancellation domain — cancel them here so a scan or
                    // domain refresh armed just before logout can't write into
                    // the freshly-wiped tables (or spend the next session's
                    // budget on the old account's behalf). `reset` also clears
                    // the freshness stamps, so the next session's first
                    // `refreshIfStale` can't mistake wiped tables for fresh.
                    locationsIngestion.cancelPendingWork()
                    domainFreshness.reset()
                }
            )
        )

        // A returning user's session is restored from the Keychain without a
        // login, so start the stream here too (start() is idempotent).
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
                // Clear the dock badge directly: the main window may already be
                // gone, so the view's reactive update can't be relied upon.
                await MainActor.run { NSApp.dockTile.badgeLabel = nil }
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
        accountManager.registerHandler(
            SessionLifecycleHandler(id: "operations", onLogout: {
                @Dependency(\.defaultDatabase) var database
                try? await database.write { db in try GameModels.Operation.delete().execute(db) }
            })
        )
        accountManager.registerHandler(
            SessionLifecycleHandler(id: "locationEvents", onLogout: {
                @Dependency(\.defaultDatabase) var database
                try? await database.write { db in try LocationEvent.delete().execute(db) }
            })
        )
        accountManager.registerHandler(
            SessionLifecycleHandler(id: "blueprints", onLogout: {
                @Dependency(\.defaultDatabase) var database
                try? await database.write { db in try Blueprint.delete().execute(db) }
            })
        )
        accountManager.registerHandler(
            SessionLifecycleHandler(id: "knownReplicants", onLogout: {
                @Dependency(\.defaultDatabase) var database
                try? await database.write { db in try KnownReplicant.delete().execute(db) }
            })
        )
        // Universe intel is account-scoped too: system details and location
        // footprints come from *this* account's scans (explored-gating), and the
        // FTL mesh from its relay fleet. A second account must not inherit them
        // — and the cold-load "table is empty" gates must fire for it.
        accountManager.registerHandler(
            SessionLifecycleHandler(id: "universe", onLogout: {
                @Dependency(\.defaultDatabase) var database
                try? await database.write { db in
                    try SystemDetail.delete().execute(db)
                    try LocationFootprint.delete().execute(db)
                    try FTLLinkRecord.delete().execute(db)
                }
            })
        )
        // The event-stream cursor is account-scoped: resuming a different
        // account from the previous account's cursor would skip its catch-up
        // (the cursor looks fresh) and replay a foreign id-space. The next
        // login then starts cold, seeding from the live tip.
        accountManager.registerHandler(
            SessionLifecycleHandler(id: "eventCursor", onLogout: {
                UserDefaultsEventCursorStore().clear()
            })
        )
        // Deliberately NOT cleared: `EventLog` — the SSE diagnostic ledger is
        // user-managed by design (cleared via the Event Log window's button),
        // and keeping it across sessions is part of its taxonomy-discovery job.
    }

    var body: some Scene {
        // The first-launch / sign-in window. It lives in its own window so the
        // login ⇄ main transition is a clean window hand-off, and so it can pin
        // itself to dark independently of the signed-in appearance preference.
        // Shown at launch only when there's no stored session. It's transient,
        // so it never participates in state restoration.
        Window("Welcome", id: WindowID.login) {
            LoginWindow(store: store)
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

                Button("Event Log") {
                    openWindow(id: WindowID.eventLog)
                }
                .keyboardShortcut("e", modifiers: [.command, .option])
                .disabled(store.isLoggedOut)
            }
        }

        // The direct API access window for power users. Opened on demand from the
        // Tools menu (never at launch) and follows the appearance preference.
        Window("Raw API Access", id: WindowID.rawAPI) {
            RawAPIWindow(store: store)
        }
        .defaultLaunchBehavior(.suppressed)

        // The SSE Event Log diagnostic window for power users. Opened on demand from
        // the Tools menu (never at launch) and follows the appearance preference.
        Window("Event Log", id: WindowID.eventLog) {
            EventLogWindow(store: store)
        }
        .defaultLaunchBehavior(.suppressed)

        // The Preferences window (⌘,), which follows the same appearance
        // preference as the main window.
        Settings {
            PreferencesView(store: store.scope(state: \.preferences, action: \.preferences))
                .applyAppAppearance(store.preferences.appearance)
        }
    }
}

/// Identifiers for the app's top-level windows.
enum WindowID {
    static let login = "login"
    static let main = "main"
    static let rawAPI = "rawAPI"
    static let eventLog = "eventLog"
}
