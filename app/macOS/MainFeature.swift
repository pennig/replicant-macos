//
//  MainFeature.swift
//  Replicant
//
//  The signed-in experience: a three-column NavigationSplitView. The sidebar
//  (header · grouped categories · footer) is its own `SidebarFeature`; this
//  container just scopes the per-category content + detail features and lets the
//  sidebar's selection drive which panes show. The Account sheet lives in the
//  sidebar.
//

import AccountFeature
import AccountManager
import AppKit
import BlueprintsFeature
import ComposableArchitecture
import DevicesFeature
import GameModels
import GameServices
import LocationEventsFeature
import LocationsFeature
import MessagesFeature
import NewStarMapFeature
import PrintQueueFeature
import RawAPIFeature
import ReplicantsFeature
import SQLiteData
import SidebarFeature
import SwiftUI
import UI
import Utils

// MARK: - Main feature

@Reducer
struct MainFeature {
    @ObservableState
    struct State: Equatable {
        var apiKey: String
        /// The content-pane selection for placeholder categories (real features
        /// own their own selection). Reset whenever the sidebar category changes.
        var detailSelection: String?
        /// The sidebar: active-replicant header, category list, account footer.
        /// Owns the category selection this container reads to pick its panes.
        var sidebar: SidebarFeature.State
        /// The Account sheet (identity · settings · achievements), presented from
        /// the sidebar footer. Its own feature; owns logout.
        @Presents var account: AccountFeature.State?
        /// The Messages inbox, persisted locally and seeded with the session key.
        var messages: MessagesFeature.State
        /// The Raw API Access experience, shown in its own window (Tools menu).
        /// Seeded with the session API key so requests authenticate as this user.
        var rawAPI: RawAPIFeature.State
        /// The Galaxy Map (Stars view)
        var newStarMap: NewStarMapFeature.State
        /// The live fleet (Devices view) — list + inspector + command dispatch.
        var devices: DevicesFeature.State
        /// The unlocked blueprint catalog (Blueprints view) — list + inspector.
        var blueprints: BlueprintsFeature.State
        /// The stellar-locations catalog (Locations view) — disclosure list + inspector.
        var locations: LocationsFeature.State
        /// The Location Events quest log (Missions) — discovered events + quest sheet.
        var locationEvents: LocationEventsFeature.State
        /// The Print Queue (Operations) — printers with an active job or queue.
        var printQueue: PrintQueueFeature.State
        /// The Replicants directory — the account's own replicants plus every
        /// other player and NPC known in the galaxy.
        var replicantDirectory: ReplicantsFeature.State

        init(
            apiKey: String,
            category: SidebarItem? = .devices,
            detailSelection: String? = nil
        ) {
            self.apiKey = apiKey
            self.detailSelection = detailSelection
            self.sidebar = SidebarFeature.State(category: category)
            self.messages = MessagesFeature.State()
            self.rawAPI = RawAPIFeature.State(apiKey: apiKey)
            self.newStarMap = NewStarMapFeature.State()
            self.devices = DevicesFeature.State()
            self.blueprints = BlueprintsFeature.State()
            self.locations = LocationsFeature.State()
            self.locationEvents = LocationEventsFeature.State()
            self.printQueue = PrintQueueFeature.State()
            self.replicantDirectory = ReplicantsFeature.State()
        }
    }

    @Dependency(\.accountManager) var accountManager

    enum Action: BindableAction {
        case binding(BindingAction<State>)
        /// The signed-in experience appeared — re-sync the account roster from the
        /// server (login isn't re-run for a restored session).
        case task
        case delegate(Delegate)
        case sidebar(SidebarFeature.Action)
        case account(PresentationAction<AccountFeature.Action>)
        case messages(MessagesFeature.Action)
        case rawAPI(RawAPIFeature.Action)
        case newStarMap(NewStarMapFeature.Action)
        case devices(DevicesFeature.Action)
        case blueprints(BlueprintsFeature.Action)
        case locations(LocationsFeature.Action)
        case locationEvents(LocationEventsFeature.Action)
        case printQueue(PrintQueueFeature.Action)
        case replicantDirectory(ReplicantsFeature.Action)

        enum Delegate {
            case loggedOut
        }
    }

