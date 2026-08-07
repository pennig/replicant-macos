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

    /// While a bottom-scroll is in flight, geometry reporting "not at bottom" is
    /// the content having grown under a held viewport — not the reader leaving.
    /// It must not flip the flag or count a message.
    @Test func negativeGeometryDuringPendingScrollIsIgnored() async throws {
        let (store, _) = try await makeStore(clock: TestClock())

        await store.send(.binding(.set(\.isAtLatest, true)))
        await store.send(.latestMessageChanged)
        #expect(store.state.pendingBottomScroll == true)

        await store.send(.binding(.set(\.isAtLatest, false)))

        #expect(store.state.isAtLatest == true)
        #expect(store.state.newWhileAway == 0)
        #expect(store.state.pendingBottomScroll == true)
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

    /// The suppression cannot stick: with no geometry report at all, 250 ms
    /// clears it and geometry becomes authoritative again.
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

    /// Tapping the pill goes to the bottom and clears the count.
    @Test func jumpToLatestScrollsAndClears() async throws {
        let (store, _) = try await makeStore(clock: TestClock())

        await store.send(.binding(.set(\.isAtLatest, false)))
        await store.send(.latestMessageChanged)
        let before = store.state.scrollToBottomToken

        await store.send(.jumpToLatestTapped)

        #expect(store.state.isAtLatest == true)
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

        #expect(store.state.isAtLatest == true)
        #expect(store.state.newWhileAway == 0)
        #expect(store.state.scrollToBottomToken == before + 1)
    }

    /// A send response for a channel the reader has since switched away from
    /// must not force that OTHER channel to latest or scroll it.
    @Test func staleSendSucceededIsIgnored() async throws {
        let (store, _) = try await makeStore(clock: TestClock())

        await store.send(.binding(.set(\.selectedChannel, "#trade")))
        await store.send(.binding(.set(\.isAtLatest, false)))
        let before = store.state.scrollToBottomToken

        await store.send(.sendSucceeded("#general"))

        #expect(store.state.isAtLatest == false)
        #expect(store.state.scrollToBottomToken == before)
    }
}
