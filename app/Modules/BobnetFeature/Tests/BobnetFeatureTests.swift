//
//  BobnetFeatureTests.swift
//  Replicould — Bobnet feature
//

import ComposableArchitecture
import Foundation
import GameDatabase
import GameModels
import SQLiteData
import Testing
@testable import BobnetFeature

/// A stand-in error whose `localizedDescription` is a known string.
struct StubError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// A minimal relay device fixture; only code/type/status matter to Bobnet.
func relayFixture(_ code: String, status: String = "relaying") -> Device {
    Device(
        deviceCode: code, deviceType: "ftl_relay", replicantCode: "99380EDF",
        status: status, location: "SOL-3-1", locationName: nil,
        operationalCapacity: 100, queueSize: 0, stowedInDeviceCode: nil,
        controllerDeviceCode: nil, attachedToDeviceCode: nil,
        createdAt: Date(timeIntervalSince1970: 0),
        availableCommands: [], features: ["relay"], tags: [], detail: .object([:]),
        updatedAt: Date(timeIntervalSince1970: 0),
        firstSeenAt: Date(timeIntervalSince1970: 0)
    )
}

func bobnetMessage(
    _ id: Int, channel: String = "#general", at seconds: TimeInterval = 0
) -> BobnetMessage {
    BobnetMessage(
        id: id, replicantName: "Bill", replicantCode: "A8F48B26", currentStar: nil,
        channel: channel, message: "m\(id)", time: Date(timeIntervalSince1970: seconds)
    )
}

@MainActor
@Suite struct BobnetCatchUpTests {
    /// With no relaying relay, `.task` does no network work at all — the loud
    /// unimplemented `bobnetClient` would fail this test if it were touched.
    @Test func taskWithoutActiveRelayShortCircuits() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Device.upsert { relayFixture("AAAA1111", status: "inactive") }.execute(db)
        }
        let store = TestStore(initialState: BobnetFeature.State()) {
            BobnetFeature()
        } withDependencies: {
            $0.defaultDatabase = database
        }
        store.exhaustivity = .off
        await store.send(.task)
        await store.finish()
    }

    /// Fresh install (empty table): seed with the newest page (`latest=true`).
    @Test func taskSeedsEmptyTableWithLatestPage() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Device.upsert { relayFixture("AAAA1111") }.execute(db)
        }
        let calls = LockIsolated<[[String: String]]>([])
        let store = TestStore(initialState: BobnetFeature.State()) {
            BobnetFeature()
        } withDependencies: {
            $0.defaultDatabase = database
            $0.bobnetClient.channels = { _ in
                [BobnetChannelInfo(name: "#general", lastActive: Date(timeIntervalSince1970: 500))]
            }
            $0.bobnetClient.messages = { relay, cursor, limit, latest in
                calls.withValue { $0.append([
                    "relay": relay, "cursor": cursor.map(String.init) ?? "nil",
                    "limit": "\(limit)", "latest": "\(latest)",
                ]) }
                return BobnetPage(
                    messages: [bobnetMessage(10, at: 400), bobnetMessage(9, at: 300)],
                    nextCursor: nil
                )
            }
        }
        store.exhaustivity = .off
        await store.send(.task)
        await store.receive(\.catchUpFinished)

        #expect(calls.value == [
            ["relay": "AAAA1111", "cursor": "nil", "limit": "100", "latest": "true"]
        ])
        let stored = try await database.read { db in
            try BobnetMessage.order { $0.id }.fetchAll(db)
        }
        #expect(stored.map(\.id) == [9, 10])
        let channels = try await database.read { db in try BobnetChannel.all.fetchAll(db) }
        #expect(channels.map(\.name) == ["#general"])
    }

    /// Existing history: walk forward from the local max id until a short page.
    @Test func taskWalksForwardFromLocalMaxID() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Device.upsert { relayFixture("AAAA1111") }.execute(db)
            try BobnetMessage.upsert { bobnetMessage(50, at: 100) }.execute(db)
        }
        let cursors = LockIsolated<[Int?]>([])
        let store = TestStore(initialState: BobnetFeature.State()) {
            BobnetFeature()
        } withDependencies: {
            $0.defaultDatabase = database
            $0.bobnetClient.channels = { _ in [] }
            $0.bobnetClient.messages = { _, cursor, _, latest in
                #expect(latest == false)
                cursors.withValue { $0.append(cursor) }
                switch cursor {
                case 50:
                    return BobnetPage(
                        messages: (51...150).map { bobnetMessage($0, at: Double($0)) },
                        nextCursor: 150
                    )
                default:
                    return BobnetPage(
                        messages: [bobnetMessage(151, at: 151)], nextCursor: 151
                    )
                }
            }
        }
        store.exhaustivity = .off
        await store.send(.task)
        await store.receive(\.catchUpFinished)

        #expect(cursors.value == [50, 150]) // second page short → stop
        let count = try await database.read { db in try BobnetMessage.all.fetchCount(db) }
        #expect(count == 102) // 50 + 100 walked + 1 short-page
    }

    /// A failed catch-up surfaces the error and clears the in-flight flag.
    @Test func catchUpFailureSurfacesError() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Device.upsert { relayFixture("AAAA1111") }.execute(db)
        }
        let store = TestStore(initialState: BobnetFeature.State()) {
            BobnetFeature()
        } withDependencies: {
            $0.defaultDatabase = database
            $0.bobnetClient.channels = { _ in throw StubError(message: "relay offline") }
        }
        store.exhaustivity = .off
        await store.send(.task)
        await store.receive(\.catchUpFailed) {
            $0.errorMessage = "relay offline"
            $0.isCatchingUp = false
        }
    }

    /// A second refresh while one is in flight is ignored.
    @Test func refreshIsIgnoredWhileCatchingUp() async throws {
        let database = try GameDatabase.bootstrap()
        // `State()` must be constructed inside `withDependencies` — it's a
        // plain statement here (not the `initialState:` autoclosure TestStore
        // itself defers), so without this scope it resolves `defaultDatabase`
        // against the ambient default and warns loudly (see ReplicantsFeatureTests).
        try await withDependencies {
            $0.defaultDatabase = database
        } operation: {
            var state = BobnetFeature.State()
            state.isCatchingUp = true
            let store = TestStore(initialState: state) {
                BobnetFeature()
            } withDependencies: {
                $0.defaultDatabase = database
            }
            await store.send(.refreshButtonTapped)
        }
    }
}

