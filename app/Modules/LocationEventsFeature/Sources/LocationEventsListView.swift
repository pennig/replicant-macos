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
                List(selection: $store.selection) {
                    if !store.active.isEmpty {
                        Section("Active") {
                            ForEach(store.active) { event in
                                LocationEventRow(event: event).tag(event.designation)
                            }
                        }
                    }
                    if !store.inactive.isEmpty {
                        Section("Completed") {
                            ForEach(store.inactive) { event in
                                LocationEventRow(event: event).tag(event.designation)
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .navigationTitle("Location Events")
        .toolbar { toolbarContent }
        .task { store.send(.task) }
        .safeAreaInset(edge: .top) { errorBanner }
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

struct LocationEventRow: View {
    let event: LocationEvent

    var body: some View {
        HStack(spacing: Space.s) {
            Image(systemName: "flag")
                .font(.system(size: 13))
                .foregroundStyle(event.isActive ? .rcAccent : .rcTextTertiary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(event.title.isEmpty ? event.designation : event.title)
                    .font(.rcBodyEmph)
                    .foregroundStyle(.rcTextPrimary)
                Text(event.locationLabel)
                    .font(.rcCaption)
                    .foregroundStyle(.rcTextTertiary)
            }

            Spacer(minLength: Space.s)

            if event.tier > 0 {
                Text("T\(event.tier)")
                    .font(.rcMonoSmall)
                    .foregroundStyle(.rcTextSecondary)
                    .rcPill(.neutral)
            }
            StatusBadge(event.status)
        }
        .padding(.vertical, 2)
    }
}
