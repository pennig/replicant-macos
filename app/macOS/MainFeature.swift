//
//  MainFeature.swift
//  Replicant
//
//  The signed-in experience: a three-column NavigationSplitView with a sidebar
//  (header · grouped categories · footer) and per-category content + detail
//  panes. The Account sheet lives in AccountView.swift.
//

import AppKit
import BlueprintsFeature
import ComposableArchitecture
import DependencyClients
import DevicesFeature
import MessagesFeature
import RawAPIFeature
import SQLiteData
import StarMapFeature
import SwiftUI
import UI

// MARK: - Sidebar model

/// The categories shown in the sidebar, grouped into three sections.
enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    // Catalog
    case stars, devices, replicants, blueprints
    // Operations
    case printQueue, signals
    // Comms
    case messages, bobnet, eventLog

    var id: String { rawValue }

    var title: String {
        switch self {
        case .stars: "Stars"
        case .devices: "Devices"
        case .replicants: "Replicants"
        case .blueprints: "Blueprints"
        case .printQueue: "Print Queue"
        case .signals: "Signals"
        case .messages: "Messages"
        case .bobnet: "Bobnet"
        case .eventLog: "Event Log"
        }
    }

    var symbol: String {
        switch self {
        case .stars: "sparkles"
        case .devices: "circle.hexagongrid"
        case .replicants: "point.3.connected.trianglepath.dotted"
        case .blueprints: "doc.plaintext"
        case .printQueue: "printer"
        case .signals: "antenna.radiowaves.left.and.right"
        case .messages: "envelope"
        case .bobnet: "bubble.left.and.bubble.right"
        case .eventLog: "list.bullet.rectangle"
        }
    }

    /// Some categories show content only — no detail pane (Galaxy Map, Event Log,
    /// and the live ledgers Activity/Bobnet).
    var hasDetail: Bool {
        switch self {
        case .eventLog, .stars, .signals, .bobnet: false
        default: true
        }
    }

    /// Placeholder content rows for this category.
    var sampleItems: [String] {
        (1...8).map { "\(title) item \($0)" }
    }

    struct Group: Identifiable {
        let id: String
        let items: [SidebarItem]
    }

    static let groups: [Group] = [
        Group(id: "Catalog", items: [.stars, .devices, .replicants, .blueprints]),
        Group(id: "Operations", items: [.printQueue, .signals]),
        Group(id: "Comms", items: [.messages, .bobnet, .eventLog]),
    ]
}

// MARK: - Main feature

@Reducer
struct MainFeature {
    @ObservableState
    struct State: Equatable {
        /// The signed-in account profile, persisted to disk and refreshed on
        /// login. Reads back immediately on relaunch.
        @Shared(.account) var account: Account
        /// The account's replicant roster, observed straight from SQLite.
        @FetchAll var replicants: [Replicant]
        var apiKey: String
        var category: SidebarItem? = .devices
        var detailSelection: String?
        var isShowingAccount = false
        /// The Messages inbox, persisted locally and seeded with the session key.
        var messages: MessagesFeature.State
        /// The Raw API Access experience, shown in its own window (Tools menu).
        /// Seeded with the session API key so requests authenticate as this user.
        var rawAPI: RawAPIFeature.State
        /// The Galaxy Map (Stars view) — currently seeded with static galaxy data.
        var starMap: StarMapFeature.State
        /// The live fleet (Devices view) — list + inspector + command dispatch.
        var devices: DevicesFeature.State
        /// The unlocked blueprint catalog (Blueprints view) — list + inspector.
        var blueprints: BlueprintsFeature.State

        init(
            apiKey: String,
            category: SidebarItem? = .devices,
            detailSelection: String? = nil,
            isShowingAccount: Bool = false
        ) {
            self.apiKey = apiKey
            self.category = category
            self.detailSelection = detailSelection
            self.isShowingAccount = isShowingAccount
            self.messages = MessagesFeature.State()
            self.rawAPI = RawAPIFeature.State(apiKey: apiKey)
            self.starMap = StarMapFeature.State()
            self.devices = DevicesFeature.State()
            self.blueprints = BlueprintsFeature.State()
        }
    }

    enum Action: BindableAction {
        case binding(BindingAction<State>)
        case delegate(Delegate)
        case logoutButtonTapped
        case messages(MessagesFeature.Action)
        case rawAPI(RawAPIFeature.Action)
        case starMap(StarMapFeature.Action)
        case devices(DevicesFeature.Action)
        case blueprints(BlueprintsFeature.Action)

        enum Delegate {
            case loggedOut
        }
    }

