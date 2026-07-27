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
import DirectiveEngine
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
import os

private let logger = Logger(subsystem: "name.pennig.replicould", category: "ReplicantApp")

@main
struct ReplicantApp: App {
    @State private var store: StoreOf<AppFeature>
    @Environment(\.openWindow) private var openWindow

    init() {
        // A reset armed by the Tools menu relaunches a second instance before
        // this one has quit (NSWorkspace has no "replace running instance"
        // option, and the sandbox blocks exec-ing a shell to wait on the old
        // PID). If this instance bootstraps while the old one is still alive,
        // two processes hold the same SQLite file open: GRDB's default
        // `.immediateError` busy mode makes `erase()` throw the instant the
        // old process holds any lock (ingestion, the directive engine, a
        // `@FetchAll` observer), and if erase wins the race instead, the old
        // process's still-running ingestion can write rows back afterward —
        // resurrecting exactly the data being deleted. So: wait here, before
        // any dependency (let alone the database) is touched.
        #if DEBUG
        Self.awaitSoleInstanceIfResetPending()
        #endif
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
        @Dependency(\.directiveEngine) var directiveEngine

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
        // `directive.*` had no route at all before Stage 3. It only writes a
        // `DirectiveLogEntry`; the engine observes that row rather than the
        // event, which is what keeps observe-reconciled-state intact.
        gameSync.registerRoute(DirectiveIngestion.eventRoute)

        // Start consuming the stream on login, stop on logout. Registered FIRST
        // (init calls `registerGameSync()` before `registerSessionCleanup()`)
        // so ingestion is fully torn down before any table wipe runs.
        accountManager.registerHandler(
            SessionLifecycleHandler(
                id: "gameSync",
                onLogin: {
                    await gameSync.start()
                    // After ingestion: the engine reads reconciled tables, so
                    // it should never be running while the stream that fills
                    // them is not.
                    await directiveEngine.start()
                },
                onLogout: {
                    // Executors FIRST: a directive step must never POST — or
                    // write a log row — after the tables it reads are cleared.
                    // The wipes themselves run in `registerSessionCleanup`'s
                    // handlers, registered later and therefore run later.
                    await directiveEngine.stop()
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
            Task {
                await gameSync.start()
                await directiveEngine.start()
            }
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
            SessionLifecycleHandler(id: "siteAssays", onLogout: {
                @Dependency(\.defaultDatabase) var database
                try? await database.write { db in try SiteAssay.delete().execute(db) }
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
                try? await database.write { db in
                    try BobnetMessage.delete().execute(db)
                    try BobnetChannel.delete().execute(db)
                }
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
            // The species roster is global, but the merged `totalReputation`
            // column is account-scoped — wipe the table so a second account
            // re-cold-loads instead of inheriting the first's standings.
            SessionLifecycleHandler(id: "civilisations", onLogout: {
                @Dependency(\.defaultDatabase) var database
                try? await database.write { db in try Civilisation.delete().execute(db) }
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
        // Directives are account-scoped: a second account on this machine must
        // not inherit the first's missions or their audit trail. The engine's
        // executors are cancelled by the gameSync handler, registered FIRST —
        // so the wipe below can never race a live write.
        accountManager.registerHandler(
            SessionLifecycleHandler(id: "directives", onLogout: {
                @Dependency(\.defaultDatabase) var database
                try? await database.write { db in
                    try Directive.delete().execute(db)
                    try DirectiveLogEntry.delete().execute(db)
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

    #if DEBUG
    /// Blocks until every other running instance of this app has quit, when
    /// (and only when) a reset is pending. Called at the very top of `init()`,
    /// before any dependency — let alone the database — is touched, so the
    /// new instance never bootstraps (and therefore never erases) while an
    /// old instance might still hold the SQLite file open.
    ///
    /// Uses `isPending` rather than `consumeRequest`: consuming here would
    /// burn the flag before `bootstrapDatabase()` gets a chance to act on it.
    ///
    /// Bounded at 10 seconds rather than waited on indefinitely — a stuck old
    /// instance (e.g. hung in a modal) must not make the app unlaunchable.
    /// Falling through after the deadline reintroduces the original race for
    /// that one launch, which is still strictly better than never launching.
    private static func awaitSoleInstanceIfResetPending() {
        guard DatabaseReset.isPending(
            defaults: .standard,
            environment: ProcessInfo.processInfo.environment
        ) else { return }
        guard let bundleID = Bundle.main.bundleIdentifier else { return }

        let me = ProcessInfo.processInfo.processIdentifier
        let deadline = Date().addingTimeInterval(10)
        logger.notice("Reset pending — waiting for other \(bundleID) instances to quit before bootstrapping.")
        while Date() < deadline {
            let others = NSRunningApplication
                .runningApplications(withBundleIdentifier: bundleID)
                .filter { $0.processIdentifier != me }
            if others.isEmpty {
                logger.notice("Sole instance confirmed — proceeding to bootstrap.")
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        // Fall through after the deadline rather than hanging forever — a
        // stuck old instance shouldn't make the app unlaunchable.
        logger.error("Timed out after 10s waiting for other \(bundleID) instances to quit — bootstrapping anyway.")
    }

    /// Arms a database reset and relaunches. The wipe itself happens at the
    /// next bootstrap, before ingestion or any observer is running — see
    /// `DatabaseReset`. The Keychain session is untouched, so the app comes
    /// back signed in and the catalogue can be reloaded straight away.
    private func confirmDatabaseReset() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Reset the local database?"
        alert.informativeText = """
            Every locally cached table is erased and rebuilt on relaunch, \
            including the stars catalogue and surveyed locations. The stars \
            catalogue endpoint is rate limited to roughly one call a minute, \
            and locations rehydrate only when selected.

            You stay signed in.
            """
        alert.addButton(withTitle: "Reset and Relaunch")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        DatabaseReset.requestOnNextLaunch()

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(
            at: Bundle.main.bundleURL,
            configuration: configuration
        ) { _, error in
            if let error {
                // The flag is already armed and durably written, so leaving
                // this instance running (instead of vanishing with no
                // explanation) means the user can just try again — or the
                // next ordinary launch still picks up the reset.
                logger.error("Failed to relaunch for database reset: \(error.localizedDescription). App remains running; reset stays armed for next launch.")
                return
            }
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
    #endif

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

                #if DEBUG
                Divider()

                Button("Reset Local Database…") {
                    confirmDatabaseReset()
                }
                #endif
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
