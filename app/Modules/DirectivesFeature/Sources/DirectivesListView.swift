//
//  DirectivesListView.swift
//  Replicould — Directives feature
//
//  The content pane: one selectable list holding both directive kinds. A pure
//  renderer — every query lives in the reducer's state.
//

import ComposableArchitecture
import SwiftUI
import UI

public struct DirectivesListView: View {
    @Bindable var store: StoreOf<DirectivesFeature>

    public init(store: StoreOf<DirectivesFeature>) {
        self.store = store
    }

    public var body: some View {
        Group {
            if store.rows.isEmpty {
                RCContentUnavailableView(
                    "No Directives",
                    systemImage: "brain.head.profile",
                    description: Text("Set a directive on an AMI controller from the device inspector, or launch a mission.")
                )
            } else {
                List(selection: $store.selectedRowID) {
                    ForEach(store.rows) { row in
                        DirectiveRowView(row: row).tag(row.id)
                    }
                }
            }
        }
        .safeAreaInset(edge: .top) { header }
        .toolbar {
            ToolbarItem {
                Menu {
                    Button("Survey Run") { store.send(.newDirectiveTapped) }
                    Button("Salvage Run") { store.send(.newSalvageRunTapped) }
                    Button("Haul Run") { store.send(.newHaulRunTapped) }
                    Button("Print Mine Fleet") { store.send(.printMineFleetTapped) }
                } label: {
                    Label("New Mission", systemImage: "plus")
                }
                .help("Launch a new mission")
            }
            ToolbarItem {
                // The count is in the title rather than a bare "Clear": this
                // deletes rows and their timelines for good, so the number that
                // goes should be readable before the click, not after it.
                Button("Clear \(store.finishedCount) Finished", systemImage: "trash") {
                    store.send(.clearFinishedTapped)
                }
                .labelStyle(.iconOnly)
                .disabled(store.finishedCount == 0)
                .help("Delete completed and cancelled runs and their timelines")
            }
        }
        // Feature-tier sheets: @Presents + scope, never .sheet(isPresented:).
        .sheet(item: $store.scope(state: \.newDirective, action: \.newDirective)) { newStore in
            NewDirectiveSheet(store: newStore)
        }
        .sheet(item: $store.scope(state: \.newSalvageRun, action: \.newSalvageRun)) { newStore in
            NewSalvageRunSheet(store: newStore)
        }
        .sheet(item: $store.scope(state: \.newHaulRun, action: \.newHaulRun)) { newStore in
            NewHaulRunSheet(store: newStore)
        }
        .confirmationDialog($store.scope(state: \.printMineFleetDialog, action: \.printMineFleetDialog))
        .navigationTitle("Directives")
    }

    /// The error banner and the brain's why-view, as ONE top inset.
    ///
    /// One inset rather than two stacked ones: each `safeAreaInset` on the
    /// same edge reserves its own space, and the banner has to sit above the
    /// brain card when both are present. Emitted conditionally so an empty
    /// stack never reserves its own padding above the list — the card is
    /// absent for the whole of a session before the brain's first tick.
    @ViewBuilder
    private var header: some View {
        if store.errorMessage != nil || store.brainWhy != nil {
            VStack(spacing: Space.s) {
                if let message = store.errorMessage {
                    RCErrorBanner(message) { store.send(.dismissError) }
                }
                // The brain's why-view (`brain-robustness-bar` clause 8),
                // above the rows it is explaining. Read-only: everything the
                // operator can DO about a mission already lives on the row
                // and its detail pane.
                if let why = store.brainWhy {
                    BrainWhyView(why: why) { store.send(.brainTapped) }
                }
            }
            .padding(Space.s)
        }
    }
}
