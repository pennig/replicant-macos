//
//  BobnetJumpToLatestTests.swift
//  Replicould — Bobnet feature
//
//  The jump-to-latest affordance's state machine: counting messages that land
//  while the reader is away from the bottom, and zeroing that count wherever
//  the view is known to be pinned to the newest message.
//

import ComposableArchitecture
import Foundation
import GameDatabase
import GameModels
import SQLiteData
import Testing
@testable import BobnetFeature

@MainActor
@Suite struct BobnetJumpToLatestTests {
    /// A store over #general (marker 0) with two messages, #general selected.
    private func makeStore(
        clock: TestClock<Duration>
    ) async throws -> (TestStore<BobnetFeature.State, BobnetFeature.Action>, any DatabaseWriter) {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try BobnetMessage.upsert { bobnetMessage(1, at: 100) }.execute(db)
            try BobnetMessage.upsert { bobnetMessage(2, at: 200) }.execute(db)
        }
        return try await withDependencies {
            $0.defaultDatabase = database
        } operation: {
            var state = BobnetFeature.State()
            state.selectedChannel = "#general"
            let store = TestStore(initialState: state) {
                BobnetFeature()
            } withDependencies: {
                $0.defaultDatabase = database
                $0.continuousClock = clock
            }
            store.exhaustivity = .off
            try await store.state.$channelList.load(BobnetChannelList())
            return (store, database)
        }
    }

    private func marker(_ database: any DatabaseWriter, _ channel: String) async throws -> Int? {
        try await database.read { db in
            try BobnetChannel.where { $0.name.eq(channel) }.fetchOne(db)?.lastReadMessageID
        }
    }

    /// Write a new #general message and reload the list the reducer reads from,
    /// the way the SSE route plus the `@Fetch` observation would.
    private func land(
        _ id: Int,
        _ database: any DatabaseWriter,
        _ store: TestStore<BobnetFeature.State, BobnetFeature.Action>
    ) async throws {
        try await withDependencies {
            $0.defaultDatabase = database
        } operation: {
            try await database.write { db in
                try BobnetMessage.upsert {
                    bobnetMessage(id, at: TimeInterval(id) * 100)
                }.execute(db)
            }
            try await store.state.$channelList.load(BobnetChannelList())
        }
    }

    /// A message landing while the reader is scrolled away is counted.
    @Test func messageWhileAwayIsCounted() async throws {
        let (store, _) = try await makeStore(clock: TestClock())

        await store.send(.binding(.set(\.isAtLatest, false)))
        await store.send(.latestMessageChanged)
        await store.send(.latestMessageChanged)

        #expect(store.state.newWhileAway == 2)
    }

    /// Reaching the bottom clears the count.
    @Test func reachingBottomClearsTheCount() async throws {
        let (store, _) = try await makeStore(clock: TestClock())

        await store.send(.binding(.set(\.isAtLatest, false)))
        await store.send(.latestMessageChanged)
        #expect(store.state.newWhileAway == 1)

        await store.send(.binding(.set(\.isAtLatest, true)))
        #expect(store.state.newWhileAway == 0)
    }

    /// Switching channels clears the count — the new channel opens at its bottom.
    @Test func switchingChannelClearsTheCount() async throws {
        let (store, _) = try await makeStore(clock: TestClock())

        await store.send(.binding(.set(\.isAtLatest, false)))
        await store.send(.latestMessageChanged)
        await store.send(.binding(.set(\.selectedChannel, "#trade")))

        #expect(store.state.newWhileAway == 0)
    }

    /// Re-entering the pane clears the count, the same as `.detailAppeared`
    /// re-establishes `isAtLatest`. A message lands after the pane has left,
    /// so `.detailAppeared` clears a genuinely nonzero count.
    @Test func reappearingPaneClearsTheCount() async throws {
        let (store, _) = try await makeStore(clock: TestClock())

        await store.send(.binding(.set(\.isAtLatest, false)))
        await store.send(.latestMessageChanged)
        await store.send(.detailDisappeared("#general"))
        await store.send(.latestMessageChanged)
        #expect(store.state.newWhileAway == 1)

        await store.send(.detailAppeared("#general"))
        #expect(store.state.newWhileAway == 0)
    }

    /// A message landing while the reader is AT the bottom asks the view to
    /// follow, and is never counted as unseen.
    @Test func messageWhileAtBottomRequestsAScroll() async throws {
        let (store, _) = try await makeStore(clock: TestClock())

        await store.send(.binding(.set(\.isAtLatest, true)))
        let before = store.state.scrollToBottomToken
        await store.send(.latestMessageChanged)

        #expect(store.state.scrollToBottomToken == before + 1)
        #expect(store.state.newWhileAway == 0)
        #expect(store.state.pendingBottomScroll == true)
    }

    /// Geometry reporting "not at bottom" while a bottom-scroll is in flight is
    /// recorded as-is — the mask, not an overwrite, is what keeps the message
    /// from being counted as unseen.
    @Test func negativeGeometryDuringPendingScrollIsNotCounted() async throws {
        let (store, _) = try await makeStore(clock: TestClock())

        await store.send(.binding(.set(\.isAtLatest, true)))
        await store.send(.latestMessageChanged)
        #expect(store.state.pendingBottomScroll == true)

        await store.send(.binding(.set(\.isAtLatest, false)))

        #expect(store.state.isAtLatest == false)
        #expect(store.state.newWhileAway == 0)
        #expect(store.state.pendingBottomScroll == true)
    }

    /// A message landing while the reader is at the bottom holds the linger
    /// armed across the whole window, counts nothing as unseen, and the landing
    /// report drops the mask — the marker still advances.
    @Test func messageLandingAtTheBottomKeepsTheLingerArmed() async throws {
        let clock = TestClock()
        let (store, database) = try await makeStore(clock: clock)

        await store.send(.binding(.set(\.isAtLatest, true)))
        try await land(3, database, store)
        await store.send(.latestMessageChanged)
        #expect(store.state.pendingBottomScroll == true)
        #expect(store.state.newWhileAway == 0)

        // The content grew under the held viewport before the scroll landed.
        await store.send(.binding(.set(\.isAtLatest, false)))
        #expect(store.state.newWhileAway == 0)
        #expect(store.state.pendingBottomScroll == true)

        await store.send(.binding(.set(\.isAtLatest, true)))
        #expect(store.state.pendingBottomScroll == false)

        await clock.advance(by: .seconds(3))
        await store.receive(\.lingerElapsed)
        await store.finish()
        #expect(try await marker(database, "#general") == 3)
    }

    /// The reader scrolling up mid-window: geometry is believed immediately, the
    /// mask holds until it expires, and the marker never advances after it does.
    @Test func scrollingUpMidWindowDisarmsTheLingerAtTheExpiry() async throws {
        let clock = TestClock()
        let (store, database) = try await makeStore(clock: clock)

        await store.send(.binding(.set(\.isAtLatest, true)))
        try await land(3, database, store)
        await store.send(.latestMessageChanged)

        await store.send(.binding(.set(\.isAtLatest, false)))
        #expect(store.state.isAtLatest == false)
        #expect(store.state.pendingBottomScroll == true)

        await clock.advance(by: .milliseconds(250))
        await store.receive(\.pendingScrollExpired)
        #expect(store.state.isAtLatest == false)
        #expect(store.state.pendingBottomScroll == false)

        await clock.advance(by: .seconds(3))
        await store.finish()
        #expect(try await marker(database, "#general") == nil)
    }

    /// A channel shorter than the viewport: `isAtBottom` is true at rest and
    /// stays true as content grows, so no geometry report ever arrives. The
    /// reader is at the newest message and the marker must still advance.
    @Test func shortChannelWithNoGeometryReportStillAdvancesTheMarker() async throws {
        let clock = TestClock()
        let (store, database) = try await makeStore(clock: clock)

        await store.send(.binding(.set(\.isAtLatest, true)))
        try await land(3, database, store)
        await store.send(.latestMessageChanged)

        await clock.advance(by: .milliseconds(250))
        await store.receive(\.pendingScrollExpired)
        #expect(store.state.isAtLatest == true)
        #expect(store.state.pendingBottomScroll == false)

        await clock.advance(by: .seconds(3))
        await store.receive(\.lingerElapsed)
        await store.finish()
        #expect(try await marker(database, "#general") == 3)
    }

    /// The genuine exit: a positive geometry report while a scroll is pending
    /// clears the flag AND cancels the 250 ms backstop — not just the flag.
    @Test func genuineLandingClearsPendingAndCancelsExpiry() async throws {
        let clock = TestClock()
        let (store, _) = try await makeStore(clock: clock)

        await store.send(.binding(.set(\.isAtLatest, true)))
        await store.send(.latestMessageChanged)
        await store.send(.binding(.set(\.isAtLatest, false)))
        await store.send(.binding(.set(\.isAtLatest, true)))

        #expect(store.state.pendingBottomScroll == false)

        // Exhaustive from here: an uncancelled expiry effect would deliver
        // `.pendingScrollExpired` unasserted, and the next `send` would fail.
        store.exhaustivity = .on
        await clock.advance(by: .milliseconds(250))
        await store.send(.binding(.set(\.isAtLatest, false))) {
            $0.isAtLatest = false
        }
        await store.finish()
    }

    /// The mask cannot stick: with no geometry report at all, 250 ms clears it
    /// and `isAtLatest` alone decides again.
    @Test func pendingScrollExpiresWithoutAGeometryReport() async throws {
        let clock = TestClock()
        let (store, _) = try await makeStore(clock: clock)

        await store.send(.binding(.set(\.isAtLatest, true)))
        await store.send(.latestMessageChanged)
        #expect(store.state.pendingBottomScroll == true)

        await clock.advance(by: .milliseconds(250))
        await store.receive(\.pendingScrollExpired)
        #expect(store.state.pendingBottomScroll == false)

        // Geometry is authoritative once more.
        await store.send(.binding(.set(\.isAtLatest, false)))
        #expect(store.state.isAtLatest == false)

        await store.finish()
    }

    /// A negative report is not repeated once the mask expires, so the reader is
    /// genuinely away: the next arrival is counted rather than followed.
    @Test func negativeReportOutlivesTheMaskWindow() async throws {
        let clock = TestClock()
        let (store, database) = try await makeStore(clock: clock)

        await store.send(.binding(.set(\.isAtLatest, true)))
        await store.send(.latestMessageChanged)
        await store.send(.binding(.set(\.isAtLatest, false)))

        await clock.advance(by: .milliseconds(250))
        await store.receive(\.pendingScrollExpired)

        let before = store.state.scrollToBottomToken
        await store.send(.latestMessageChanged)
        #expect(store.state.newWhileAway == 1)
        #expect(store.state.scrollToBottomToken == before)

        await clock.advance(by: .seconds(3))
        await store.finish()
        #expect(try await marker(database, "#general") == nil)
    }

    /// The pill's mask cannot stick: with no landing report at all it drops at
    /// 250 ms, leaving the reader in history and the marker where it was.
    @Test func jumpToLatestThatNeverLandsAdvancesNothing() async throws {
        let clock = TestClock()
        let (store, database) = try await makeStore(clock: clock)

        await store.send(.binding(.set(\.isAtLatest, false)))
        await store.send(.jumpToLatestTapped)
        #expect(store.state.isAtLatest == false)
        #expect(store.state.pendingBottomScroll == true)

        await clock.advance(by: .milliseconds(250))
        await store.receive(\.pendingScrollExpired)
        #expect(store.state.isAtLatest == false)
        #expect(store.state.pendingBottomScroll == false)

        await clock.advance(by: .seconds(3))
        await store.finish()
        #expect(try await marker(database, "#general") == nil)
    }

    /// An expiry whose window a landing already closed — or that a later
    /// request superseded — must not put the reader back in history.
    @Test func expiryFromAClosedWindowIsInert() async throws {
        let clock = TestClock()
        let (store, _) = try await makeStore(clock: clock)

        await store.send(.binding(.set(\.isAtLatest, true)))
        await store.send(.latestMessageChanged)
        let armed = store.state.scrollToBottomToken

        await store.send(.binding(.set(\.isAtLatest, true))) // the scroll landed
        #expect(store.state.pendingBottomScroll == false)

        await store.send(.pendingScrollExpired(armed)) // a cancellation that didn't take
        #expect(store.state.isAtLatest == true)

        await store.send(.latestMessageChanged) // a fresh window opens
        await store.send(.pendingScrollExpired(armed))
        #expect(store.state.isAtLatest == true)
        #expect(store.state.pendingBottomScroll == true)
    }

    /// Tapping the pill asks for the bottom and clears the count; the mask
    /// carries "effectively at latest" until geometry speaks.
    @Test func jumpToLatestScrollsAndClears() async throws {
        let (store, _) = try await makeStore(clock: TestClock())

        await store.send(.binding(.set(\.isAtLatest, false)))
        await store.send(.latestMessageChanged)
        let before = store.state.scrollToBottomToken

        await store.send(.jumpToLatestTapped)

        #expect(store.state.isAtLatest == false)
        #expect(store.state.pendingBottomScroll == true)
        #expect(store.state.newWhileAway == 0)
        #expect(store.state.scrollToBottomToken == before + 1)
    }

    /// Sending a message from scrolled-up history takes the reader to it.
    @Test func sendingScrollsToTheBottom() async throws {
        let (store, _) = try await makeStore(clock: TestClock())

        await store.send(.binding(.set(\.isAtLatest, false)))
        await store.send(.latestMessageChanged)
        let before = store.state.scrollToBottomToken

        await store.send(.sendSucceeded("#general"))

        #expect(store.state.isAtLatest == false)
        #expect(store.state.pendingBottomScroll == true)
        #expect(store.state.newWhileAway == 0)
        #expect(store.state.scrollToBottomToken == before + 1)
    }

    /// A send response for a channel the reader has since switched away from
    /// must not mask that OTHER channel to latest or scroll it.
    @Test func staleSendSucceededIsIgnored() async throws {
        let (store, _) = try await makeStore(clock: TestClock())

        await store.send(.binding(.set(\.selectedChannel, "#trade")))
        await store.send(.binding(.set(\.isAtLatest, false)))
        let before = store.state.scrollToBottomToken

        await store.send(.sendSucceeded("#general"))

        #expect(store.state.isAtLatest == false)
        #expect(store.state.pendingBottomScroll == false)
        #expect(store.state.scrollToBottomToken == before)
    }
}
