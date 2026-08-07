//
//  BobnetChannelDetailView.swift
//  Replicould — Bobnet feature
//
//  The channel-detail pane: the message list, an error banner, and a compose
//  bar. The list and its scroll behaviour live in BobnetChannelMessagesScroll.
//

import ComposableArchitecture
import SwiftUI
import UI

public struct BobnetChannelDetailView: View {
    @Bindable var store: StoreOf<BobnetFeature>

    public init(store: StoreOf<BobnetFeature>) {
        self.store = store
    }

    public var body: some View {
        if let channel = store.selectedChannel {
            messages(for: channel)
        } else {
            RCContentUnavailableView(
                "No Channel Selected",
                systemImage: SidebarSymbol.bobnet
            )
        }
    }

    @ViewBuilder
    private func messages(for channel: String) -> some View {
        BobnetChannelMessagesScroll(store: store, channel: channel)
            // Above the anchors and geometry observer, so a channel switch gives
            // them fresh identity; deliberately excludes the compose bar's field.
            .id(channel)
            .background(.rcContentBackground)
            .navigationTitle(channel)
            .safeAreaInset(edge: .top, spacing: 0) {
                if let errorMessage = store.errorMessage {
                    RCErrorBanner(errorMessage) { store.send(.dismissError) }
                }
            }
            .overlay(alignment: .bottom) {
                JumpToLatestPill(store: store)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                ComposeBar(store: store, channel: channel)
            }
    }
}

// MARK: - New-messages divider

/// The "New" separator inserted before the first message past the read marker.
struct NewMessagesDivider: View {
    var body: some View {
        HStack(spacing: Space.s) {
            Divider().overlay(.rcAccent)
            Text("New")
                .font(.rcMonoSmall)
                .foregroundStyle(.rcAccent)
            Divider().overlay(.rcAccent)
        }
    }
}

// MARK: - Compose bar

/// The bottom compose strip: a message field + send button, or a disabled hint
/// line naming what's missing (relay or replicant) when sending isn't possible.
private struct ComposeBar: View {
    @Bindable var store: StoreOf<BobnetFeature>
    let channel: String

    /// Why sending is disabled, if it is — relay first, then replicant.
    private var disabledReason: String? {
        if store.activeRelayCode == nil { return "No active FTL relay" }
        if store.activeReplicantCode == nil { return "No active replicant" }
        return nil
    }

    var body: some View {
        VStack(spacing: Space.xs) {
            HStack(spacing: Space.s) {
                TextField("Message \(channel)", text: $store.composeText)
                    .rcField(focused: false)
                    .onSubmit { store.send(.sendButtonTapped) }
                    .disabled(!store.canSend)

                Button {
                    store.send(.sendButtonTapped)
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: IconSize.hero))
                        .foregroundStyle(.rcAccent)
                }
                .buttonStyle(.plain)
                .disabled(!store.canSend || store.isSending)
            }

            if let disabledReason {
                HStack(spacing: 0) {
                    Text(disabledReason)
                        .font(.rcMonoSmall)
                        .foregroundStyle(.rcTextTertiary)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, Space.m)
        .padding(.vertical, Space.s)
        .background(.bar)
    }
}
