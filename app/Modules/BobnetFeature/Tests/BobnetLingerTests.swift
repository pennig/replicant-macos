//
//  BobnetLingerTests.swift
//  Replicould — Bobnet feature
//
//  The 3-second read-marker linger: reaching the newest message arms a timer;
//  scrolling away or switching channels cancels it; a new arrival re-arms it;
//  firing advances the stored marker to the channel's max id.
//

import ComposableArchitecture
import Foundation
import GameDatabase
import GameModels
import SQLiteData
import Testing
@testable import BobnetFeature

@MainActor
@Suite struct BobnetLingerTests {
    /// Builds a store over a database seeded with #general (marker 0) and two
    /// messages (ids 1, 2), with #general selected and the channel list loaded.
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

    /// Lingering at the newest message for 3 seconds marks the channel read.
    @Test func threeSecondLingerAdvancesMarker() async throws {
        let clock = TestClock()
        let (store, database) = try await makeStore(clock: clock)

        await store.send(.binding(.set(\.isAtLatest, true)))
        await clock.advance(by: .seconds(3))
        await store.receive(\.lingerElapsed)
        await store.finish()

        #expect(try await marker(database, "#general") == 2)
    }

    /// Scrolling away before 3 seconds cancels the pending mark.
    @Test func scrollingAwayCancelsLinger() async throws {
        let clock = TestClock()
        let (store, database) = try await makeStore(clock: clock)

        await store.send(.binding(.set(\.isAtLatest, true)))
        await clock.advance(by: .seconds(2))
        await store.send(.binding(.set(\.isAtLatest, false)))
        await clock.advance(by: .seconds(5))
        await store.finish()

        #expect(try await marker(database, "#general") == nil) // no row ever written
    }

    /// Switching channels cancels the pending mark for the old channel.
    @Test func switchingChannelCancelsLinger() async throws {
        let clock = TestClock()
        let (store, database) = try await makeStore(clock: clock)

        await store.send(.binding(.set(\.isAtLatest, true)))
        await clock.advance(by: .seconds(2))
        await store.send(.binding(.set(\.selectedChannel, "#trade")))
        await clock.advance(by: .seconds(5))
        await store.finish()

        #expect(try await marker(database, "#general") == nil)
    }

    /// A new arrival mid-linger restarts the window: the marker only advances
    /// 3 seconds after the *newest* message became visible.
    @Test func arrivalMidLingerRestartsWindow() async throws {
        let clock = TestClock()
        let (store, database) = try await makeStore(clock: clock)

        await store.send(.binding(.set(\.isAtLatest, true)))
        await clock.advance(by: .seconds(2))

        // A new message lands (the SSE route writes it) and the view reports it.
        // The `.load()` call resolves `defaultDatabase` from the ambient
        // dependency context (it's not routed through the store), so it must
        // be scoped to the test database the same way `makeStore` is.
        try await withDependencies {
            $0.defaultDatabase = database
        } operation: {
            try await database.write { db in
                try BobnetMessage.upsert { bobnetMessage(3, at: 300) }.execute(db)
            }
            try await store.state.$channelList.load(BobnetChannelList())
        }
        await store.send(.latestMessageChanged)
        // The bottom-scroll it requested lands, and geometry says so.
        await store.send(.binding(.set(\.isAtLatest, true)))

        await clock.advance(by: .seconds(2))
        #expect(try await marker(database, "#general") == nil) // old window would have fired at 3s

        await clock.advance(by: .seconds(1))
        await store.receive(\.lingerElapsed)
        await store.finish()
        #expect(try await marker(database, "#general") == 3)
    }

    /// Leaving the pane before 3 seconds cancels the pending mark — the same
    /// as scrolling away, but driven by the view's `onDisappear`.
    @Test func paneDisappearanceCancelsLinger() async throws {
        let clock = TestClock()
        let (store, database) = try await makeStore(clock: clock)

        await store.send(.binding(.set(\.isAtLatest, true)))
        await clock.advance(by: .seconds(2))
        await store.send(.detailDisappeared("#general")) {
            $0.isAtLatest = false
        }
        await clock.advance(by: .seconds(5))
        await store.finish()

        #expect(try await marker(database, "#general") == nil) // no row ever written
    }

    /// An intra-pane channel switch can deliver the *old* identity's
    /// `onDisappear` after the new channel is already selected (SwiftUI's
    /// ordering isn't guaranteed). That stale disappearance must not clobber
    /// the newly-selected channel's state.
    @Test func staleDisappearanceFromChannelSwitchIsIgnored() async throws {
        let clock = TestClock()
        let (store, database) = try await makeStore(clock: clock)

        await store.send(.binding(.set(\.isAtLatest, true)))
        await clock.advance(by: .seconds(2))
        await store.send(.binding(.set(\.selectedChannel, "#trade")))

        // The stale #general identity's onDisappear arrives after the switch.
        await store.send(.detailDisappeared("#general"))

        // Simulate the new channel's view reporting at-latest; with nothing
        // unread in #trade nothing arms, but the stale disappear above must
        // not have reset it out from under the new selection.
        await store.send(.binding(.set(\.isAtLatest, true))) {
            $0.isAtLatest = true
        }

        await clock.advance(by: .seconds(5))
        await store.finish()

        #expect(try await marker(database, "#general") == nil) // stale disappear wrote nothing
        #expect(store.state.isAtLatest == true) // untouched by the stale disappear
    }

