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
        .safeAreaInset(edge: .top) {
            if let message = store.errorMessage {
                RCErrorBanner(message) { store.send(.dismissError) }
                    .padding(Space.s)
            }
        }
        .toolbar {
            ToolbarItem {
                Button { store.send(.newDirectiveTapped) } label: {
                    Label("New Survey Run", systemImage: "plus")
                }
                .help("Launch a new Survey Run")
            }
        }
        // Feature-tier sheet: @Presents + scope, never .sheet(isPresented:).
        .sheet(item: $store.scope(state: \.newDirective, action: \.newDirective)) { newStore in
            NewDirectiveSheet(store: newStore)
        }
        .navigationTitle("Directives")
    }
}
