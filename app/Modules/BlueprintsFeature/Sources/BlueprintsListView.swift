//
//  BlueprintsListView.swift
//  Replicould — Blueprints feature
//
//  The blueprint catalog for the split view's content column. It's a pure
//  renderer of `store.blueprints` — the `Blueprint` table is observed as a
//  dynamic `@FetchAll` in the reducer's state, and the reducer reloads that query
//  from the search text (filtering in SQLite). So the list always matches state
//  with no async reload in the view and no empty-state flash. The store drives
//  selection and the cold-load/refresh.
//

import ComposableArchitecture
import GameModels
import SwiftUI
import UI

public struct BlueprintsListView: View {
    @Bindable var store: StoreOf<BlueprintsFeature>

    public init(store: StoreOf<BlueprintsFeature>) {
        self.store = store
    }

    public var body: some View {
        List(selection: $store.selectedDeviceType) {
            ForEach(store.blueprints) { blueprint in
                BlueprintRow(blueprint: blueprint)
                    .tag(blueprint.deviceType)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .overlay {
            if store.blueprints.isEmpty {
                if store.isLoading {
                    ProgressView()
                } else if !store.searchText.isEmpty {
                    ContentUnavailableView.search(text: store.searchText)
                } else {
                    ContentUnavailableView(
                        "No Blueprints",
                        systemImage: SidebarSymbol.blueprints,
                        description: Text("Your unlocked blueprints will appear here once they load.")
                    )
                }
            }
        }
        .navigationTitle("Blueprints")
        .searchable(text: $store.searchText, placement: .sidebar, prompt: "Search blueprints")
        .safeAreaInset(edge: .top, spacing: 0) {
            if let errorMessage = store.errorMessage {
                RCErrorBanner(errorMessage) { store.send(.dismissError) }
            }
        }
        .toolbar {
            ToolbarItem {
                if !store.blueprints.isEmpty {
                    Text("\(store.blueprints.count) blueprints")
                        .font(.rcCaption)
                        .foregroundStyle(.rcTextTertiary)
                }
            }
            ToolbarItem {
                Button {
                    store.send(.refreshButtonTapped)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh blueprints")
                .disabled(store.isLoading)
            }
        }
        // Cold-load trigger (first run / empty catalog).
        .task { store.send(.task) }
    }

}

// MARK: - Row

private struct BlueprintRow: View {
    let blueprint: Blueprint

    var body: some View {
        HStack(spacing: Space.s) {
            RCGlyphTile(Image.rcSymbol("device.\(blueprint.deviceType)"))
            VStack(alignment: .leading, spacing: Space.xs) {
                HStack(spacing: Space.s) {
                    Text(BlueprintPresentation.displayName(blueprint.deviceType))
                        .font(.rcBodyEmph)
                        .foregroundStyle(.rcTextPrimary)
                        .lineLimit(1)
                    Spacer(minLength: Space.xs)
                    Label(BlueprintPresentation.printTimeText(blueprint.printTime), systemImage: "clock")
                        .font(.rcMonoSmall)
                        .foregroundStyle(.rcTextTertiary)
                        .labelStyle(.titleAndIcon)
                }
                Text(blueprint.shortDescription)
                    .font(.rcCaption)
                    .foregroundStyle(.rcTextSecondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, Space.xs)
    }

}