    var body: some Reducer<State, Action> {
        BindingReducer()
        Scope(state: \.sidebar, action: \.sidebar) {
            SidebarFeature()
        }
        Scope(state: \.messages, action: \.messages) {
            MessagesFeature()
        }
        Scope(state: \.rawAPI, action: \.rawAPI) {
            RawAPIFeature()
        }
        Scope(state: \.newStarMap, action: \.newStarMap) {
            NewStarMapFeature()
        }
        Scope(state: \.devices, action: \.devices) {
            DevicesFeature()
        }
        Scope(state: \.blueprints, action: \.blueprints) {
            BlueprintsFeature()
        }
        Scope(state: \.locations, action: \.locations) {
            LocationsFeature()
        }
        Scope(state: \.locationEvents, action: \.locationEvents) {
            LocationEventsFeature()
        }
        Scope(state: \.printQueue, action: \.printQueue) {
            PrintQueueFeature()
        }
        Scope(state: \.replicantDirectory, action: \.replicantDirectory) {
            ReplicantsFeature()
        }
        Reduce { state, action in
            switch action {
            case .binding:
                return .none

            case .task:
                // Restored sessions skip login, so the roster can be stale (or
                // empty after a DB reset). Re-fetch it so the sidebar and the
                // Replicants directory's own set are current.
                return .run { _ in await accountManager.refreshAccount() }

            case .delegate:
                return .none

            case .sidebar(.delegate(.accountButtonTapped)):
                // Present the Account sheet, seeded with the session key.
                state.account = AccountFeature.State(apiKey: state.apiKey)
                return .none

            case .account(.presented(.delegate(.loggedOut))):
                // Dismiss the sheet, then bubble logout to the app root.
                state.account = nil
                return .send(.delegate(.loggedOut))

            case .sidebar(.delegate(.categoryChanged)):
                // The category changed — the placeholder detail selection is stale.
                state.detailSelection = nil
                return .none

            case let .newStarMap(.delegate(.openDevice(code))):
                // A ship dossier's "View device" — switch to the Devices category and
                // select it so the inspector opens on that device.
                state.sidebar.category = .devices
                state.devices.selectedDeviceCode = code
                return .none

            case .sidebar, .account, .messages, .rawAPI, .newStarMap, .devices, .blueprints, .locations, .locationEvents, .printQueue, .replicantDirectory:
                return .none
            }
        }
        .ifLet(\.$account, action: \.account) {
            AccountFeature()
        }
    }
}

// MARK: - Main view

struct MainView: View {
    @Bindable var store: StoreOf<MainFeature>
    /// Live unread-message count, observed straight from SQLite, mirrored onto the
    /// app's dock-tile badge. (The sidebar renders its own badge independently.)
    @FetchOne(Message.where { !$0.isRead }.count()) private var unreadCount = 0

