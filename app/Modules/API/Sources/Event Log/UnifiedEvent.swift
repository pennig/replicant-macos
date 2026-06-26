import CryptoKit
import Foundation
import Utils

/// One game event, normalized so the app doesn't care which channel it
/// arrived on. Both the relay (webhook) stream and the game's event log
/// produce these, and the fingerprint lets the pipeline deduplicate when
/// both channels deliver the same event.
public struct UnifiedEvent: Sendable, Identifiable {

    public enum Source: Sendable, Equatable {
        /// Pushed via webhook, read from the relay's stream.
        case relay(streamID: String)
        /// Recovered from `GET /replicants/{code}/events` during backfill.
        case gameLog
    }

    /// Stable fingerprint — identical for the same logical event regardless
    /// of channel. See `fingerprint(...)` for what goes into it.
    public let id: String
    /// Top-level webhook type: "event", "message", or "bobnet".
    /// Backfilled log entries are always "event".
    public let type: String
    public let eventType: String?
    public let deviceCode: String?
    public let deviceType: String?
    public let replicantCode: String?
    /// ISO-8601 string as delivered (webhook `timestamp` / log `created_at`).
    public let timestamp: String?
    /// Human-readable summary. Only the game log provides this.
    public let message: String?
    public let payload: [String: JSONValue]?
    public let source: Source
    /// The original relay bytes (relay source only; nil for game-log entries).
    /// Routes for `type`s whose data lives outside the generic envelope — e.g.
    /// `bobnet`, which carries a top-level `messages[]` array the envelope drops —
    /// decode this to recover their type-specific payload.
    public let rawData: Data?

    /// Parsed timestamp, when the string is well-formed.
    public var date: Date? {
        timestamp.flatMap(UnifiedEvent.parseTimestamp)
    }

    // MARK: - Construction from each channel

    /// From a relay stream entry (webhook payload).
    public init(relayEvent: RelayEvent) throws {
        let event = try relayEvent.decoded()
        self.type = event.type
        self.eventType = event.eventType
        self.deviceCode = event.deviceCode
        self.deviceType = event.deviceType
        self.replicantCode = event.replicantCode
        self.timestamp = event.timestamp
        self.message = nil
        self.payload = event.payload
        self.source = .relay(streamID: relayEvent.id)
        self.rawData = relayEvent.raw
        self.id = Self.fingerprint(
            type: event.type,
            eventType: event.eventType,
            deviceCode: event.deviceCode,
            timestamp: event.timestamp,
            payload: event.payload,
            // Non-"event" types (message/bobnet) never appear in the game
            // log, so there's nothing to dedup against — hash the raw bytes
            // to guarantee uniqueness instead.
            fallbackRaw: event.type == "event" ? nil : relayEvent.raw
        )
    }

    /// From a game event-log entry (backfill).
    public init(gameLogEntry entry: GameLogEntry, replicantCode: String) {
        self.type = "event"
        self.eventType = entry.eventType
        self.deviceCode = entry.deviceCode
        self.deviceType = entry.deviceType
        self.replicantCode = replicantCode
        self.timestamp = entry.createdAt
        self.message = entry.message
        self.payload = entry.payload
        self.source = .gameLog
        self.rawData = nil
        self.id = Self.fingerprint(
            type: "event",
            eventType: entry.eventType,
            deviceCode: entry.deviceCode,
            timestamp: entry.createdAt,
            payload: entry.payload,
            fallbackRaw: nil
        )
    }

    // MARK: - Fingerprinting

    /// Identity = (event_type, device_code, timestamp-as-epoch, canonical
    /// payload). Fields exclusive to one channel (`message`, the log's
    /// missing `replicant_code`) are deliberately excluded.
    ///
    /// Including the payload is a chosen trade-off: if the two channels ever
    /// render a payload differently for the same event, the failure mode is
    /// a *duplicate* delivery — recoverable by idempotent consumers — rather
    /// than silently dropping a genuinely distinct same-second event, which
    /// would defeat the pipeline's whole purpose.
    static func fingerprint(
        type: String,
        eventType: String?,
        deviceCode: String?,
        timestamp: String?,
        payload: [String: JSONValue]?,
        fallbackRaw: Data?
    ) -> String {
        if let fallbackRaw {
            return sha256Hex(fallbackRaw)
        }
        let epoch = timestamp.flatMap(parseTimestamp).map { String(Int($0.timeIntervalSince1970)) }
            ?? timestamp ?? ""
        let canonicalPayload = payload.map { JSONValue.object($0).canonicalString } ?? ""
        let material = [type, eventType ?? "", deviceCode ?? "", epoch, canonicalPayload]
            .joined(separator: "|")
        return sha256Hex(Data(material.utf8))
    }

    private static func sha256Hex(_ data: Data) -> String {
        // 16 bytes (128 bits) of SHA-256 — far beyond collision-safe here.
        SHA256.hash(data: data).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// ISO-8601 with timezone offset, as the game emits. Parsing to epoch
    /// makes "+01:00" vs "Z"-style renderings of the same instant equal.
    static func parseTimestamp(_ string: String) -> Date? {
        iso8601.date(from: string) ?? iso8601Fractional.date(from: string)
    }

    // Configured once and only ever read from (`date(from:)`), which is
    // thread-safe on Foundation's formatters.
    nonisolated(unsafe) private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    nonisolated(unsafe) private static let iso8601Fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

// MARK: - Canonical JSON

extension JSONValue {
    /// Deterministic serialization: object keys sorted, no whitespace.
    /// Two structurally equal values always produce the same string.
    var canonicalString: String {
        switch self {
        case .null:
            return "null"
        case .bool(let value):
            return value ? "true" : "false"
        case .number(let value):
            // Render integral doubles without the trailing ".0" so 5 and 5.0
            // (same JSON number, different decode paths) fingerprint equally.
            if value.rounded() == value, value.magnitude < 1e15 {
                return String(Int64(value))
            }
            return String(value)
        case .string(let value):
            let escaped = value
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        case .array(let values):
            return "[" + values.map(\.canonicalString).joined(separator: ",") + "]"
        case .object(let dict):
            let body = dict.keys.sorted()
                .map { "\"\($0)\":\(dict[$0]!.canonicalString)" }
                .joined(separator: ",")
            return "{" + body + "}"
        }
    }
}
