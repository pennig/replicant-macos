//
//  BobnetView.swift
//  Replicould — Devices feature
//
//  A minimal Bobnet chat view over the locally-persisted `BobnetMessage` table.
//  Bobnet is relay-only (no authoritative REST source), so this is best-effort
//  history kept by `GameSync`. Content-only, observed live. Lives in this module
//  (already linked by the app) so it needs no separate app-target wiring.
//

import DependencyClients
import GameModels
import SQLiteData
import SwiftUI
import UI

public struct BobnetView: View {
    @FetchAll(BobnetMessage.order { $0.time.desc() }) private var messages

    public init() {}

    public var body: some View {
        List {
            ForEach(messages) { message in
                BobnetRow(message: message)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.inset)
        .overlay {
            if messages.isEmpty {
                ContentUnavailableView(
                    "Bobnet Quiet",
                    systemImage: SidebarSymbol.bobnet,
                    description: Text("Chatter from the network will appear here.")
                )
            }
        }
        .navigationTitle("Bobnet")
    }
}

private struct BobnetRow: View {
    let message: BobnetMessage

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.s) {
                Text(message.replicantName)
                    .font(.rcBodyEmph)
                    .foregroundStyle(.rcTextPrimary)
                Text(message.channel)
                    .font(.rcMonoSmall)
                    .foregroundStyle(.rcAccent)
                if let star = message.currentStar {
                    Text(star)
                        .font(.rcMonoSmall)
                        .foregroundStyle(.rcTextTertiary)
                }
                Spacer(minLength: Space.s)
                Text(message.time, format: .relative(presentation: .named))
                    .font(.rcMonoSmall)
                    .foregroundStyle(.rcTextTertiary)
            }
            Text(message.message)
                .font(.rcBody)
                .foregroundStyle(.rcTextSecondary)
                .textSelection(.enabled)
        }
        .padding(.vertical, Space.xs)
    }
}