    var body: some View {
        Group {
            if store.sidebar.category?.hasDetail == false {
                // Content-only category (Operations Log): a two-column split view —
                // sidebar + content, with no detail column at all.
                NavigationSplitView {
                    sidebar  
                        .navigationSplitViewColumnWidth(min: 240, ideal: 240, max: 300)
                } detail: {
                    ZStack {
                        Color.rcWindowBackground.ignoresSafeArea()
                        content
                    }
                }
            } else {
                NavigationSplitView {
                    sidebar
                        .navigationSplitViewColumnWidth(min: 240, ideal: 240, max: 300)
                } content: {
                    content
                        .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 420)
                        .background(.rcWindowBackground)
                } detail: {
                    detail
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.rcContentBackground)
                        .toolbar { Text("") } // force toolbar content to get the glass effect to appear above detail content (wtf).
                }
            }
        }
        // The Account sheet (identity · settings · achievements), driven from the
        // sidebar footer via `MainFeature`'s presentation state.
        .sheet(item: $store.scope(state: \.account, action: \.account)) { accountStore in
            AccountView(store: accountStore)
        }
        // Re-sync the account roster on launch (a restored session skips login).
        .task { store.send(.task) }
        // Mirror the unread count onto the dock icon so it's visible when the
        // app is in the background. Cleared (nil) whenever the inbox is caught up.
        .onChange(of: unreadCount, initial: true) { _, count in
            NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
        }
    }

    // — Sidebar (its own feature) —
    private var sidebar: some View {
        SidebarView(store: store.scope(state: \.sidebar, action: \.sidebar))
    }

    /// The Messages inbox store, scoped from the main session.
    private var messagesStore: StoreOf<MessagesFeature> {
        store.scope(state: \.messages, action: \.messages)
    }

    /// The Metal star map store, scoped from the main session.
    private var newStarMapStore: StoreOf<NewStarMapFeature> {
        store.scope(state: \.newStarMap, action: \.newStarMap)
    }

    /// The Devices store, scoped from the main session.
    private var devicesStore: StoreOf<DevicesFeature> {
        store.scope(state: \.devices, action: \.devices)
    }

    /// The Blueprints store, scoped from the main session.
    private var blueprintsStore: StoreOf<BlueprintsFeature> {
        store.scope(state: \.blueprints, action: \.blueprints)
    }

    /// The Locations catalog store, scoped from the main session.
    private var locationsStore: StoreOf<LocationsFeature> {
        store.scope(state: \.locations, action: \.locations)
    }

    /// The Location Events quest-log store, scoped from the main session.
    private var locationEventsStore: StoreOf<LocationEventsFeature> {
        store.scope(state: \.locationEvents, action: \.locationEvents)
    }

    /// The Print Queue store, scoped from the main session.
    private var printQueueStore: StoreOf<PrintQueueFeature> {
        store.scope(state: \.printQueue, action: \.printQueue)
    }

    /// The Replicants directory store, scoped from the main session.
    private var replicantsStore: StoreOf<ReplicantsFeature> {
        store.scope(state: \.replicantDirectory, action: \.replicantDirectory)
    }

    // — Content: a selectable list (or, for the Operations Log, a plain list) —
    @ViewBuilder private var content: some View {
        if store.sidebar.category == .messages {
            MessagesListView(store: messagesStore)
        } else if store.sidebar.category == .stars {
            NewStarMapView(store: newStarMapStore)
        } else if store.sidebar.category == .devices {
            DevicesListView(store: devicesStore)
        } else if store.sidebar.category == .blueprints {
            BlueprintsListView(store: blueprintsStore)
        } else if store.sidebar.category == .locations {
            LocationsListView(store: locationsStore)
        } else if store.sidebar.category == .locationEvents {
            LocationEventsListView(store: locationEventsStore)
        } else if store.sidebar.category == .printQueue {
            PrintQueueListView(store: printQueueStore)
        } else if store.sidebar.category == .replicants {
            ReplicantsListView(store: replicantsStore)
        } else if store.sidebar.category == .operationsLog {
            ActivityView()
        } else if store.sidebar.category == .bobnet {
            BobnetView()
        } else if let category = store.sidebar.category {
            if category.hasDetail {
                List(selection: $store.detailSelection) {
                    ForEach(category.sampleItems, id: \.self) { item in
                        Text(item).tag(item)
                    }
                }
                .navigationTitle(category.title)
            } else {
                // Content-only category — no detail pane is driven from here.
                List {
                    ForEach(category.sampleItems, id: \.self) { item in
                        Label(item, systemImage: category.symbol)
                    }
                }
                .navigationTitle(category.title)
            }
        } else {
            ContentUnavailableView("Nothing Selected", systemImage: "sidebar.left")
        }
    }

    // — Detail (three-column categories only) —
    @ViewBuilder private var detail: some View {
        if store.sidebar.category == .messages {
            MessageDetailView(store: messagesStore)
        } else if store.sidebar.category == .devices {
            DeviceDetailView(store: devicesStore)
        } else if store.sidebar.category == .blueprints {
            BlueprintDetailView(store: blueprintsStore)
        } else if store.sidebar.category == .locations {
            LocationDetailView(store: locationsStore)
        } else if store.sidebar.category == .locationEvents {
            LocationEventDetailView(store: locationEventsStore)
        } else if store.sidebar.category == .printQueue {
            PrintQueueDetailView(store: printQueueStore)
        } else if store.sidebar.category == .replicants {
            ReplicantDetailView(store: replicantsStore)
        } else if let category = store.sidebar.category, let selection = store.detailSelection {
            VStack(spacing: 12) {
                Image(systemName: category.symbol).font(.system(size: 48)).foregroundStyle(.tint)
                Text(selection).font(.title2.bold())
                Text("Detail for \(category.title.lowercased()).")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(selection)
        } else {
            ContentUnavailableView("No Selection", systemImage: "square.dashed")
        }
    }
}
