//
//  MainFeature.swift
//  Replicant
//
//  The signed-in experience: a three-column NavigationSplitView with a sidebar
//  (header · grouped categories · footer) and per-category content + detail
//  panes. The Account sheet lives in AccountView.swift.
//

import AccountManager
import AppKit
import BlueprintsFeature
import ComposableArchitecture
import DependencyClients
import DevicesFeature
import LocationsFeature
import MessagesFeature
import PrintQueueFeature
import RawAPIFeature
import ReplicantsFeature
import SQLiteData
import StarMapFeature
import SwiftUI
import UI

// MARK: - Sidebar model

/// The categories shown in the sidebar, grouped into three sections.
enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    // Catalog
    case stars, locations, devices, replicants, blueprints
    // Operations
    case printQueue
    // Comms
    case messages, bobnet, eventLog

    var id: String { rawValue }

    var title: String {
        switch self {
        case .stars: "Stars"
        case .locations: "Locations"
        case .devices: "Devices"
        case .replicants: "Replicants"
        case .blueprints: "Blueprints"
        case .printQueue: "Print Queue"
        case .messages: "Messages"
        case .bobnet: "Bobnet"
        case .eventLog: "Event Log"
        }
    }

    var symbol: String {
        switch self {
        case .stars: "sparkles"
        case .locations: "map"
        case .devices: "circle.hexagongrid"
        case .replicants: "point.3.connected.trianglepath.dotted"
        case .blueprints: "doc.plaintext"
        case .printQueue: "printer"
        case .messages: "envelope"
        case .bobnet: "bubble.left.and.bubble.right"
        case .eventLog: "list.bullet.rectangle"
        }
    }

    /// Some categories show content only — no detail pane (Galaxy Map, Bobnet,
    /// and the live Event Log ledger).
    var hasDetail: Bool {
        switch self {
        case .eventLog, .stars, .bobnet: false
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
        Group(id: "Catalog", items: [.stars, .locations, .devices, .replicants, .blueprints]),
        Group(id: "Operations", items: [.printQueue]),
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
        /// The stellar-locations catalog (Locations view) — disclosure list + inspector.
        var locations: LocationsFeature.State
        /// The Print Queue (Operations) — printers with an active job or queue.
        var printQueue: PrintQueueFeature.State
        /// The Replicants directory — the account's own replicants plus every
        /// other player and NPC known in the galaxy. (Named to avoid colliding
        /// with the owned-roster `replicants` array above.)
        var replicantDirectory: ReplicantsFeature.State

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
            self.locations = LocationsFeature.State()
            self.printQueue = PrintQueueFeature.State()
            self.replicantDirectory = ReplicantsFeature.State()
        }
    }

    @Dependency(\.replicantsClient) var replicantsClient
    @Dependency(\.accountManager) var accountManager

    enum Action: BindableAction {
        case binding(BindingAction<State>)
        /// The signed-in experience appeared — re-sync the account roster from the
        /// server (login isn't re-run for a restored session).
        case task
        case delegate(Delegate)
        /// Hydrate the active replicant's public details (its `plan`) so the
        /// sidebar header can show and edit it.
        case loadActivePlan(String)
        case logoutButtonTapped
        /// Persist an edited plan for the given replicant via PATCH.
        case savePlan(code: String, plan: String)
        case messages(MessagesFeature.Action)
        case rawAPI(RawAPIFeature.Action)
        case starMap(StarMapFeature.Action)
        case devices(DevicesFeature.Action)
        case blueprints(BlueprintsFeature.Action)
        case locations(LocationsFeature.Action)
        case printQueue(PrintQueueFeature.Action)
        case replicantDirectory(ReplicantsFeature.Action)

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
        Scope(state: \.locations, action: \.locations) {
            LocationsFeature()
        }
        Scope(state: \.printQueue, action: \.printQueue) {
            PrintQueueFeature()
        }
        Scope(state: \.replicantDirectory, action: \.replicantDirectory) {
            ReplicantsFeature()
        }
        Reduce { state, action in
            switch action {
            case .binding(\.category):
                // Reset the detail selection whenever the category changes.
                state.detailSelection = nil
                return .none

            case .binding:
                return .none

            case .task:
                // Restored sessions skip login, so the roster can be stale (or
                // empty after a DB reset). Re-fetch it so the sidebar and the
                // Replicants directory's own set are current.
                return .run { _ in await accountManager.refreshAccount() }

            case .delegate:
                return .none

            case let .loadActivePlan(code):
                // Best-effort: the sidebar reads the plan straight from SQLite, so
                // a failed load just leaves the last-known value in place.
                return .run { _ in try? await replicantsClient.loadDetails(code) }

            case .logoutButtonTapped:
                return .send(.delegate(.loggedOut))

            case let .savePlan(code, plan):
                return .run { _ in
                    _ = await withErrorReporting {
                        try await replicantsClient.updatePlan(code, plan)
                    }
                }

            case .messages, .rawAPI, .starMap, .devices, .blueprints, .locations, .printQueue, .replicantDirectory:
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
    /// The whole fleet, observed from SQLite — the header reads it to resolve the
    /// active replicant's host glyph and any running travel/print progress.
    @FetchAll private var devices: [Device]
    /// The known-replicant directory, observed from SQLite — the header reads the
    /// active replicant's public `plan` from here (hydrated on appear/change).
    @FetchAll private var knownReplicants: [KnownReplicant]
    /// The app-wide active-replicant selection (shared with Locations / Stars).
    /// The header's switcher writes here; other features read the same key.
    @Shared(.appStorage(Account.activeReplicantCodeKey)) private var activeReplicantCode: String?

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
        // Re-sync the account roster on launch (a restored session skips login).
        .task { store.send(.task) }
        // Mirror the unread count onto the dock icon so it's visible when the
        // app is in the background. Cleared (nil) whenever the inbox is caught up.
        .onChange(of: unreadCount, initial: true) { _, count in
            NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
        }
    }

    // — Sidebar: header · grouped categories · footer —
    private var sidebar: some View {
        VStack(spacing: 0) {
            sidebarHeader
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
            RCAccountFooter(
                name: store.account.name,
                email: store.account.email,
                experiencePoints: store.account.experiencePointsTotal,
                replicantCount: store.replicants.count
            ) {
                store.isShowingAccount = true
            }
        }
    }

    // — Active replicant header —
    //
    // The switcher writes the chosen replicant straight to the shared
    // `activeReplicantCode` (the same appStorage key Locations/Stars read), so
    // changing the active replicant here updates the whole app. Progress and host
    // glyphs are derived from the local fleet.
    @ViewBuilder private var sidebarHeader: some View {
        if store.replicants.isEmpty {
            // No roster yet (fresh session / mid-sync) — a quiet placeholder.
            HStack(spacing: Space.s) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .foregroundStyle(.rcTextTertiary)
                Text("No replicants yet")
                    .font(.rcBody)
                    .foregroundStyle(.rcTextSecondary)
                Spacer()
            }
            .padding(.horizontal, Space.m)
            .padding(.vertical, Space.m)
        } else {
            RCActiveReplicantHeader(
                replicants: rosterOptions,
                selection: switcherSelection,
                location: activeReplicant?.currentLocationName ?? activeReplicant?.currentLocation,
                experiencePoints: activeReplicant?.experiencePoints ?? 0,
                deviceCount: activeReplicant?.deviceCount ?? 0,
                progress: activeReplicantProgress,
                plan: activePlan,
                onShowInReplicants: { $store.category.wrappedValue = .replicants },
                onEditPlan: { plan in
                    if let code = activeReplicant?.replicantCode {
                        store.send(.savePlan(code: code, plan: plan))
                    }
                }
            )
            // Hydrate the active replicant's public details (its plan) whenever the
            // selection changes, so the plan line reflects the server.
            .task(id: activeReplicant?.replicantCode) {
                if let code = activeReplicant?.replicantCode {
                    store.send(.loadActivePlan(code))
                }
            }
        }
    }

    /// The active replicant's public plan, read from its known-replicant record.
    private var activePlan: String? {
        guard let code = activeReplicant?.replicantCode else { return nil }
        return knownReplicants.first { $0.replicantCode == code }?.plan
    }

    // — Active replicant derivation —

    /// The currently-active replicant, falling back to the first in the roster
    /// when nothing (or a stale code) is selected.
    private var activeReplicant: Replicant? {
        store.replicants.first { $0.replicantCode == activeReplicantCode } ?? store.replicants.first
    }

    /// The roster mapped to switcher options, each carrying its host glyph.
    private var rosterOptions: [RCReplicant] {
        store.replicants.map { replicant in
            RCReplicant(id: replicant.replicantCode, name: replicant.name, host: host(for: replicant))
        }
    }

    /// A binding the switcher drives: reads the active option, writes the choice
    /// back to the shared `activeReplicantCode`.
    private var switcherSelection: Binding<RCReplicant> {
        Binding(
            get: {
                rosterOptions.first { $0.id == activeReplicant?.replicantCode }
                    ?? rosterOptions.first
                    ?? RCReplicant(id: "", name: "—", host: .vessel)
            },
            set: { newValue in $activeReplicantCode.withLock { $0 = newValue.id } }
        )
    }

    /// The host kind for a replicant, read from its hosting device's type when
    /// that device is in the local fleet (defaults to a vessel otherwise).
    private func host(for replicant: Replicant) -> HostKind {
        guard
            let code = replicant.hostedDeviceCode,
            let device = devices.first(where: { $0.deviceCode == code })
        else { return .vessel }
        return HostKind(deviceType: device.deviceType)
    }

    /// The active replicant's most relevant running activity — its host device's
    /// travel first (the replicant itself is moving), then any other device of
    /// its that's mid-operation (printing, mining, scanning).
    private var activeReplicantProgress: RCReplicantProgress? {
        guard let active = activeReplicant else { return nil }
        let fleet = devices.filter { $0.replicantCode == active.replicantCode }
        let host = active.hostedDeviceCode.flatMap { code in fleet.first { $0.deviceCode == code } }
        let ordered = [host].compactMap { $0 } + fleet.filter { $0.deviceCode != active.hostedDeviceCode }
        for device in ordered {
            if let progress = progress(for: device) { return progress }
        }
        return nil
    }

    /// Distill a device's in-progress snapshot into a header progress row, or nil
    /// when it isn't running a timed operation we can chart.
    private func progress(for device: Device) -> RCReplicantProgress? {
        guard
            let activity = device.derivedActivity,
            let startedAt = activity.startedAt,
            let completesAt = activity.completesAt
        else { return nil }
        let tint = DeviceStatus.tone(for: device.statusBase).color
        let label: String
        let symbol: String?
        switch activity.kind {
        case .travel:
            label = device.travelSnapshot?.destinationLabel ?? device.locationName ?? device.location ?? "In transit"
            symbol = "arrow.right"
        case .print:
            label = device.statusParameter.map { $0.replacingOccurrences(of: "_", with: " ").capitalized } ?? "Printing"
            symbol = "printer"
        default:
            label = DeviceStatus.label(for: device.statusBase)
            symbol = nil
        }
        return RCReplicantProgress(label: label, symbol: symbol, startedAt: startedAt, completesAt: completesAt, tint: tint)
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

    /// The Locations catalog store, scoped from the main session.
    private var locationsStore: StoreOf<LocationsFeature> {
        store.scope(state: \.locations, action: \.locations)
    }

    /// The Print Queue store, scoped from the main session.
    private var printQueueStore: StoreOf<PrintQueueFeature> {
        store.scope(state: \.printQueue, action: \.printQueue)
    }

    /// The Replicants directory store, scoped from the main session.
    private var replicantsStore: StoreOf<ReplicantsFeature> {
        store.scope(state: \.replicantDirectory, action: \.replicantDirectory)
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
        } else if store.category == .locations {
            LocationsListView(store: locationsStore)
        } else if store.category == .printQueue {
            PrintQueueListView(store: printQueueStore)
        } else if store.category == .replicants {
            ReplicantsListView(store: replicantsStore)
        } else if store.category == .eventLog {
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
        } else if store.category == .locations {
            LocationDetailView(store: locationsStore)
        } else if store.category == .printQueue {
            PrintQueueDetailView(store: printQueueStore)
        } else if store.category == .replicants {
            ReplicantDetailView(store: replicantsStore)
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