    /// Switching to a channel arms the linger on its own, with no scroll report.
    ///
    /// The detail view renders pinned to the newest message
    /// (`.defaultScrollAnchor(.bottom)`), so a freshly-selected channel *is* at
    /// its latest — but nothing tells the reducer that. The scroll-geometry
    /// callback only fires when its `Bool` *changes*, and the `.id(channel)`
    /// rebuild does not re-deliver an initial report because the modifier is
    /// applied outside that identity, so it keeps its stored previous value.
    /// `selectionChanged` reset `isAtLatest` to false and nothing ever set it
    /// back, leaving every switched-to channel unable to clear its unread count.
    @Test func switchingToChannelArmsLingerWithoutScrollReport() async throws {
        let clock = TestClock()
        let (store, database) = try await makeStore(clock: clock)

        // Away and back — the exact path that left isAtLatest dead-linked.
        await store.send(.binding(.set(\.selectedChannel, "#trade")))
        await store.send(.binding(.set(\.selectedChannel, "#general")))

        await clock.advance(by: .seconds(3))
        await store.receive(\.lingerElapsed)
        await store.finish()

        #expect(try await marker(database, "#general") == 2)
    }

    /// Re-entering the pane re-arms the linger. Leaving sends
    /// `.detailDisappeared`, which clears `isAtLatest`; coming back the view is
    /// pinned to the bottom again, but with no selection change and no
    /// geometry *change* nothing would otherwise restore the flag.
    @Test func reappearingPaneReArmsLinger() async throws {
        let clock = TestClock()
        let (store, database) = try await makeStore(clock: clock)

        await store.send(.detailDisappeared("#general")) {
            $0.isAtLatest = false
        }
        await store.send(.detailAppeared("#general"))

        await clock.advance(by: .seconds(3))
        await store.receive(\.lingerElapsed)
        await store.finish()

        #expect(try await marker(database, "#general") == 2)
    }

    /// A stale `.detailAppeared` from a channel the user already left must not
    /// re-arm a linger against the newly-selected channel.
    @Test func staleAppearanceFromChannelSwitchIsIgnored() async throws {
        let clock = TestClock()
        let (store, _) = try await makeStore(clock: clock)

        await store.send(.binding(.set(\.selectedChannel, "#trade")))
        await store.send(.detailAppeared("#general"))
        await store.finish()

        #expect(store.state.selectedChannel == "#trade")
    }

    /// A linger that outlived its cancellation must not advance the marker.
    ///
    /// `.cancel(id:)` cannot cancel an effect whose task has not yet registered
    /// its cancellation token, so a linger armed and cancelled microseconds apart
    /// — which is exactly what a scroll-geometry blip produces — runs its full
    /// three seconds and fires. Observed in the wild marking a channel read while
    /// the user was scrolling *away* from the bottom. `.lingerElapsed` re-checks
    /// the arming conditions so the escaped timer is inert.
    @Test func escapedLingerAfterScrollingAwayWritesNothing() async throws {
        let clock = TestClock()
        let (store, database) = try await makeStore(clock: clock)

        await store.send(.binding(.set(\.isAtLatest, true)))
        await store.send(.binding(.set(\.isAtLatest, false)))
        await store.send(.lingerElapsed) // the cancellation didn't take
        await store.finish()

        #expect(try await marker(database, "#general") == nil)
    }

    /// The same escape, but the pane was left rather than scrolled.
    @Test func escapedLingerAfterLeavingPaneWritesNothing() async throws {
        let clock = TestClock()
        let (store, database) = try await makeStore(clock: clock)

        await store.send(.binding(.set(\.isAtLatest, true)))
        await store.send(.detailDisappeared("#general")) {
            $0.isAtLatest = false
        }
        await store.send(.lingerElapsed)
        await store.finish()

        #expect(try await marker(database, "#general") == nil)
    }

    /// A fully-read channel arms nothing.
    @Test func nothingUnreadArmsNoTimer() async throws {
        let clock = TestClock()
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try BobnetMessage.upsert { bobnetMessage(1, at: 100) }.execute(db)
            try BobnetChannel.upsert {
                BobnetChannel(name: "#general", lastActive: nil, lastReadMessageID: 1)
            }.execute(db)
        }
        try await withDependencies {
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

            await store.send(.binding(.set(\.isAtLatest, true)))
            await clock.run() // nothing scheduled: run() returns immediately
            await store.finish()
            #expect(try await marker(database, "#general") == 1) // unchanged
        }
    }
}
