//
//  BobnetMessage.swift
//  Replicould — shared dependency clients
//
//  The locally-persisted Bobnet chat record. Bobnet exists *only* as event-stream
//  pushes (no authoritative REST endpoint), so unlike every other table this one
//  is populated solely from the stream and persisted locally so history survives
//  relaunch (ARCHITECTURE_REVIEW §4.5, "one connection, three logical streams" —
//  the plan's §4 has no such subsection). Each `bobnet.new_*` event carries one
//  message in its `payload`, which `init(eventPayload:createdAt:)` maps here.
//

import Foundation
import SQLiteData
import Utils

/// A single Bobnet chat message.
@Table
public struct BobnetMessage: Identifiable, Equatable, Sendable {
    /// Server-assigned identifier; also the SQLite primary key (dedups replays).
    @Column(primaryKey: true) public var id: Int
    public var replicantName: String
    public var replicantCode: String
    public var currentStar: String?
    public var channel: String
    public var message: String
    public var time: Date

    public init(
        id: Int,
        replicantName: String,
        replicantCode: String,
        currentStar: String?,
        channel: String,
        message: String,
        time: Date
    ) {
        self.id = id
        self.replicantName = replicantName
        self.replicantCode = replicantCode
        self.currentStar = currentStar
        self.channel = channel
        self.message = message
        self.time = time
    }
}

// MARK: - Event-stream decoding

extension BobnetMessage {
    /// Build a record from a `bobnet.new_*` event's payload. The native event
    /// stream delivers one bobnet message per event (in `payload`), unlike the
    /// old relay envelope's top-level `messages[]` array. Returns nil when the
    /// payload carries no numeric `id` (nothing to key/dedup on).
    ///
    /// - Parameter createdAt: the event's envelope timestamp, used when the
    ///   payload itself carries no `time` (falls back to the epoch, matching the
    ///   wire decoder's tolerance).
    public init?(eventPayload payload: [String: JSONValue], createdAt: Date?) {
        guard let id = payload["id"]?.numberValue.map({ Int($0) }) else { return nil }
        let time: Date = payload["time"]?.stringValue.map(Self.parseTimestamp)
            ?? createdAt
            ?? Date(timeIntervalSince1970: 0)
        self.init(
            id: id,
            replicantName: payload["replicant_name"]?.stringValue ?? "",
            replicantCode: payload["replicant_code"]?.stringValue ?? "",
            currentStar: payload["current_star"]?.stringValue,
            channel: payload["channel"]?.stringValue ?? "",
            message: payload["message"]?.stringValue ?? "",
            time: time
        )
    }
}

// MARK: - Timestamp parsing

extension BobnetMessage {
    /// Parses an ISO-8601 timestamp (with or without fractional seconds),
    /// falling back to the Unix epoch so a malformed row still sorts predictably.
    static func parseTimestamp(_ string: String) -> Date {
        if let date = try? Date(string, strategy: isoWithFraction) { return date }
        if let date = try? Date(string, strategy: isoPlain) { return date }
        return Date(timeIntervalSince1970: 0)
    }

    private static let isoWithFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let isoPlain = Date.ISO8601FormatStyle()
}

// MARK: - Schema

extension BobnetMessage {
    /// Registers the `bobnetMessages` table migration. Composed into the app's
    /// `bootstrapDatabase` alongside other tables.
    public static func registerMigrations(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("Create 'bobnetMessages' table") { db in
            try #sql(
                """
                CREATE TABLE "bobnetMessages" (
                  "id" INTEGER PRIMARY KEY NOT NULL,
                  "replicantName" TEXT NOT NULL DEFAULT '',
                  "replicantCode" TEXT NOT NULL DEFAULT '',
                  "currentStar" TEXT,
                  "channel" TEXT NOT NULL DEFAULT '',
                  "message" TEXT NOT NULL DEFAULT '',
                  "time" TEXT NOT NULL
                ) STRICT
                """
            )
            .execute(db)
        }
    }
}
