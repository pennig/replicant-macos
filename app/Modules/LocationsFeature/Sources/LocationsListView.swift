//
//  LocationsListView.swift
//  LocationsFeature
//
//  The catalog's content pane: a hierarchical disclosure list of star systems →
//  (belts + planets) → moons, filterable by explored/uncharted and sortable by
//  name, distance-from-probe, or inventory.
//
//  Performance notes (the census is ~5,770 systems):
//    - Rows render through the lazy `List(_:children:selection:)` initializer, so
//      only visible rows are realized (a `List { OutlineGroup }` realizes the
//      whole tree eagerly — death on scroll).
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

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Space.m) {
                Text("\(forest.count.formatted()) \(forest.count == 1 ? "system" : "systems")")
                    .font(.rcCaption)
                    .foregroundStyle(.rcTextTertiary)
                    .monospacedDigit()
                Spacer(minLength: Space.s)
                RCValueSelect(
                    "Filter",
                    systemImage: "line.3.horizontal.decrease.circle",
                    options: ["All": LocationFilter.all, "Explored": .explored, "Uncharted": .unexplored],
                    selection: $store.filter
                )
            }
            .padding(.horizontal, Space.m)
            .padding(.vertical, Space.s)

            Group {
                if forest.isEmpty {
                    emptyState
                } else {
                    // Flat `List { ForEach }` (lazily realizes only visible rows)
                    // with per-row `DisclosureGroup`s (children built on expand) —
                    // reliably lazy at 5,770 systems, unlike `List(_:children:)`.
                    List(selection: $store.selection) {
                        ForEach(forest) { node in
                            LocationOutlineRow(node: node)
                        }
                    }
                    .listStyle(.inset)
                    .scrollContentBackground(.hidden)
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
                Picker("Sort", selection: $store.sort) {
                    ForEach(LocationSort.allCases) { option in
                        Label(option.label, systemImage: option.symbol).tag(option)
                    }
                }
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
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
