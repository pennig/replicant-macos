//
//  BobnetChannelMessagesScroll.swift
//  Replicould — Bobnet feature
//
//  The channel's message list: oldest first, laid out from the bottom, with the
//  unread divider at the read marker as it stood on selection. Owns the scroll
//  position, so the caller's `.id` gives each loaded channel a fresh one.
//

import ComposableArchitecture
import SwiftUI
import UI

struct BobnetChannelMessagesScroll: View {
    @Bindable var store: StoreOf<BobnetFeature>
    /// The channel the rendered messages belong to, which is also this view's
    /// `.id`. Nil until the first load lands.
    let channel: String?

    @State private var scrollPosition = ScrollPosition(idType: Int.self)

    var body: some View {
        // Bound once per list build. A scroll anchor walks the whole `ForEach`
        // to size the content, so anything O(n) inside the closure is O(n²).
        let firstUnreadID = BobnetUnreadDivider.anchor(
            in: store.channelMessages.messages,
            marker: store.channelMessages.marker
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
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(.bottom, for: .alignment)
        // Holding the top anchor on growth is what stops a new message moving
        // the viewport out of history.
        .defaultScrollAnchor(.top, for: .sizeChanges)
        .scrollPosition($scrollPosition)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            BobnetScrollBottom.isAtBottom(
                contentOffset: geometry.contentOffset.y,
                containerHeight: geometry.containerSize.height,
                contentHeight: geometry.contentSize.height,
                bottomInset: geometry.contentInsets.bottom
            )
        } action: { _, isAtBottom in
            store.send(.binding(.set(\.isAtLatest, isAtBottom)))
        }
        .onChange(of: store.scrollToBottomToken) {
            scrollPosition.scrollTo(edge: .bottom)
        }
        .onChange(of: store.channelMessages.messages.last?.id) {
            store.send(.latestMessageChanged)
        }
        .onAppear { store.send(.detailAppeared(channel)) }
        .onDisappear { store.send(.detailDisappeared(channel)) }
    }
}
