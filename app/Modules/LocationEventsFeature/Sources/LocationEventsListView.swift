//
//  LocationEventsListView.swift
//  LocationEventsFeature
//
//  The content pane for the Location Events screen: a selectable list of quests,
//  grouped Active over Completed, each row a title · location with a tier pill and
//  a status badge. Selection drives the detail pane's quest sheet.
//

import ComposableArchitecture
import GameModels
import SQLiteData
import SwiftUI
import UI

public struct LocationEventsListView: View {
    @Bindable var store: StoreOf<LocationEventsFeature>

    public init(store: StoreOf<LocationEventsFeature>) {
        self.store = store
    }

    public var body: some View {
        Group {
            if store.events.isEmpty {
                emptyState
            } else {
                SelectableList(
                    selection: $store.selection,
                    sections: [
                        store.active.isEmpty
                            ? nil
                            : SelectableSection(id: "active", title: "Active", items: store.active),
                        store.inactive.isEmpty
                            ? nil
                            : SelectableSection(id: "completed", title: "Completed", items: store.inactive),
                    ].compactMap { $0 },
                    rowID: \.designation,
                    style: .inline,
                    pinnedViews: [.sectionHeaders]
                ) { event, isSelected in
                    LocationEventRow(event: event).rcSidebarRow(isSelected: isSelected)
                }
                .background(.rcContentBackground)
            }
        }
        .navigationTitle("Location Events")
        .toolbar { toolbarContent }
        .task { store.send(.task) }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let errorMessage = store.errorMessage {
                RCErrorBanner(errorMessage) { store.send(.dismissError) }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button { store.send(.refresh) } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(store.isRefreshing)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "No Events Discovered",
            systemImage: "flag",
            description: Text("Travel to and scan systems to uncover the galaxy's calls for help.")
        )
    }
}
