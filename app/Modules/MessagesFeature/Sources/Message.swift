//
//  Message.swift
//  Replicould — Messages feature
//
//  The locally-persisted inbox record plus its schema. Messages are fetched
//  from `GET /v1/messages` and upserted into SQLite so the inbox reads
//  instantly offline and survives relaunches. Mirrors the backend
//  `app_schemas_messages_MessageSchema` payload.
//

import Foundation
import SQLiteData

/// A single message in the player's inbox.
///
/// The column names intentionally track the table's Swift property names; the
/// snake_case backend keys (`message_type`, `is_read`, `created_at`) are mapped
/// at the networking boundary in `MessagesClient`.
@Table
public struct Message: Identifiable, Equatable, Sendable {
    /// Server-assigned identifier; also the SQLite primary key.
    public let id: Int
    /// Backend category string, e.g. `"system"`, `"combat"`, `"trade"`.
    public var messageType: String
    public var title: String
    public var body: String
    public var isRead: Bool
    public var createdAt: Date

    public init(
        id: Int,
        messageType: String,
        title: String,
        body: String,
        isRead: Bool,
        createdAt: Date
    ) {
        self.id = id
        self.messageType = messageType
        self.title = title
        self.body = body
        self.isRead = isRead
        self.createdAt = createdAt
    }
}

// MARK: - Schema

extension Message {
    /// Registers the `messages` table migration. Kept here, alongside the model,
    /// so the schema and the type it backs never drift apart. Composed into the
    /// app's `bootstrapDatabase` alongside other features' tables.
    public static func registerMigrations(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("Create 'messages' table") { db in
            try #sql(
                """
                CREATE TABLE "messages" (
                  "id" INTEGER PRIMARY KEY NOT NULL,
                  "messageType" TEXT NOT NULL DEFAULT '',
                  "title" TEXT NOT NULL DEFAULT '',
                  "body" TEXT NOT NULL DEFAULT '',
                  "isRead" INTEGER NOT NULL DEFAULT 0,
                  "createdAt" TEXT NOT NULL
                ) STRICT
                """
            )
            .execute(db)
        }
    }
}

// MARK: - Preview fixtures

extension Message {
    /// Sample inbox used by Xcode previews and the `MessagesClient` preview
    /// value. Tests deliberately define their own seeds instead of sharing.
    static let previewInbox: [Message] = [
        Message(
            id: 4_021,
            messageType: "system",
            title: "Replication quota increased",
            body: "Your probe's replication quota has been raised to 12 concurrent instances following a sustained uptime streak.",
            isRead: false,
            createdAt: Date(timeIntervalSince1970: 1_750_000_000)
        ),
        Message(
            id: 4_018,
            messageType: "combat",
            title: "Skirmish at Elysium Shelf",
            body: "A rival swarm probed your relay at Elysium Shelf. Defenses held; two harvesters sustained minor damage.",
            isRead: false,
            createdAt: Date(timeIntervalSince1970: 1_749_900_000)
        ),
        Message(
            id: 4_010,
            messageType: "trade",
            title: "Resource exchange settled",
            body: "Your standing offer of 400 iron for 120 rare earths was filled by an NPC collective at Olympus Rim.",
            isRead: true,
            createdAt: Date(timeIntervalSince1970: 1_749_700_000)
        ),
    ]
}
