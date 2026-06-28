//
//  ActivityView.swift
//  Replicould — Devices feature
//
//  The global Operations/Activity view: every operation across the fleet, newest
//  first, observed straight from the `Operation` table. Content-only (no detail
//  pane) — a live ledger of what the fleet is doing. Lives in this module (which
//  the app already links) so it needs no separate app-target wiring.
//

import DependencyClients
import SQLiteData
import SwiftUI
import UI

/// Disambiguate from `Foundation.Operation`.
private typealias Operation = DependencyClients.Operation

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
                    systemImage: SidebarSymbol.signals,
                    description: Text("Operations across your fleet will appear here.")
                )
            }
        }
        .navigationTitle("Activity")
    }
}

private struct ActivityRow: View {
    let operation: Operation

    var body: some View {
        HStack(spacing: Space.s) {
            VStack(alignment: .leading, spacing: Space.xs) {
                HStack(spacing: Space.s) {
                    Text(operation.kind.capitalized)
                        .font(.rcBodyEmph)
                        .foregroundStyle(.rcTextPrimary)
                    Text(operation.entityCode)
                        .font(.rcMonoSmall)
                        .foregroundStyle(.rcTextTertiary)
                }
                Text(operation.status)
                    .font(.rcCaption)
                    .foregroundStyle(color(for: operation.status))
            }
            Spacer(minLength: Space.s)
            if let completesAt = operation.completesAt,
               operation.status == OperationStatus.active.rawValue {
                Text(completesAt, format: .relative(presentation: .named))
                    .font(.rcMonoSmall)
                    .foregroundStyle(.rcTextTertiary)
            }
        }
        .padding(.vertical, Space.xs)
    }

    private func color(for status: String) -> Color {
        switch status {
        case OperationStatus.active.rawValue, OperationStatus.enqueued.rawValue,
             OperationStatus.optimistic.rawValue:
            return .rcAccent
        case OperationStatus.completed.rawValue:
            return .rcStatusReady
        case OperationStatus.rejected.rawValue, OperationStatus.failed.rawValue:
            return .rcError
        default:
            return .rcTextTertiary
        }
    }
}
