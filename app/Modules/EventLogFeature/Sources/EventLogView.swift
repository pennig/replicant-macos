//
//  EventLogView.swift
//  Replicould — EventLogFeature
//
//  The root of the SSE Event Log window: a two-column split of the event list
//  (sidebar) and the selected event's JSON detail. Hosts the destructive
//  "clear all" confirmation shared by both columns.
//

import ComposableArchitecture
import SwiftUI
import UI

public struct EventLogView: View {
    @Bindable var store: StoreOf<EventLogFeature>

    public init(store: StoreOf<EventLogFeature>) {
        self.store = store
    }

    public var body: some View {
        NavigationSplitView {
            EventLogListView(store: store)
                .navigationSplitViewColumnWidth(min: 320, ideal: 360, max: 480)
        } detail: {
            EventLogDetailView(store: store)
                .navigationSplitViewColumnWidth(min: 420, ideal: 560)
                .background(.rcContentBackground)
                .navigationTitle("Event")
        }
        .background(.rcWindowBackground)
        .confirmationDialog(
            "Clear Event Log?",
            isPresented: $store.isConfirmingClear,
            titleVisibility: .visible
        ) {
            Button("Clear All Events", role: .destructive) {
                store.send(.clearConfirmed)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes every recorded event. This can't be undone.")
        }
    }
}
