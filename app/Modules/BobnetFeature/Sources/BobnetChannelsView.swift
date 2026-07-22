//
//  BobnetChannelsView.swift
//  Replicould — Bobnet feature
//
//  The channels pane (the split view's content column): a selectable list of
//  channels observed from SQLite, a no-relay banner when Bobnet is offline, a
//  refresh/new-channel toolbar, and the New Channel sheet. Selection drives the
//  detail pane. `.task` runs relay catch-up on appearance.
//

import ComposableArchitecture
import SwiftUI
import UI

public struct BobnetChannelsView: View {
    @Bindable var store: StoreOf<BobnetFeature>

    public init(store: StoreOf<BobnetFeature>) {
        self.store = store
    }

    public var body: some View {
        List(store.channelList.rows, selection: $store.selectedChannel) { row in
            BobnetChannelListRow(row: row)
                .listRowSeparator(.hidden)
        }
        .listStyle(.inset)
        .overlay {
            if store.channelList.rows.isEmpty {
                ContentUnavailableView(
                    "Bobnet Quiet",
                    systemImage: SidebarSymbol.bobnet,
                    description: Text("Chatter from the network will appear here.")
                )
            }
        }
        .navigationTitle("Bobnet")
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                if store.activeRelayCode == nil {
                    NoRelayBanner()
                }
                if let errorMessage = store.errorMessage {
                    RCErrorBanner(errorMessage) { store.send(.dismissError) }
                }
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    store.send(.refreshButtonTapped)
                } label: {
                    if store.isCatchingUp {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .help("Refresh")
                .disabled(store.isCatchingUp)

                Button {
                    store.send(.newChannelButtonTapped)
                } label: {
                    Image(systemName: "plus")
                }
                .help("New channel")
                .disabled(!store.canSend)
            }
        }
        .sheet(
            item: Binding(
                get: { store.newChannelDraft },
                set: { if $0 == nil { store.send(.newChannelDismissed) } }
            )
        ) { _ in
            NewChannelSheet(store: store)
        }
        .task { store.send(.task) }
    }
}

// MARK: - No-relay banner

/// The compact strip shown atop the channels list when no FTL relay is relaying:
/// Bobnet falls back to stored history, and catch-up/sending are unavailable.
private struct NoRelayBanner: View {
    var body: some View {
        HStack(spacing: Space.s) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .font(.system(size: IconSize.m))
                .foregroundStyle(.rcTextTertiary)
            Text("No active FTL relays — showing stored history. Catch-up and sending are unavailable.")
                .font(.rcMonoSmall)
                .foregroundStyle(.rcTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.m)
        .padding(.vertical, Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.rcWindowBackground)
        .overlay(alignment: .bottom) {
            Rectangle().fill(.rcSeparator).frame(height: Hairline.thin)
        }
    }
}
