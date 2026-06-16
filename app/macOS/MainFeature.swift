//
//  MainFeature.swift
//  Replicant
//
//  The signed-in experience: a three-column NavigationSplitView with a sidebar
//  (header · grouped categories · footer) and per-category content + detail
//  panes. The Account sheet lives in AccountView.swift.
//

import ComposableArchitecture
import SwiftUI

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

    /// The Event Log is the one category that shows content only — no detail pane.
    var hasDetail: Bool { self != .eventLog }

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

/// Stub account information surfaced in the sidebar header and Account window.
struct Account: Equatable {
    var name: String
    var email: String
    var replicantCount: Int

    static let mock = Account(name: "K. Pennig", email: "kell@pennig.name", replicantCount: 5)
}

// MARK: - Main feature

@Reducer
struct MainFeature {
    @ObservableState
    struct State: Equatable {
        var account: Account
        var apiKey: String
        var category: SidebarItem? = .devices
        var detailSelection: String?
        var isShowingAccount = false
    }

    enum Action: BindableAction {
        case binding(BindingAction<State>)
        case delegate(Delegate)
        case logoutButtonTapped

        enum Delegate {
            case loggedOut
        }
    }

    var body: some Reducer<State, Action> {
        BindingReducer()
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
            }
        }
    }
}

// MARK: - Main view

struct MainView: View {
    @Bindable var store: StoreOf<MainFeature>

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
                }
                .navigationTitle("Replicant")
            } else {
                NavigationSplitView {
                    sidebar
                        .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 300)
                } content: {
                    content
                        .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 420)
                } detail: {
                    detail
                }
                .navigationTitle("Replicant")
            }
        }
        .sheet(isPresented: $store.isShowingAccount) {
            AccountView(store: store)
        }
    }

    // — Sidebar: header · grouped categories · footer —
    private var sidebar: some View {
        VStack(spacing: 0) {
            SidebarHeader(account: store.account)
            Divider()
            List(selection: $store.category) {
                ForEach(SidebarItem.groups) { group in
                    Section(group.id) {
                        ForEach(group.items) { item in
                            Label(item.title, systemImage: item.symbol)
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

    // — Content: a selectable list (or, for the Event Log, a plain list) —
    @ViewBuilder private var content: some View {
        if let category = store.category {
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
        if let category = store.category, let selection = store.detailSelection {
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

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 34))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.name).font(.headline)
                Text("\(account.replicantCount) replicants")
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
