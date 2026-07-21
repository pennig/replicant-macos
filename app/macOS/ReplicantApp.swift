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
        prepareDependencies { try? $0.bootstrapDatabase() }
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

    /// Wire the relay ingestion service (`GameSync`): register the routes that
    /// map relay event types onto feature tables, hook start/stop into the
    /// session lifecycle, and kick it off now for a session restored
    /// synchronously at launch (which never fires `onLogin`). This is the
    /// composition root opting features into real-time ingestion — `GameSync`
    /// itself stays feature-agnostic.
    private func registerGameSync() {
        @Dependency(\.accountManager) var accountManager
        @Dependency(\.gameSync) var gameSync
        @Dependency(\.domainFreshness) var domainFreshness

        // Register the non-device domains' refresh policies (V3.5): each names
        // the authoritative re-read its event routes debounce into. The routes
        // below then only `invalidate(domain)` — a synchronous mark + trailing
        // debounce — so no refresh ever runs on the router's dispatch path
        // (where a slow read would head-of-line-block all event ingestion).

        // Inbox: a message/story event is a thin notification (no id or
        // read-state — its content lives at the envelope's top level), so the
        // refresh is one authoritative head-page inbox read. The rows land in
        // the same `Message` table the Messages feature observes via @FetchAll,
        // making the inbox live with no change to that feature.
        let refreshInbox: @Sendable () async -> Bool = {
            @Dependency(\.messagesClient) var messagesClient
            @Dependency(\.defaultDatabase) var database
            guard let page = try? await messagesClient.fetch(nil, 50, false) else { return false }
            let wrote = try? await database.write { db in
                for message in page.messages {
                    try Message.upsert { message }.execute(db)
                }
            }
            return wrote != nil
        }
        domainFreshness.register(.inbox, DomainRegistration(refresh: refreshInbox))

        // Location events (quests): the authoritative shape (criteria, live
        // progress, rewards) lives at `accounts/events`, re-read wholesale.
        domainFreshness.register(.locationEvents, DomainRegistration(refresh: {
            @Dependency(\.locationEventsClient) var locationEventsClient
            return (try? await locationEventsClient.refresh()) != nil
        }))

        // FTL mesh: O(relays) serial network reads — the single most expensive
        // refresh an event can trigger, and exactly why applies must stay off
        // the dispatch path (V3.4-B2). The rebuild is best-effort per relay by
        // design (an unreachable relay is skipped, not an error), so it always
        // counts as a refresh.
        domainFreshness.register(.ftlMesh, DomainRegistration(refresh: {
            @Dependency(\.ftlMeshRefresher) var ftlMeshRefresher
            await ftlMeshRefresher.refresh()
            return true
        }))

        // "message": an overnight catch-up can replay a dozen message events —
        // debounced, they cost one head-page read after the burst (V3.4-B3).
        //
        // The same authoritative inbox read is this channel's **tier-2 gap
        // repair** (§4.5): on a cold start or a reconnect beyond the stream's
        // cursor retention, `gapRepair` recovers messages that arrived while
        // disconnected — the REST inbox is authoritative, so a head-page re-read
        // is the catch-up. Deliberately direct (not debounced): it must run even
        // when no message event replays at all.
        gameSync.registerRoute(
            EventRoute(
                id: "message",
                match: .category("message"),
                apply: { _ in domainFreshness.invalidate(.inbox) },
                gapRepair: { _ = await refreshInbox() }
            )
        )

        // `story.*`: narrative beats (Bill/Riker updates, first-contact reports)
        // are pushed over the stream for immediacy, but the backend also persists
        // them to the inbox as ordinary messages (`message_type: "story"`). The
        // stream copy carries no id/read-state, so — exactly like the "message"
        // route — a story event nudges the same debounced inbox re-read; the new
        // row lands in the same `Message` table the inbox observes, arriving
        // live instead of on the next poll. No `gapRepair` needed: the "message"
        // route's head-page re-read already recovers stories missed while
        // disconnected.
        gameSync.registerRoute(
            EventRoute(id: "messages.story", match: .category("story")) { _ in
                domainFreshness.invalidate(.inbox)
            }
        )

        // "event" (Locations): passively refresh the catalog. Shops,
        // megastructures/objects, and the outer system live ONLY in the scan
        // response (never the locations endpoint), so when an event implies the
        // current system's observable state changed — an arrival, a megastructure
        // contribution, a new object/threat, a shop or location event — re-scan
        // (free, current-system) and merge into `SystemDetail`. Excludes
        // scan-echo event types so our own scan can't feed back into a loop.
        //
        // A scan only ever reads *this replicant's current location*, so an event
        // is worth a scan only when it actually concerns that location, and a
        // host-vessel arrival additionally advances the roster location. That whole
        // policy — the arrival host-device gate, the location-scoped current-system
        // gate, and the arrival→location derivation — lives in (and is tested by)
        // `LocationEventPolicy.decide`; this route just applies its decision.
        //
        // A scan reads the current location's *current* state, so a burst of
        // relevant events needs exactly one scan to converge — not one per event.
        // This matters most at launch: tier-2 backfill replays a batch of recent
        // events through the routes, and events dispatch *serially* (see
        // `EventRouter.dispatch`), so a per-event scan fires a redundant scan for
        // each replayed event. A trailing debounce collapses the burst: each
        // relevant event (re)arms a short timer, and a single scan runs once the
        // events quiet — the same live state one immediate scan would have read.
        let pendingPassiveScan = LockIsolated<Task<Void, Never>?>(nil)
        gameSync.registerRoute(
            EventRoute(id: "locations.scan", match: .all) { event in
                @Dependency(\.defaultDatabase) var database
                // The replicant the event pertains to (else the sole/first on the
                // roster) — the source of the host-device and current-system gates.
                let replicant = try? await database.read { db -> Replicant? in
                    if let code = event.replicantCode,
                       let match = try Replicant.where({ $0.replicantCode.eq(code) }).fetchOne(db) {
                        return match
                    }
                    return try Replicant.fetchAll(db).first
                }
                guard let replicant, !replicant.replicantCode.isEmpty else { return }
                let code = replicant.replicantCode

                let decision = LocationEventPolicy.decide(event: event, replicant: replicant)

                // A host-vessel arrival IS the authoritative location change: fold
                // the destination straight into the roster row so `currentStar` /
                // `currentLocation` are never stale between the move and the next
                // `accounts/me` refresh. The name columns are cleared (the arrival
                // carries no display names, and the UI falls back to the mono
                // designation) — except the star name survives an intra-system hop.
                //
                // Only *live stream* arrivals move the roster. A catch-up arrival
                // is history being replayed on launch (see `EventPipeline.catchUp`):
                // folding those in would walk the roster through stale waypoints —
                // the location flicker — before settling. The roster's launch truth
                // is `accounts/me`; catch-up exists to repair the other tables
                // (devices, etc.), which it still does.
                if event.provenance == .stream, let update = decision.rosterUpdate {
                    let priorStarName = replicant.currentStarName
                    try? await database.write { db in
                        try Replicant.where { $0.replicantCode.eq(code) }.update {
                            $0.currentStar = #bind(update.star)
                            $0.currentLocation = #bind(update.location)
                            $0.currentStarName = #bind(update.systemChanged ? nil : priorStarName)
                            $0.currentLocationName = #bind(String?.none)
                        }
                        .execute(db)
                    }
                }

                guard decision.shouldScan else { return }

                // Debounce: cancel any scan still waiting out its window and re-arm.
                pendingPassiveScan.withValue { pending in
                    pending?.cancel()
                    pending = Task {
                        try? await Task.sleep(for: .seconds(2))
                        guard !Task.isCancelled else { return }
                        @Dependency(\.locationsClient) var locationsClient
                        try? await locationsClient.scanAndPersist(replicantCode: code)
                    }
                }
            }
        )

        // "event" (Locations catalog): fold catalog data carried in event payloads
        // straight into `SystemDetail`, so the Locations view and gather_salvage
        // picker stay current with no `body(_:)`/`scan` API call. This is the one
        // dispatch table for payload-scraped catalog updates — a new event that
        // carries catalog data is a new `case` here plus one `LocationsClient`
        // method, nothing more. Every handler is best-effort and idempotent.
        gameSync.registerRoute(
            EventRoute(id: "locations.catalog", match: .all) { event in
                @Dependency(\.locationsClient) var locationsClient
                let payload = event.payload
                // Prefer the envelope's first-class `location`; fall back to payload.
                let location = event.location ?? payload?["location"]?.stringValue
                switch event.event {
                case "scan.completed":
                    // Full scanned body (physical, salvage, sites, inventory).
                    if let payload {
                        _ = try? await locationsClient.ingestScanResult(payload: payload)
                    }
                case "salvage.depleted":
                    // A salvage site at `location` is fully spent.
                    if let location {
                        _ = try? await locationsClient.markSalvageDepleted(location: location)
                    }
                // NOTE: the resource-level salvage-depletion event's new dotted name
                // is unconfirmed post-migration; it will surface in the event log so
                // the case can be added once its name/payload are known.
                default:
                    break
                }
            }
        )

        // "event" (Location Events): the galaxy publishes quests — calls for
        // resources or devices sited at a location. Discovery and progress both
        // surface as relay events, but the authoritative shape (criteria, live
        // progress, rewards) lives at `accounts/events`. So, like the inbox, a
        // nudge triggers one authoritative re-read that upserts the quest log; the
        // Location Events screen and its sidebar badge observe that table live.
        // The same re-read is this channel's tier-2 gap repair (a cold-start /
        // reconnect catch-up), so `apply` (gated on the trigger) and `gapRepair`
        // (unconditional) share one trigger.
        //
        // Each trigger re-reads the *whole* `accounts/events` list (cursor-paged
        // from the top), so a burst of qualifying events — tier-1 replay + tier-2
        // backfill at launch, or several quests landing together — would fire a
        // stack of identical full re-reads. One re-read after the burst reads
        // the same live state, so the domain's trailing debounce collapses the
        // burst into a single refresh once events quiet.
        gameSync.registerRoute(
            EventRoute(
                id: "locationEvents",
                match: .all,
                apply: { event in
                    // Quests surface as the `event.*` family (`event.discovered` /
                    // `event.completed`); a fresh scan can also reveal one.
                    guard event.category == "event" || event.event == "scan.completed"
                    else { return }
                    domainFreshness.invalidate(.locationEvents)
                },
                gapRepair: { domainFreshness.invalidate(.locationEvents) }
            )
        )

        // Start consuming the relay on login, stop on logout. Registered FIRST
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
                    pendingPassiveScan.withValue { $0?.cancel(); $0 = nil }
                    domainFreshness.reset()
                }
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
