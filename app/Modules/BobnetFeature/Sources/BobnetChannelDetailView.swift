//
//  BobnetChannelDetailView.swift
//  Replicould — Bobnet feature
//
//  The channel-detail pane (the split view's detail column): the selected
//  channel's messages, oldest first, pinned to the newest; a "New messages"
//  divider anchored at the read marker as it stood on selection; a compose bar;
//  and at-latest scroll reporting that drives the read-marker linger.
//

import ComposableArchitecture
import SwiftUI
import UI

public struct BobnetChannelDetailView: View {
    @Bindable var store: StoreOf<BobnetFeature>

    public init(store: StoreOf<BobnetFeature>) {
        self.store = store
    }

    /// The id of the first message past the selection-time read marker — the
    /// anchor for the "New messages" divider. Nil when nothing is unread.
    private var firstUnreadID: Int? {
        guard store.markerAtSelection > 0 else { return nil }
        return store.channelMessages.messages
            .first { $0.id > store.markerAtSelection }?.id
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
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Space.s) {
                ForEach(store.channelMessages.messages) { message in
                    if message.id == firstUnreadID {
                        NewMessagesDivider()
                    }
                    BobnetMessageRow(message: message)
                }
            }
            .padding(Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .id(channel)
        .defaultScrollAnchor(.bottom)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y + geometry.containerSize.height
                >= geometry.contentSize.height - 24
        } action: { _, isAtBottom in
            if store.isAtLatest != isAtBottom {
                store.send(.binding(.set(\.isAtLatest, isAtBottom)))
            }
        }
        .onChange(of: store.channelMessages.messages.last?.id) {
            store.send(.latestMessageChanged)
        }
        .onAppear { store.send(.detailAppeared(channel)) }
        .onDisappear { store.send(.detailDisappeared(channel)) }
        .background(.rcContentBackground)
        .navigationTitle(channel)
        .safeAreaInset(edge: .top, spacing: 0) {
            if let errorMessage = store.errorMessage {
                RCErrorBanner(errorMessage) { store.send(.dismissError) }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ComposeBar(store: store, channel: channel)
        }
    }
}

// MARK: - New-messages divider

/// The "New" separator inserted before the first message past the read marker.
private struct NewMessagesDivider: View {
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
