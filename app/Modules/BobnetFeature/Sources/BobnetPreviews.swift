//
//  BobnetPreviews.swift
//  Replicould — Bobnet feature
//
//  Previews for the two Bobnet panes. Kept in their own file (never beside a row
//  struct) so the Xcode 26 preview JIT doesn't recompile a `List`/stack row type
//  in the same file as a `#Preview` and trip the `ViewListTree` assertion.
//
//  Both previews seed the database and render over stored history with no active
//  relay — the offline state — so `.task` is a no-op and never reaches the
//  loud-by-default (unimplemented) `bobnetClient`. That still exercises the
//  channel list, unread badges, the no-relay banner, the message list, the
//  "New messages" divider, and the compose bar's disabled hint.
//

import ComposableArchitecture
import GameDatabase
import GameModels
import SQLiteData
import SwiftUI
import UI

// MARK: - Seed

private enum BobnetPreviewSeed {
    static func install(_ db: Database) throws {
        // A read marker at id 2 in #general → ids 3+ are unread (badge + divider).
        try BobnetChannel.upsert {
            BobnetChannel(name: "#general", lastActive: date(-120), lastReadMessageID: 2)
        }.execute(db)
        try BobnetChannel.upsert {
            BobnetChannel(name: "#trade", lastActive: date(-3_600), lastReadMessageID: 0)
        }.execute(db)

        let seeded: [BobnetMessage] = [
            message(1, "#general", "Vela", "SOL-3", "Relay's warm — anyone reading?", -1_800),
            message(2, "#general", "Deckard", "SOL-4", "Copy. Signal's clean.", -1_500),
            message(3, "#general", "Vela", "SOL-3", "New drone print finished at the forge.", -300),
            message(4, "#general", "Rachael", nil, "Nice. Sending coordinates now.", -90),
            message(5, "#trade", "Roy", "ELYSIUM-2", "Trading iron for volatiles, 2:1.", -3_600),
        ]
        for row in seeded {
            try BobnetMessage.upsert { row }.execute(db)
        }
    }

    private static func message(
        _ id: Int, _ channel: String, _ name: String,
        _ star: String?, _ text: String, _ offset: TimeInterval
    ) -> BobnetMessage {
        BobnetMessage(
            id: id,
            replicantName: name,
            replicantCode: "RPL-\(id)",
            currentStar: star,
            channel: channel,
            message: text,
            time: date(offset)
        )
    }

    private static func date(_ offset: TimeInterval) -> Date { Date(timeIntervalSinceNow: offset) }
}

// MARK: - Harnesses

private struct BobnetChannelsPreviewHarness: View {
    @State private var store = Store(initialState: BobnetFeature.State()) {
        BobnetFeature()
    }

    var body: some View {
        NavigationSplitView {
            List { Label("Bobnet", systemImage: SidebarSymbol.bobnet) }
                .navigationSplitViewColumnWidth(180)
        } content: {
            BobnetChannelsView(store: store)
                .navigationSplitViewColumnWidth(min: 260, ideal: 300)
        } detail: {
            BobnetChannelDetailView(store: store)
        }
    }
}

private struct BobnetDetailPreviewHarness: View {
    let channel: String
    @State private var store = Store(initialState: BobnetFeature.State()) {
        BobnetFeature()
    }

    var body: some View {
        BobnetChannelDetailView(store: store)
            // Selecting through the binding is what loads the channel's messages
            // (the detail query is nil until a selection lands).
            .task { store.send(.binding(.set(\.selectedChannel, channel))) }
    }
}

// MARK: - Previews

#Preview("Channels") {
    let _ = prepareDependencies {
        try! $0.bootstrapDatabase { db in try BobnetPreviewSeed.install(db) }
    }
    BobnetChannelsPreviewHarness()
        .frame(width: 820, height: 560)
}

#Preview("Channel detail") {
    let _ = prepareDependencies {
        try! $0.bootstrapDatabase { db in try BobnetPreviewSeed.install(db) }
    }
    BobnetDetailPreviewHarness(channel: "#general")
        .frame(width: 560, height: 560)
}
