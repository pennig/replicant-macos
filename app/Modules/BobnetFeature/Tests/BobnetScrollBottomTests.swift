//
//  BobnetScrollBottomTests.swift
//  Replicould — Bobnet feature
//
//  The at-the-newest-message predicate. Every geometry below is a real sample
//  taken from the running app's channel detail pane (915pt container, ~11.7k of
//  content, a 54pt compose-bar safe-area inset) while diagnosing why unread
//  counts refused to clear.
//

import Testing
@testable import BobnetFeature

@Suite struct BobnetScrollBottomTests {
    /// The regression: a scroll view visually pinned to the bottom still reports
    /// a gap the size of the bottom inset. Measuring against `contentHeight`
    /// alone made this false, so the linger never armed at rest.
    @Test func restingAtBottomWithComposeBarInsetCountsAsBottom() {
        #expect(BobnetScrollBottom.isAtBottom(
            contentOffset: 10_771,
            containerHeight: 915,
            contentHeight: 11_740,
            bottomInset: 54
        ))
    }

    /// Rubber-band overscroll — the only state the old predicate ever accepted —
    /// must still count.
    @Test func overscrollPastTheRestingBottomCountsAsBottom() {
        #expect(BobnetScrollBottom.isAtBottom(
            contentOffset: 10_825,
            containerHeight: 915,
            contentHeight: 11_740,
            bottomInset: 54
        ))
    }

    /// Scrolled up a full screen: emphatically not at the newest message.
    @Test func scrolledUpIsNotBottom() {
        #expect(!BobnetScrollBottom.isAtBottom(
            contentOffset: 9_856,
            containerHeight: 915,
            contentHeight: 11_740,
            bottomInset: 54
        ))
    }

    /// Just past the tolerance above the resting bottom (~47pt of real scroll).
    @Test func justAboveToleranceIsNotBottom() {
        #expect(!BobnetScrollBottom.isAtBottom(
            contentOffset: 10_700,
            containerHeight: 915,
            contentHeight: 11_740,
            bottomInset: 54
        ))
    }

    /// With no bottom inset the resting bottom is the content bottom, and the
    /// tolerance behaves as before.
    @Test func withoutInsetToleranceStillApplies() {
        #expect(BobnetScrollBottom.isAtBottom(
            contentOffset: 1_000,
            containerHeight: 915,
            contentHeight: 1_930,
            bottomInset: 0
        ))
        #expect(!BobnetScrollBottom.isAtBottom(
            contentOffset: 1_000,
            containerHeight: 915,
            contentHeight: 2_000,
            bottomInset: 0
        ))
    }

    /// Content shorter than the container (a near-empty channel) is at bottom.
    @Test func contentShorterThanContainerIsBottom() {
        #expect(BobnetScrollBottom.isAtBottom(
            contentOffset: 0,
            containerHeight: 915,
            contentHeight: 120,
            bottomInset: 54
        ))
    }
}
