//
//  ActivityView.swift
//  Replicould — Devices feature
//
//  The global Operations/Activity view: every operation across the fleet, newest
//  first, observed straight from the `Operation` table. Content-only (no detail
//  pane) — a live ledger of what the fleet is doing. Lives in this module (which
//  the app already links) so it needs no separate app-target wiring.
//

import GameModels
import GameServices
import SQLiteData
import SwiftUI
import UI

/// Disambiguate from `Foundation.Operation`.
private typealias Operation = GameModels.Operation

public struct ActivityView: View {
    @FetchAll(Operation.order { $0.startedAt.desc() }) private var operations

    public init() {}

    public var body: some View {
        List {
            ForEach(operations) { operation in
                ActivityRow(operation: operation)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.inset)
        .overlay {
            if operations.isEmpty {
                ContentUnavailableView(
                    "No Activity",
                    systemImage: SidebarSymbol.eventLog,
                    description: Text("Operations across your fleet will appear here.")
                )
            }
        }
        .navigationTitle("Operations Log")
    }
}
