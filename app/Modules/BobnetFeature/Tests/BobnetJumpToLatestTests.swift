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
    /// re-establishes `isAtLatest`.
    @Test func reappearingPaneClearsTheCount() async throws {
        let (store, _) = try await makeStore(clock: TestClock())

        await store.send(.binding(.set(\.isAtLatest, false)))
        await store.send(.latestMessageChanged)
        await store.send(.detailDisappeared("#general"))
        await store.send(.detailAppeared("#general"))

        #expect(store.state.newWhileAway == 0)
    }
}
