//
//  BobnetQueriesTests.swift
//  Replicould — Bobnet feature
//

import Foundation
import GameDatabase
import GameModels
import SQLiteData
import Testing
@testable import BobnetFeature

private func message(
    _ id: Int, channel: String, at seconds: TimeInterval, from name: String = "Bill"
) -> BobnetMessage {
    BobnetMessage(
        id: id, replicantName: name, replicantCode: "A8F48B26", currentStar: nil,
        channel: channel, message: "m\(id)", time: Date(timeIntervalSince1970: seconds)
    )
}

@Suite struct BobnetChannelMergeTests {
    @Test func mergesMessageOnlyAndRelayOnlyChannels() {
        let rows = BobnetChannelList.merge(
            channels: [BobnetChannel(name: "#trade", lastActive: Date(timeIntervalSince1970: 500), lastReadMessageID: 0)],
            messages: [message(1, channel: "#general", at: 100)]
        )
        #expect(rows.map(\.name) == ["#trade", "#general"]) // activity desc
        #expect(rows[0].latestMessageID == 0)               // relay-only: no local messages
        #expect(rows[1].unreadCount == 1)                   // no marker row → all unread
    }

    @Test func unreadCountsAgainstMarker() {
        let rows = BobnetChannelList.merge(
            channels: [BobnetChannel(name: "#general", lastActive: nil, lastReadMessageID: 2)],
            messages: [
                message(1, channel: "#general", at: 100),
                message(2, channel: "#general", at: 200),
                message(3, channel: "#general", at: 300),
                message(4, channel: "#general", at: 400),
            ]
        )
        #expect(rows.count == 1)
        #expect(rows[0].unreadCount == 2)
        #expect(rows[0].latestMessageID == 4)
        #expect(rows[0].lastReadMessageID == 2)
        #expect(rows[0].lastActivity == Date(timeIntervalSince1970: 400))
    }

    @Test func activityPrefersNewerOfRelayAndLocal() {
        let rows = BobnetChannelList.merge(
            channels: [BobnetChannel(name: "#general", lastActive: Date(timeIntervalSince1970: 900), lastReadMessageID: 0)],
            messages: [message(1, channel: "#general", at: 100)]
        )
        #expect(rows[0].lastActivity == Date(timeIntervalSince1970: 900))
    }

    @Test func sortsByActivityDescThenName() {
        let rows = BobnetChannelList.merge(
            channels: [
                BobnetChannel(name: "#b", lastActive: Date(timeIntervalSince1970: 100), lastReadMessageID: 0),
                BobnetChannel(name: "#a", lastActive: Date(timeIntervalSince1970: 100), lastReadMessageID: 0),
                BobnetChannel(name: "#quiet", lastActive: nil, lastReadMessageID: 0),
            ],
            messages: []
        )
        #expect(rows.map(\.name) == ["#a", "#b", "#quiet"]) // ties by name, nil activity last
    }
}

@Suite struct BobnetQueriesDatabaseTests {
    @Test func channelListFetchReadsBothTables() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try BobnetChannel.upsert {
                BobnetChannel(name: "#general", lastActive: nil, lastReadMessageID: 1)
            }.execute(db)
            try BobnetMessage.upsert { message(1, channel: "#general", at: 100) }.execute(db)
            try BobnetMessage.upsert { message(2, channel: "#general", at: 200) }.execute(db)
        }
        let value = try await database.read { db in try BobnetChannelList().fetch(db) }
        #expect(value.rows.map(\.name) == ["#general"])
        #expect(value.rows[0].unreadCount == 1)
    }

    @Test func channelMessagesAreScopedAndAscending() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try BobnetMessage.upsert { message(2, channel: "#general", at: 200) }.execute(db)
            try BobnetMessage.upsert { message(1, channel: "#general", at: 100) }.execute(db)
            try BobnetMessage.upsert { message(3, channel: "#trade", at: 300) }.execute(db)
        }
        let value = try await database.read { db in
            try BobnetChannelMessages(channel: "#general", marker: 0).fetch(db)
        }
        #expect(value.messages.map(\.id) == [1, 2])

        let empty = try await database.read { db in
            try BobnetChannelMessages(channel: nil, marker: 0).fetch(db)
        }
        #expect(empty.messages.isEmpty)
    }

    @Test func channelMessagesCarryTheChannelTheyCameFrom() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try BobnetMessage.upsert { message(1, channel: "#general", at: 100) }.execute(db)
            try BobnetMessage.upsert { message(2, channel: "#trade", at: 200) }.execute(db)
        }
        let general = try await database.read { db in
            try BobnetChannelMessages(channel: "#general", marker: 0).fetch(db)
        }
        #expect(general.channel == "#general")
        #expect(general.messages.map(\.id) == [1])

        let missing = try await database.read { db in
            try BobnetChannelMessages(channel: "#quiet", marker: 0).fetch(db)
        }
        #expect(missing.channel == "#quiet") // named even with nothing to show
        #expect(missing.messages.isEmpty)

        let none = try await database.read { db in
            try BobnetChannelMessages(channel: nil, marker: 0).fetch(db)
        }
        #expect(none.channel == nil)
        #expect(none.messages.isEmpty)
    }

    /// `fetch` echoes the marker it was constructed with, untouched — it never
    /// reads the live read-marker column itself.
    @Test func fetchEchoesTheMarkerItWasConstructedWith() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try BobnetChannel.upsert {
                BobnetChannel(name: "#general", lastActive: nil, lastReadMessageID: 999)
            }.execute(db)
            try BobnetMessage.upsert { message(1, channel: "#general", at: 100) }.execute(db)
        }
        let value = try await database.read { db in
            try BobnetChannelMessages(channel: "#general", marker: 42).fetch(db)
        }
        #expect(value.channel == "#general")
        #expect(value.marker == 42) // the snapshot passed in, not the live 999 in the table
        #expect(value.messages.map(\.id) == [1])
    }

    @Test func readMarkerAdvancesMonotonicallyAndPreservesLastActive() async throws {
        let database = try GameDatabase.bootstrap()
        let active = Date(timeIntervalSince1970: 900)
        try await database.write { db in
            try BobnetChannel.upsert {
                BobnetChannel(name: "#general", lastActive: active, lastReadMessageID: 5)
            }.execute(db)
            try BobnetReadMarker.advance(db, channel: "#general", to: 9)
            try BobnetReadMarker.advance(db, channel: "#general", to: 7) // regression ignored
            try BobnetReadMarker.advance(db, channel: "#fresh", to: 3)   // creates the row
        }
        let rows = try await database.read { db in
            try BobnetChannel.order { $0.name }.fetchAll(db)
        }
        #expect(rows.map(\.name) == ["#fresh", "#general"])
        #expect(rows.map(\.lastReadMessageID) == [3, 9])
        #expect(rows[1].lastActive == active)
    }
}
