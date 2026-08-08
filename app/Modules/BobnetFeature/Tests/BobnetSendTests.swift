//
//  BobnetSendTests.swift
//  Replicould — Bobnet feature
//

import ComposableArchitecture
import Foundation
import GameDatabase
import GameModels
import SQLiteData
import Testing
@testable import BobnetFeature

@MainActor
@Suite struct BobnetSendTests {
    /// Seeds a relaying relay + selected #general and stubs the active
    /// replicant.
    private func makeStore(
        send: @escaping @Sendable (String, String, String) async throws -> BobnetMessage
    ) async throws -> (TestStore<BobnetFeature.State, BobnetFeature.Action>, any DatabaseWriter) {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Device.upsert { relayFixture("AAAA1111") }.execute(db)
        }
        return try await withDependencies {
            $0.defaultDatabase = database
        } operation: {
            var state = BobnetFeature.State()
            state.selectedChannel = "#general"
            state.composeText = "  hello there  "
            state.$activeReplicantCode.withLock { $0 = "99380EDF" }
            let store = TestStore(initialState: state) {
                BobnetFeature()
            } withDependencies: {
                $0.defaultDatabase = database
                $0.bobnetClient.send = send
                $0.continuousClock = TestClock()
            }
            store.exhaustivity = .off
            try await store.state.$relays.load()
            return (store, database)
        }
    }

    /// A successful send trims + posts the draft, persists the echo, advances
    /// the marker past it, and clears the compose box.
    @Test func sendPersistsEchoAndAdvancesMarker() async throws {
        let sent = LockIsolated<[[String]]>([])
        let (store, database) = try await makeStore { replicant, channel, text in
            sent.withValue { $0.append([replicant, channel, text]) }
            return bobnetMessage(42, at: 500)
        }

        await store.send(.sendButtonTapped) { $0.isSending = true }
        await store.receive(\.sendSucceeded) {
            $0.isSending = false
            $0.composeText = ""
        }
        #expect(sent.value == [["99380EDF", "#general", "hello there"]])

        let stored = try await database.read { db in
            try BobnetMessage.where { $0.id.eq(42) }.fetchOne(db)
        }
        #expect(stored != nil)
        let markerRow = try await database.read { db in
            try BobnetChannel.where { $0.name.eq("#general") }.fetchOne(db)
        }
        #expect(markerRow?.lastReadMessageID == 42)
    }

    /// A failed send keeps the draft and surfaces the error.
    @Test func sendFailureKeepsDraft() async throws {
        let (store, _) = try await makeStore { _, _, _ in
            throw StubError(message: "no relay in range")
        }
        await store.send(.sendButtonTapped) { $0.isSending = true }
        await store.receive(\.sendFailed) {
            $0.isSending = false
            $0.errorMessage = "no relay in range"
            $0.composeText = "  hello there  "
        }
    }

    /// Without an active replicant, send is a no-op.
    @Test func sendWithoutReplicantIsNoOp() async throws {
        let (store, _) = try await makeStore { _, _, _ in
            Issue.record("send must not be called")
            throw StubError(message: "unreachable")
        }
        store.state.$activeReplicantCode.withLock { $0 = nil }
        await store.send(.sendButtonTapped)
    }

    /// Submitting the New Channel sheet normalizes the name, posts the first
    /// message (which creates + subscribes the channel network-side), then
    /// selects the new channel.
    @Test func newChannelSubmitCreatesAndSelects() async throws {
        let sent = LockIsolated<[[String]]>([])
        let (store, database) = try await makeStore { replicant, channel, text in
            sent.withValue { $0.append([replicant, channel, text]) }
            return BobnetMessage(
                id: 77, replicantName: "Matt", replicantCode: "99380EDF",
                currentStar: nil, channel: channel, message: text,
                time: Date(timeIntervalSince1970: 900)
            )
        }
        await store.send(.newChannelButtonTapped) {
            $0.newChannelDraft = BobnetFeature.NewChannelDraft()
        }
        await store.send(.binding(.set(\.newChannelDraft, {
            var draft = BobnetFeature.NewChannelDraft()
            draft.name = "salvage"
            draft.firstMessage = "anyone stripping hulks near SOL?"
            return draft
        }())))
        await store.send(.newChannelSubmitted) { $0.isSending = true }
        await store.receive(\.channelCreated) {
            $0.isSending = false
            $0.newChannelDraft = nil
            $0.selectedChannel = "#salvage"
        }
        #expect(sent.value == [["99380EDF", "#salvage", "anyone stripping hulks near SOL?"]])
        let row = try await database.read { db in
            try BobnetChannel.where { $0.name.eq("#salvage") }.fetchOne(db)
        }
        #expect(row?.lastReadMessageID == 77)
    }
}

@Suite struct BobnetChannelNameTests {
    @Test func normalizeAddsPrefixAndTrims() {
        #expect(BobnetChannelName.normalize("  salvage ") == "#salvage")
        #expect(BobnetChannelName.normalize("#trade") == "#trade")
    }

    @Test func normalizeRejectsEmptyAndSpaced() {
        #expect(BobnetChannelName.normalize("") == nil)
        #expect(BobnetChannelName.normalize("   ") == nil)
        #expect(BobnetChannelName.normalize("#") == nil)
        #expect(BobnetChannelName.normalize("two words") == nil)
    }
}
