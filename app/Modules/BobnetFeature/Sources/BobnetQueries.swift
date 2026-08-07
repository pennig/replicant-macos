//
//  BobnetQueries.swift
//  Replicould — Bobnet feature
//
//  The queries behind both panes, plus the read-marker write. The channel list
//  merges the two tables (marker rows + message aggregates) so a channel shows
//  up whether it's known from a relay directory, from streamed messages, or
//  both — all inside `fetch`, which SQLiteData re-runs whenever either table
//  changes. Pure logic lives in plain namespaces (SwiftUI-free) for testing.
//

import Foundation
import GameModels
import SQLiteData

/// One row of the channels pane.
public struct BobnetChannelRow: Equatable, Sendable, Identifiable {
    public var name: String
    /// Newer of the relay-reported activity and the latest local message.
    public var lastActivity: Date?
    /// Highest local message id (0 when no local messages).
    public var latestMessageID: Int
    /// The stored read marker (0 when no marker row exists).
    public var lastReadMessageID: Int
    /// Local messages with `id > lastReadMessageID`.
    public var unreadCount: Int

    public var id: String { name }

    public init(
        name: String,
        lastActivity: Date?,
        latestMessageID: Int,
        lastReadMessageID: Int,
        unreadCount: Int
    ) {
        self.name = name
        self.lastActivity = lastActivity
        self.latestMessageID = latestMessageID
        self.lastReadMessageID = lastReadMessageID
        self.unreadCount = unreadCount
    }
}

/// The channels-pane query: every known channel with activity + unread state.
public struct BobnetChannelList: FetchKeyRequest {
    public struct Value: Equatable, Sendable {
        public var rows: [BobnetChannelRow] = []
        public init(rows: [BobnetChannelRow] = []) { self.rows = rows }
    }

    public init() {}

    public func fetch(_ db: Database) throws -> Value {
        let channels = try BobnetChannel.all.fetchAll(db)
        let messages = try BobnetMessage.all.fetchAll(db)
        return Value(rows: Self.merge(channels: channels, messages: messages))
    }

    /// Pure merge of marker rows and message aggregates, sorted by activity
    /// (descending, nil last), ties by name.
    static func merge(
        channels: [BobnetChannel],
        messages: [BobnetMessage]
    ) -> [BobnetChannelRow] {
        let markers = Dictionary(uniqueKeysWithValues: channels.map { ($0.name, $0) })

        struct Aggregate {
            var latestID = 0
            var latestTime: Date?
            var unread = 0
        }
        var aggregates: [String: Aggregate] = [:]
        for message in messages {
            var aggregate = aggregates[message.channel] ?? Aggregate()
            aggregate.latestID = max(aggregate.latestID, message.id)
            aggregate.latestTime = max(aggregate.latestTime ?? message.time, message.time)
            if message.id > (markers[message.channel]?.lastReadMessageID ?? 0) {
                aggregate.unread += 1
            }
            aggregates[message.channel] = aggregate
        }

        let names = Set(markers.keys).union(aggregates.keys)
        let rows = names.map { name -> BobnetChannelRow in
            let marker = markers[name]
            let aggregate = aggregates[name]
            let activity = [marker?.lastActive, aggregate?.latestTime].compactMap(\.self).max()
            return BobnetChannelRow(
                name: name,
                lastActivity: activity,
                latestMessageID: aggregate?.latestID ?? 0,
                lastReadMessageID: marker?.lastReadMessageID ?? 0,
                unreadCount: aggregate?.unread ?? 0
            )
        }
        return rows.sorted { lhs, rhs in
            switch (lhs.lastActivity, rhs.lastActivity) {
            case let (l?, r?) where l != r: l > r
            case (.some, .none): true
            case (.none, .some): false
            default: lhs.name < rhs.name
            }
        }
    }
}

/// The detail-pane query: one channel's messages, oldest first.
public struct BobnetChannelMessages: FetchKeyRequest {
    public var channel: String?

    public struct Value: Equatable, Sendable {
        /// The channel `messages` belongs to; nil before the first load.
        public var channel: String?
        public var messages: [BobnetMessage] = []
        public init(channel: String? = nil, messages: [BobnetMessage] = []) {
            self.channel = channel
            self.messages = messages
        }
    }

    public init(channel: String?) { self.channel = channel }

    public func fetch(_ db: Database) throws -> Value {
        guard let channel else { return Value() }
        return Value(
            channel: channel,
            messages: try BobnetMessage
                .where { $0.channel.eq(channel) }
                .order { ($0.time, $0.id) }
                .fetchAll(db)
        )
    }
}

/// Monotonic read-marker writes, preserving the row's other columns.
enum BobnetReadMarker {
    static func advance(_ db: Database, channel: String, to id: Int) throws {
        var row = try BobnetChannel.where { $0.name.eq(channel) }.fetchOne(db)
            ?? BobnetChannel(name: channel, lastActive: nil, lastReadMessageID: 0)
        guard id > row.lastReadMessageID else { return }
        row.lastReadMessageID = id
        try BobnetChannel.upsert { row }.execute(db)
    }
}
