//
//  LocationsListView.swift
//  LocationsFeature
//
//  The catalog's content pane: a hierarchical disclosure list of star systems →
//  (belts + planets) → moons, filterable by explored/uncharted and sortable by
//  name, distance-from-probe, or inventory.
//
//  The census is >10k systems: the tree is built off the render path by the
//  state's `@Fetch` request, and search is pushed into its SQL.
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
        LocationTree.flatten(forest, expanded: store.expanded, loaded: store.childRows)
    }

    public var body: some View {
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
                // Extend under the toolbar so rows scroll beneath it; the scroll
                // view re-insets its content (automaticallyAdjustsContentInsets)
                // and drives the toolbar's scroll-edge glass effect.
                .ignoresSafeArea(.container, edges: .top)
            }
        }
        .navigationTitle("Locations")
        .navigationSubtitle(Text("^[\(forest.count) system](inflect: true)").monospacedDigit())
        .searchable(text: $store.searchText, placement: .sidebar, prompt: "Search systems")
        .toolbar { toolbarContent }
        .task { store.send(.task) }
        // The active replicant is a `@Shared(.appStorage)` written externally (the
        // sidebar switcher), so its change fires no binding action and touches no
        // observed table — reload the forest here so the distance sort re-measures
        // from the new probe.
        .onChange(of: store.activeReplicantCode) { store.send(.activeReplicantChanged) }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let errorMessage = store.errorMessage {
                RCErrorBanner(errorMessage) { store.send(.dismissError) }
            }
        }
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
}
