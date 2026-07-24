//
//  CivilisationsListView.swift
//  Replicould — Civilisations feature
//
//  The civilisations catalog for the split view's content column. It's a pure
//  renderer of `store.civilisations` — the `Civilisation` table is observed as a
//  dynamic `@FetchAll` in the reducer's state, and the reducer reloads that
//  query from the search text (filtering in SQLite). So the list always matches
//  state with no async reload in the view and no empty-state flash. The store
//  drives selection, the cold-load/refresh, and the per-visit reputation
//  refresh.
//

import ComposableArchitecture
import GameModels
import SwiftUI
import UI

public struct CivilisationsListView: View {
    @Bindable var store: StoreOf<CivilisationsFeature>

    public init(store: StoreOf<CivilisationsFeature>) {
        self.store = store
    }

    public var body: some View {
        SelectableList(
            store.civilisations,
            id: \.speciesKey,
            selection: $store.selectedSpeciesKey,
            style: .inline
        ) { civilisation, isSelected in
            CivilisationRow(civilisation: civilisation).rcSidebarRow(isSelected: isSelected)
        }
        .background(.rcContentBackground)
        .overlay {
            if store.civilisations.isEmpty {
                if store.isLoading {
                    ProgressView()
                } else if !store.searchText.isEmpty {
                    ContentUnavailableView.search(text: store.searchText)
                } else {
                    ContentUnavailableView(
                        "No Civilisations",
                        systemImage: SidebarSymbol.civilisations,
                        description: Text("The galaxy's civilisations will appear here once they load.")
                    )
                }
            }
        }
        .navigationTitle("Civilisations")
        .navigationSubtitle(Text("\(store.civilisations.count) civilisations"))
        .searchable(text: $store.searchText, placement: .sidebar, prompt: "Search civilisations")
        .safeAreaInset(edge: .top, spacing: 0) {
            if let errorMessage = store.errorMessage {
                RCErrorBanner(errorMessage) { store.send(.dismissError) }
            }
        }
        .toolbar {
            ToolbarItem {
                Button {
                    store.send(.refreshButtonTapped)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh civilisations")
                .disabled(store.isLoading)
            }
        }
        // Cold-load trigger (first run) / reputation refresh (every visit).
        .task { store.send(.task) }
    }

}
