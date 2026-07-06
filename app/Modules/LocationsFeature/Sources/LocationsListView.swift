//
//  LocationsListView.swift
//  LocationsFeature
//
//  The catalog's content pane: a hierarchical disclosure list of star systems →
//  (belts + planets) → moons, filterable by explored/uncharted and sortable by
//  name, distance-from-probe, or inventory.
//
//  Performance notes (the census is >10k systems):
//    - The tree is built OFF the render path: a detached task recomputes it into
//      `@State` only when its inputs actually change (`forestKey`), never per
//      body evaluation. Selection/scroll no longer rebuild 5,770 nodes.
//    - Search + filter are pushed into the SQL query so the built set shrinks.
//

import ComposableArchitecture
import GameServices
import SQLiteData
import SwiftUI
import UI
import UniverseModels

public struct LocationsListView: View {
    @Bindable var store: StoreOf<LocationsFeature>

    public init(store: StoreOf<LocationsFeature>) {
        self.store = store
    }

    /// The built tree, assembled off-main by the state's `@Fetch` request.
    private var forest: [LocationNode] { store.forest.nodes }

    /// The flattened, currently-visible rows — the forest walked in render order,
    /// emitting a node's children only when it's expanded. Cheap to rebuild (a
    /// linear walk producing lightweight structs) and fed to a flat, lazy `List`.
    private var rows: [LocationFlatRow] {
        LocationTree.flatten(forest, expanded: store.expanded)
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Space.m) {
                Text("\(forest.count.formatted()) \(forest.count == 1 ? "system" : "systems")")
                    .font(.rcCaption)
                    .foregroundStyle(.rcTextTertiary)
                    .monospacedDigit()
                Spacer(minLength: Space.s)
            }
            .padding(.horizontal, Space.m)
            .padding(.vertical, Space.s)

            Group {
                if forest.isEmpty {
                    emptyState
                } else {
                    // Flat, pre-flattened visible rows rendered by an AppKit
                    // `NSTableView` (see `LocationsOutlineView`): the only way on
                    // macOS to get BOTH cell recycling (essential at 10,000+ systems)
                    // and animated row insert/remove on expand/collapse. The store
                    // stays the source of truth — this is a pure renderer over `rows`,
                    // `selection`, and the toggle callback.
                    LocationsOutlineView(rows: rows, selection: $store.selection) { id in
                        store.send(.toggleExpansion(id))
                    }
                }
            }
        }
        .searchable(text: $store.searchText, placement: .sidebar, prompt: "Search systems")
        .toolbar { toolbarContent }
        .task { store.send(.task) }
        .safeAreaInset(edge: .top) { errorBanner }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Picker("Filter", selection: $store.filter) {
                    ForEach(LocationFilter.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                Picker("Sort", selection: $store.sort) {
                    ForEach(LocationSort.allCases) { option in
                        Label(option.label, systemImage: option.symbol).tag(option)
                    }
                }
            } label: {
                Label("Sort/Filter", systemImage: "line.3.horizontal.decrease.circle")
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if store.searchText.isEmpty {
            ContentUnavailableView(
                store.filter == .explored ? "No Explored Systems" : "No Charted Systems",
                systemImage: SidebarSymbol.stars,
                description: Text(store.filter == .explored
                    ? "Travel to and scan a system to populate its detail."
                    : "Survey nearby stars from the Stars view to populate the catalog.")
            )
        } else {
            ContentUnavailableView.search(text: store.searchText)
        }
    }

    @ViewBuilder
    private var errorBanner: some View {
        if let message = store.errorMessage {
            HStack(spacing: Space.s) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.rcWarning)
                Text(message).font(.rcCaption).foregroundStyle(.rcTextSecondary)
                Spacer()
                Button { store.send(.dismissError) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).foregroundStyle(.rcTextTertiary)
            }
            .padding(.horizontal, Space.m).padding(.vertical, Space.s)
            .background(.rcSurfaceRaised)
        }
    }
}