@MainActor
@Suite struct BobnetSelectionTests {
    /// Selecting a channel snapshots its marker (for the "new" divider),
    /// *establishes* the at-latest flag, and reloads the detail query.
    ///
    /// The flag is set rather than cleared because the detail view rebuilds per
    /// channel (`.id(channel)`) and renders pinned to the newest message
    /// (`.defaultScrollAnchor(.bottom)`) — the selected channel really is at its
    /// latest, and no scroll-geometry report will arrive to say so.
    @Test func selectionSnapshotsMarkerAndReloadsMessages() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try BobnetChannel.upsert {
                BobnetChannel(name: "#general", lastActive: nil, lastReadMessageID: 7)
            }.execute(db)
            try BobnetMessage.upsert { bobnetMessage(7, at: 100) }.execute(db)
            try BobnetMessage.upsert { bobnetMessage(8, at: 200) }.execute(db)
        }
        // `State()` must be constructed inside `withDependencies` — see the
        // note in `refreshIsIgnoredWhileCatchingUp`.
        try await withDependencies {
            $0.defaultDatabase = database
        } operation: {
            let clock = TestClock()
            var initial = BobnetFeature.State()
            initial.isAtLatest = false
            let store = TestStore(initialState: initial) {
                BobnetFeature()
            } withDependencies: {
                $0.defaultDatabase = database
                // Message 8 is unread, so selection also arms the linger; the
                // linger's own semantics are covered by `BobnetLingerTests`.
                $0.continuousClock = clock
            }
            // The channel list is part of the fetch machinery, not the assertion.
            try await store.state.$channelList.load(BobnetChannelList())

            await store.send(.binding(.set(\.selectedChannel, "#general"))) {
                $0.selectedChannel = "#general"
                $0.markerAtSelection = 7
                $0.isAtLatest = true
            }
            await clock.advance(by: .seconds(3))
            await store.receive(\.lingerElapsed)
            await store.finish()
            #expect(store.state.channelMessages.messages.map(\.id) == [7, 8])
            #expect(store.state.channelMessages.marker == 7)
        }
    }

    /// The pane's whole value is self-consistent: `channelMessages.channel`,
    /// `.marker`, and `.messages` always describe the SAME channel, even across
    /// a switch — no combination of stale fields can point a divider at another
    /// channel's history.
    @Test func channelMessagesValueDescribesOneChannelAfterASwitch() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            // Markers equal the latest local message in each channel — nothing
            // unread, so no linger effect arms to outlive the switch below.
            try BobnetChannel.upsert {
                BobnetChannel(name: "#general", lastActive: nil, lastReadMessageID: 7)
            }.execute(db)
            try BobnetChannel.upsert {
                BobnetChannel(name: "#trade", lastActive: nil, lastReadMessageID: 51)
            }.execute(db)
            try BobnetMessage.upsert { bobnetMessage(7, channel: "#general", at: 100) }.execute(db)
            try BobnetMessage.upsert { bobnetMessage(51, channel: "#trade", at: 300) }.execute(db)
        }
        try await withDependencies {
            $0.defaultDatabase = database
        } operation: {
            let store = TestStore(initialState: BobnetFeature.State()) {
                BobnetFeature()
            } withDependencies: {
                $0.defaultDatabase = database
            }
            store.exhaustivity = .off
            try await store.state.$channelList.load(BobnetChannelList())

            await store.send(.binding(.set(\.selectedChannel, "#general")))
            await store.finish()
            #expect(store.state.channelMessages.channel == "#general")
            #expect(store.state.channelMessages.marker == 7)
            #expect(store.state.channelMessages.messages.allSatisfy { $0.channel == "#general" })

            await store.send(.binding(.set(\.selectedChannel, "#trade")))
            await store.finish()
            #expect(store.state.channelMessages.channel == "#trade")
            #expect(store.state.channelMessages.marker == 51)
            #expect(store.state.channelMessages.messages.allSatisfy { $0.channel == "#trade" })
        }
    }
}
