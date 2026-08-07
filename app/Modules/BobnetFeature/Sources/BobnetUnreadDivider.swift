//
//  BobnetUnreadDivider.swift
//  Replicould — Bobnet feature
//
//  The "New messages" divider's anchor, as a plain scan over a channel's
//  messages. A SwiftUI-free namespace so it is testable directly (statics on a
//  `View` trap under `swift test`).
//

import GameModels

/// Where the "New messages" divider sits in a channel's message list.
enum BobnetUnreadDivider {
    /// The id of the first message past `marker`; nil when nothing is unread.
    ///
    /// O(n), so a caller must bind it once per list build and never per row —
    /// a per-row call makes rendering a channel quadratic in its message count.
    static func anchor(in messages: [BobnetMessage], marker: Int) -> Int? {
        guard marker > 0 else { return nil }
        return messages.first { $0.id > marker }?.id
    }
}
