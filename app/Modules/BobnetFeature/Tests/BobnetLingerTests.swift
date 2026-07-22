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

        await clock.advance(by: .seconds(2))
        #expect(try await marker(database, "#general") == nil) // old window would have fired at 3s

        await clock.advance(by: .seconds(1))
        await store.receive(\.lingerElapsed)
        await store.finish()
        #expect(try await marker(database, "#general") == 3)
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
