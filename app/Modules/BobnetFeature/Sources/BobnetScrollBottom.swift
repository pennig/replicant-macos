//
//  BobnetScrollBottom.swift
//  Replicould — Bobnet feature
//
//  The at-the-newest-message test behind the read-marker linger, as plain
//  arithmetic over scroll geometry. A SwiftUI-free namespace so it is testable
//  directly (statics on a `View` trap under `swift test`).
//

import CoreGraphics

/// Whether a channel's scroll view is showing its newest message.
enum BobnetScrollBottom {
    /// Slack allowed above the resting bottom, in points.
    static let tolerance: CGFloat = 24

    /// The resting bottom is `contentHeight - bottomInset`, not `contentHeight`.
    ///
    /// The compose bar is a bottom `safeAreaInset`, and a scroll view pinned to
    /// its true bottom still reports a gap equal to that inset — measured at 54pt
    /// against a 24pt tolerance. Comparing against `contentHeight` alone therefore
    /// made this predicate *false at rest* and true only during the rubber-band
    /// overscroll of an active gesture, so the linger armed on scroll blips and
    /// was cancelled milliseconds later when the view settled. Every unread count
    /// that "wouldn't clear" was this subtraction.
    static func isAtBottom(
        contentOffset: CGFloat,
        containerHeight: CGFloat,
        contentHeight: CGFloat,
        bottomInset: CGFloat
    ) -> Bool {
        contentOffset + containerHeight >= contentHeight - bottomInset - tolerance
    }
}
