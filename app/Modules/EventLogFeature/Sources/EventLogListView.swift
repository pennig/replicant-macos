//
//  EventLogListView.swift
//  Replicould — EventLogFeature
//
//  The sidebar: a selectable list of captured events, newest first, each row an
//  event name · category with its timestamp and an "unhandled" flag. The toolbar
//  carries the "unhandled only" filter and the Clear action.
//

import ComposableArchitecture
import GameModels
import SwiftUI
import UI

struct EventLogListView: View {
    @Bindable var store: StoreOf<EventLogFeature>

    var body: some View {
        Group {
            if store.events.isEmpty {
                emptyState
            } else {
                SelectableList(
                    store.events,
                    selection: $store.selection,
                    style: .inline
                ) { event, isSelected in
                    EventLogRow(event: event).rcSidebarRow(isSelected: isSelected)
                }
            }
        }
        .navigationTitle("Event Log")
        .toolbar { toolbarContent }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Toggle(isOn: $store.showUnhandledOnly) {
                Label("Unhandled only", systemImage: "exclamationmark.triangle")
            }
            .toggleStyle(.button)
            .help("Show only events that no feature handled")
        }
        ToolbarItem(placement: .primaryAction) {
            Button(role: .destructive) {
                store.send(.clearButtonTapped)
            } label: {
                Label("Clear", systemImage: "trash")
            }
            .disabled(store.events.isEmpty && !store.showUnhandledOnly)
            .help("Delete every recorded event")
        }
    }

    private var emptyState: some View {
        ContentUnavailableView(
            store.showUnhandledOnly ? "No Unhandled Events" : "No Events Yet",
            systemImage: store.showUnhandledOnly ? "checkmark.seal" : "dot.radiowaves.left.and.right",
            description: Text(
                store.showUnhandledOnly
                    ? "Every recorded event was handled by a feature."
                    : "Events stream in here as the app receives them over the live connection."
            )
        )
    }
}
