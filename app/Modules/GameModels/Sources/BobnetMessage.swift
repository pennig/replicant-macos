//
//  BobnetMessage.swift
//  Replicould — shared dependency clients
//
//  The locally-persisted Bobnet chat record. Bobnet exists *only* as relay
//  webhooks (no authoritative REST endpoint), so unlike every other table this
//  one is populated solely from the relay and persisted locally so history
//  survives relaunch (IMPLEMENTATION_PLAN §4.5). The relay delivers a
//  `{"type":"bobnet","messages":[…]}` envelope whose array lives outside the
//  generic event envelope, so the bobnet route decodes the raw bytes here.
//

import Foundation
import SQLiteData

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

// MARK: - Wire decoding

extension BobnetMessage {
    /// Decode a relay `bobnet` envelope's `messages[]` into records. Returns an
    /// empty array on any decode failure, so one malformed delivery never wedges
    /// ingestion.
    public static func decode(from data: Data) -> [BobnetMessage] {
        guard let payload = try? JSONDecoder().decode(WirePayload.self, from: data) else { return [] }
        return payload.messages.map(BobnetMessage.init(wire:))
    }

    private init(wire: WirePayload.Message) {
        self.init(
            id: wire.id,
            replicantName: wire.replicantName ?? "",
            replicantCode: wire.replicantCode ?? "",
            currentStar: wire.currentStar,
            channel: wire.channel ?? "",
            message: wire.message ?? "",
            time: Self.parseTimestamp(wire.time ?? "")
        )
    }

    private struct WirePayload: Decodable {
        let messages: [Message]
        struct Message: Decodable {
            let id: Int
            let replicantName: String?
            let replicantCode: String?
            let currentStar: String?
            let channel: String?
            let message: String?
            let time: String?

            enum CodingKeys: String, CodingKey {
                case id, channel, message, time
                case replicantName = "replicant_name"
                case replicantCode = "replicant_code"
                case currentStar = "current_star"
            }
        }
    }

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
