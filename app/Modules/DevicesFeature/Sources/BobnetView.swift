//
//  BobnetView.swift
//  Replicould — Devices feature
//
//  A minimal Bobnet chat view over the locally-persisted `BobnetMessage` table.
//  Bobnet is relay-only (no authoritative REST source), so this is best-effort
//  history kept by `GameSync`. Content-only, observed live. Lives in this module
//  (already linked by the app) so it needs no separate app-target wiring.
//

import GameModels
import GameServices
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
