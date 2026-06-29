//
//  BlueprintsListView.swift
//  Replicould — Blueprints feature
//
//  The blueprint catalog for the split view's content column. Rows render
//  straight from the `Blueprint` table via a dynamic `@FetchAll` query that is
//  reloaded whenever the search text changes, so filtering happens in SQLite
//  rather than over an in-memory array. The store drives selection and the
//  cold-load/refresh.
//

import ComposableArchitecture
import IssueReporting
import SQLiteData
import SwiftUI
import UI

public struct BlueprintsListView: View {
    @Bindable var store: StoreOf<BlueprintsFeature>
    /// Loaded lazily by the search `.task(id:)` below so the query can react to
    /// the search text.
    @FetchAll(Blueprint.none) private var blueprints

    public init(store: StoreOf<BlueprintsFeature>) {
        self.store = store
    }

    public var body: some View {
        List(selection: $store.selectedDeviceType) {
            ForEach(blueprints) { blueprint in
                BlueprintRow(blueprint: blueprint)
                    .tag(blueprint.deviceType)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .overlay {
            if blueprints.isEmpty {
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
                errorBanner(errorMessage)
            }
        }
        .toolbar {
            ToolbarItem {
                if !blueprints.isEmpty {
                    Text("\(blueprints.count) blueprints")
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
        // Reactive search: reload the query whenever the search text changes.
        .task(id: store.searchText) {
            _ = await withErrorReporting {
                try await $blueprints.load(
                    Blueprint
                        .where {
                            if !store.searchText.isEmpty {
                                $0.deviceType.contains(store.searchText)
                                    || $0.shortDescription.contains(store.searchText)
                            }
                        }
                        .order { $0.deviceType },
                    animation: .default
                )
            }
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: Space.s) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.rcWarning)
            Text(message)
                .font(.rcCaption)
                .foregroundStyle(.rcTextSecondary)
                .lineLimit(2)
            Spacer(minLength: Space.s)
            Button("Dismiss") { store.send(.dismissError) }
                .buttonStyle(RCButtonStyle(.text))
        }
        .padding(.horizontal, Space.m)
        .padding(.vertical, Space.s)
        .background(.rcSurfaceRaised)
        .overlay(alignment: .bottom) {
            Rectangle().fill(.rcSeparator).frame(height: 0.5)
        }
    }
}

// MARK: - Row

private struct BlueprintRow: View {
    let blueprint: Blueprint

    var body: some View {
        HStack(spacing: Space.s) {
            glyphTile
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

    private var glyphTile: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .fill(.rcSurfaceRaised)
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        .strokeBorder(.rcSeparator, lineWidth: 0.5)
                )
            Image(systemName: BlueprintPresentation.symbol(for: blueprint.deviceType))
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.rcAccent)
        }
        .frame(width: 30, height: 30)
    }
}
