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
        // Bound once per list build. `.defaultScrollAnchor(.bottom)` walks the
        // whole `ForEach` to size the content, so a per-row call is quadratic.
        let firstUnreadID = BobnetUnreadDivider.anchor(
            in: store.channelMessages.messages,
            marker: store.markerAtSelection
        )
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
        .defaultScrollAnchor(.bottom)
        .id(channel)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            BobnetScrollBottom.isAtBottom(
                contentOffset: geometry.contentOffset.y,
                containerHeight: geometry.containerSize.height,
                contentHeight: geometry.contentSize.height,
                bottomInset: geometry.contentInsets.bottom
            )
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
