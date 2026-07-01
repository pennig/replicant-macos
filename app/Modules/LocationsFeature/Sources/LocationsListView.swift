//
//  LocationsListView.swift
//  LocationsFeature
//
//  The catalog's content pane: a hierarchical disclosure list of star systems →
//  (belts + planets) → moons, filterable by explored/uncharted and sortable by
//  name, distance-from-probe, or inventory. Rows and tree are reconstructed from
//  observed SQLite queries (census `Star`, hydrated `SystemDetail` blobs,
//  `LocationFootprint`); the reducer only tracks selection/sort/filter.
//

import ComposableArchitecture
import DependencyClients
import SQLiteData
import SwiftUI
import UI
import UniverseModels

public struct LocationsListView: View {
    @Bindable var store: StoreOf<LocationsFeature>

    @FetchAll(Star.none) private var stars
    @FetchAll(SystemDetail.all) private var systemDetails
    @FetchAll(LocationFootprint.all) private var footprints
    @FetchAll(Replicant.all) private var replicants
    @FetchOne(Star.none) private var myStar: Star?

    public init(store: StoreOf<LocationsFeature>) {
        self.store = store
    }

    private var detailMap: [String: StarSystem] {
        Dictionary(
            systemDetails.compactMap { row in (try? row.system()).map { (row.designation, $0) } },
            uniquingKeysWith: { a, _ in a }
        )
    }

    private var footprintMap: [String: LocationCounts] {
        Dictionary(footprints.map { ($0.location, $0.counts) }, uniquingKeysWith: { a, _ in a })
    }

    private var forest: [LocationNode] {
        LocationTree.forest(
            stars: Array(stars),
            details: detailMap,
            footprints: footprintMap,
            myPosition: myStar?.position,
            filter: store.filter,
            sort: store.sort
        )
    }

    public var body: some View {
        List(selection: $store.selection) {
            if forest.isEmpty {
                emptyState
            } else {
                OutlineGroup(forest, id: \.id, children: \.children) { node in
                    LocationRow(node: node)
                        .tag(node.id)
                        .listRowSeparator(.hidden)
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .searchable(text: $store.searchText, placement: .sidebar, prompt: "Search systems")
        .toolbar { toolbarContent }
        .task { store.send(.task) }
        .task(id: store.searchText) {
            _ = await withErrorReporting {
                try await $stars.load(
                    Star.where { $0.designation.contains(store.searchText) }.order { $0.designation },
                    animation: .default
                )
            }
        }
        .task(id: replicants.first?.currentStar) {
            guard let current = replicants.first?.currentStar else { return }
            _ = await withErrorReporting {
                try await $myStar.load(Star.where { $0.designation.eq(current) })
            }
        }
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
                Divider()
                Picker("Filter", selection: $store.filter) {
                    ForEach(LocationFilter.allCases) { Text($0.label).tag($0) }
                }
            } label: {
                Label("Sort & Filter", systemImage: "line.3.horizontal.decrease.circle")
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if store.searchText.isEmpty {
            ContentUnavailableView(
                "No Charted Systems",
                systemImage: SidebarSymbol.stars,
                description: Text("Survey nearby stars from the Stars view to populate the catalog.")
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

// MARK: - Row

struct LocationRow: View {
    let node: LocationNode

    var body: some View {
        HStack(spacing: Space.s) {
            Image(systemName: node.kind.symbol)
                .font(.system(size: 13))
                .foregroundStyle(node.recon == .aware ? .rcTextTertiary : .rcAccent)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(node.title)
                    .font(node.kind == .system ? .rcBodyEmph : .rcBody)
                    .foregroundStyle(.rcTextPrimary)
                if let subtitle = node.subtitle {
                    Text(subtitle)
                        .font(.rcCaption)
                        .foregroundStyle(.rcTextTertiary)
                }
            }

            Spacer(minLength: Space.s)

            ForEach(node.badges) { badge in
                HStack(spacing: 2) {
                    Image(systemName: badge.symbol).font(.system(size: 9))
                    Text("\(badge.count)").font(.rcMonoSmall)
                }
                .foregroundStyle(.rcTextSecondary)
            }

            ReconDot(recon: node.recon)
        }
        .padding(.vertical, 2)
    }
}

/// Small filled dot conveying recon depth (scanned = full, aware = faint).
struct ReconDot: View {
    let recon: Recon
    var body: some View {
        Circle()
            .fill(.rcAccent.opacity(recon.dim))
            .frame(width: 6, height: 6)
            .help(recon.label)
    }
}
