//
//  BobnetChannel.swift
//  Replicould — shared game models
//
//  A Bobnet channel's local bookkeeping: the relay-reported last-activity
//  timestamp and this account's per-channel read marker. Rows are created by
//  relay channel-directory syncs, by channel creation, and lazily by the first
//  read-marker write — a channel known only from streamed messages appears in
//  the UI via the channel-list merge even before a row exists here.
//

import Foundation
import SQLiteData

@Table
public struct BobnetChannel: Identifiable, Equatable, Sendable {
    /// Channel name (IRC-style, e.g. `#general`) — the natural primary key.
    @Column(primaryKey: true) public var name: String
    /// Last message activity as reported by a relay's channel directory.
    public var lastActive: Date?
    /// Highest message `id` this account has read in the channel. 0 = nothing read.
    public var lastReadMessageID: Int

    public var id: String { name }

    public init(name: String, lastActive: Date?, lastReadMessageID: Int) {
        self.name = name
        self.lastActive = lastActive
        self.lastReadMessageID = lastReadMessageID
    }
}

// MARK: - Schema

extension BobnetChannel {
    /// Registers the `bobnetChannels` table migration. Composed into the app's
    /// `bootstrapDatabase` alongside other tables.
    public static func registerMigrations(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("Create 'bobnetChannels' table") { db in
            try #sql(
                """
                CREATE TABLE "bobnetChannels" (
                  "name" TEXT PRIMARY KEY NOT NULL,
                  "lastActive" TEXT,
                  "lastReadMessageID" INTEGER NOT NULL DEFAULT 0
                ) STRICT
                """
            )
            .execute(db)
        }
    }
}