    var body: some Reducer<State, Action> {
        BindingReducer()
        Scope(state: \.messages, action: \.messages) {
            MessagesFeature()
        }
        Scope(state: \.rawAPI, action: \.rawAPI) {
            RawAPIFeature()
        }
        Scope(state: \.starMap, action: \.starMap) {
            StarMapFeature()
        }
        Scope(state: \.devices, action: \.devices) {
            DevicesFeature()
        }
        Scope(state: \.blueprints, action: \.blueprints) {
            BlueprintsFeature()
        }
        Reduce { state, action in
            switch action {
            case .binding(\.category):
                // Reset the detail selection whenever the category changes.
                state.detailSelection = nil
                return .none

            case .binding:
                return .none

            case .delegate:
                return .none

            case .logoutButtonTapped:
                return .send(.delegate(.loggedOut))

            case .messages, .rawAPI, .starMap, .devices, .blueprints:
                return .none
            }
        }
    }
}

// MARK: - Main view

struct MainView: View {
    @Bindable var store: StoreOf<MainFeature>
    /// Live unread-message count, observed straight from SQLite, used for the
    /// Messages sidebar badge and the app's dock-tile badge.
    @FetchOne(Message.where { !$0.isRead }.count()) private var unreadCount = 0

    var body: some View {
        Group {
            if store.category?.hasDetail == false {
                // Content-only category (Event Log): a two-column split view —
                // sidebar + content, with no detail column at all.
                NavigationSplitView {
                    sidebar
                        .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 300)
                } detail: {
                    content
                        .background(.rcWindowBackground)
                }
                .navigationTitle("Replicant")
            } else {
                NavigationSplitView {
                    sidebar
                        .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 300)
                } content: {
                    content
                        .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 420)
                        .background(.rcWindowBackground)
                } detail: {
                    Group {
                        detail
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.rcContentBackground)
                }
                .navigationTitle("Replicant")
            }
        }
        .sheet(isPresented: $store.isShowingAccount) {
            AccountView(store: store)
        }
        // Mirror the unread count onto the dock icon so it's visible when the
        // app is in the background. Cleared (nil) whenever the inbox is caught up.
        .onChange(of: unreadCount, initial: true) { _, count in
            NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
        }
    }

    // — Sidebar: header · grouped categories · footer —
    private var sidebar: some View {
        VStack(spacing: 0) {
            SidebarHeader(account: store.account, replicantCount: store.replicants.count)
            Divider()
            List(selection: $store.category) {
                ForEach(SidebarItem.groups) { group in
                    Section(group.id) {
                        ForEach(group.items) { item in
                            Label(item.title, systemImage: item.symbol)
                                // `.badge(0)` renders nothing, so only Messages
                                // shows a count, and only while unread > 0.
                                .badge(item == .messages ? unreadCount : 0)
                                .tag(item)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            Divider()
            SidebarFooter(account: store.account) {
                store.isShowingAccount = true
            }
        }
    }

    /// The Messages inbox store, scoped from the main session.
    private var messagesStore: StoreOf<MessagesFeature> {
        store.scope(state: \.messages, action: \.messages)
    }

    /// The Galaxy Map store, scoped from the main session.
    private var starMapStore: StoreOf<StarMapFeature> {
        store.scope(state: \.starMap, action: \.starMap)
    }

    /// The Devices store, scoped from the main session.
    private var devicesStore: StoreOf<DevicesFeature> {
        store.scope(state: \.devices, action: \.devices)
    }

    /// The Blueprints store, scoped from the main session.
    private var blueprintsStore: StoreOf<BlueprintsFeature> {
        store.scope(state: \.blueprints, action: \.blueprints)
    }

    // — Content: a selectable list (or, for the Event Log, a plain list) —
    @ViewBuilder private var content: some View {
        if store.category == .messages {
            MessagesListView(store: messagesStore)
        } else if store.category == .stars {
            StarMapView(store: starMapStore)
        } else if store.category == .devices {
            DevicesListView(store: devicesStore)
        } else if store.category == .blueprints {
            BlueprintsListView(store: blueprintsStore)
        } else if store.category == .signals {
            ActivityView()
        } else if store.category == .bobnet {
            BobnetView()
        } else if let category = store.category {
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
        if store.category == .messages {
            MessageDetailView(store: messagesStore)
        } else if store.category == .devices {
            DeviceDetailView(store: devicesStore)
        } else if store.category == .blueprints {
            BlueprintDetailView(store: blueprintsStore)
        } else if let category = store.category, let selection = store.detailSelection {
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

// MARK: - Sidebar header & footer

struct SidebarHeader: View {
    let account: Account
    let replicantCount: Int

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 34))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.name).font(.headline)
                Text("\(replicantCount) replicants")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

struct SidebarFooter: View {
    let account: Account
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Circle()
                    .fill(.green)
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Signed in").font(.callout.weight(.medium))
                    Text(account.email).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
