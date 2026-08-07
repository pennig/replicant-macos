//
//  BobnetChannelMessagesScroll.swift
//  Replicould — Bobnet feature
//
//  The channel's message list: oldest first, laid out from the bottom, with the
//  unread divider at the read marker as it stood on selection. Owns the scroll
//  position, so the caller's `.id(channel)` gives each channel a fresh one.
//

import ComposableArchitecture
import OSLog
import SwiftUI
import UI

private let logger = Logger(subsystem: "name.pennig.replicould", category: "BobnetScroll")

struct BobnetChannelMessagesScroll: View {
    @Bindable var store: StoreOf<BobnetFeature>
    let channel: String

    @State private var scrollPosition = ScrollPosition(idType: Int.self)

    var body: some View {
        // Bound once per list build. A scroll anchor walks the whole `ForEach`
        // to size the content, so anything O(n) inside the closure is O(n²).
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
            if store.isAtLatest != isAtBottom {
                store.send(.binding(.set(\.isAtLatest, isAtBottom)))
            }
        }
        // Temporary: the isolated harness cannot reproduce the reported layout
        // symptoms, so the running app reports its own geometry.
        .onScrollGeometryChange(for: BobnetScrollProbe.self) { geometry in
            BobnetScrollProbe(
                container: geometry.containerSize.height,
                content: geometry.contentSize.height,
                topInset: geometry.contentInsets.top,
                bottomInset: geometry.contentInsets.bottom
            )
        } action: { _, probe in
            logger.info("""
                \(channel, privacy: .public) rows=\(store.channelMessages.messages.count) \
                container=\(probe.container, format: .fixed(precision: 1)) \
                content=\(probe.content, format: .fixed(precision: 1)) \
                insets=(t\(probe.topInset, format: .fixed(precision: 0)),\
                b\(probe.bottomInset, format: .fixed(precision: 0))) \
                fills=\(probe.content + probe.topInset, format: .fixed(precision: 1)) \
                target=\(probe.container - probe.bottomInset, format: .fixed(precision: 1))
                """)
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

/// Temporary geometry probe for the running app's layout logging.
struct BobnetScrollProbe: Equatable {
    var container: CGFloat
    var content: CGFloat
    var topInset: CGFloat
    var bottomInset: CGFloat
}
