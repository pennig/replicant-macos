//
//  GameEventEnvelope.swift
//  Replicould — API (event stream)
//
//  One game event, normalized so the app doesn't care which channel it arrived
//  on. Both the native SSE stream (`GET /v1/events/stream`) and the account-wide
//  catch-up pull (`GET /v1/events`) produce these — they share one envelope
//  (`app_schemas_events_GameEventSchema`) and one dotted-name taxonomy, so unlike
//  the old two-channel relay there is no cross-channel fingerprinting: the
//  server-assigned stream `id` is a stable, globally-ordered dedup key.
//

import Foundation
import OpenAPIRuntime
import Utils

/// One decoded game event from the native event stream (or its pull companion).
public struct GameEventEnvelope: Sendable, Identifiable {

    /// Which channel delivered this event. Replaces the old `UnifiedEvent.Source`
    /// relay/game-log distinction: only *live* stream events advance the roster
    /// location, while `catchUp` events are historical replay being reconstructed
    /// on (re)start and must not walk the roster through stale waypoints.
    public enum Provenance: Sendable, Equatable {
        /// Delivered live over the SSE stream.
        case stream
        /// Recovered from the account-wide `GET /v1/events` pull during catch-up.
        case catchUp
    }

    /// Redis stream ID, e.g. `1752681600000-0`. The resume cursor *and* the
    /// dedup key — identical for the same logical event across both channels.
    public let id: String
    /// Schema version of the payload shape.
    public let version: Int?
    /// Coarse family, e.g. `"mining"`. Routing's primary key.
    public let category: String
    /// Dotted event name, e.g. `"mining.started"`. Routing's exact key.
    public let event: String
    public let replicantCode: String?
    public let deviceCode: String?
    public let deviceType: String?
    /// System designation the event concerns (now a first-class envelope field
    /// rather than something dug out of `payload`).
    public let star: String?
    /// Location designation the event concerns.
    public let location: String?
    public let payload: [String: JSONValue]?
    /// ISO-8601 string as delivered. Parse via `date`.
    public let createdAt: String?

    /// Set by the pipeline, not decoded from the wire.
    public var provenance: Provenance = .stream

    public init(
        id: String,
        version: Int? = nil,
        category: String,
        event: String,
        replicantCode: String? = nil,
        deviceCode: String? = nil,
        deviceType: String? = nil,
        star: String? = nil,
        location: String? = nil,
        payload: [String: JSONValue]? = nil,
        createdAt: String? = nil,
        provenance: Provenance = .stream
    ) {
        self.id = id
        self.version = version
        self.category = category
        self.event = event
        self.replicantCode = replicantCode
        self.deviceCode = deviceCode
        self.deviceType = deviceType
        self.star = star
        self.location = location
        self.payload = payload
        self.createdAt = createdAt
        self.provenance = provenance
    }

    /// Parsed timestamp, when the string is well-formed.
    public var date: Date? {
        createdAt.flatMap(GameEventEnvelope.parseTimestamp)
    }

    // MARK: - Timestamp parsing

    /// ISO-8601 with timezone offset, as the game emits.
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

// MARK: - Decode from a live SSE frame

extension GameEventEnvelope {
    /// Build an envelope from a raw SSE frame. The frame's `id:` and `event:`
    /// fields are authoritative (the `data:` JSON isn't guaranteed to repeat
    /// them); everything else comes from the decoded `data:` body. Returns nil if
    /// the body isn't decodable, so one malformed delivery never wedges the stream.
    public init?(streamed: StreamedEvent) {
        guard let wire = try? JSONDecoder().decode(Wire.self, from: streamed.raw) else { return nil }
        // Frame id/event win; fall back to the body if the frame omitted them.
        let id = streamed.id.isEmpty ? (wire.id ?? "") : streamed.id
        let event = streamed.eventName.isEmpty ? (wire.event ?? "") : streamed.eventName
        guard !id.isEmpty, !event.isEmpty else { return nil }
        self.init(
            id: id,
            version: wire.version,
            // Category defaults to the dotted name's prefix when the body omits it.
            category: wire.category ?? String(event.split(separator: ".").first ?? ""),
            event: event,
            replicantCode: wire.replicantCode,
            deviceCode: wire.deviceCode,
            deviceType: wire.deviceType,
            star: wire.star,
            location: wire.location,
            // Collapse an empty payload to nil, matching the pull bridge.
            payload: (wire.payload?.isEmpty ?? true) ? nil : wire.payload,
            createdAt: wire.createdAt,
            provenance: .stream
        )
    }

    /// Lenient decode of the SSE `data:` body — every field optional, since the
    /// frame carries the authoritative id/event and the body shape may evolve.
    private struct Wire: Decodable {
        let id: String?
        let version: Int?
        let category: String?
        let event: String?
        let replicantCode: String?
        let deviceCode: String?
        let deviceType: String?
        let star: String?
        let location: String?
        let payload: [String: JSONValue]?
        let createdAt: String?

        enum CodingKeys: String, CodingKey {
            case id, version, category, event
            case replicantCode = "replicant_code"
            case deviceCode = "device_code"
            case deviceType = "device_type"
            case star, location, payload
            case createdAt = "created_at"
        }
    }
}

// MARK: - Bridge from the generated pull schema

extension GameEventEnvelope {
    /// Map a generated `GET /v1/events` entry into the envelope. `provenance`
    /// defaults to `.catchUp` since that endpoint is the historical-replay pull;
    /// the live stream constructs envelopes via the `Decodable` path instead.
    public init(schema: Components.Schemas.AppSchemasEventsGameEventSchema, provenance: Provenance = .catchUp) {
        self.init(
            id: schema.id ?? "",
            version: schema.version,
            category: schema.category ?? "",
            event: schema.event ?? "",
            replicantCode: schema.replicantCode,
            deviceCode: schema.deviceCode,
            deviceType: schema.deviceType,
            star: schema.star,
            location: schema.location,
            payload: schema.payload.flatMap(GameEventEnvelope.bridgePayload),
            createdAt: schema.createdAt,
            provenance: provenance
        )
    }

    /// Re-encode the generated free-form `payload` container through `JSONValue`
    /// so the rest of the app sees one payload type. An empty payload collapses
    /// to nil to match the stream channel's shape.
    private static func bridgePayload(
        _ payload: Components.Schemas.AppSchemasEventsGameEventSchema.PayloadPayload
    ) -> [String: JSONValue]? {
        guard !payload.additionalProperties.isEmpty else { return nil }
        guard
            let data = try? JSONEncoder().encode(payload),
            let dict = try? JSONDecoder().decode([String: JSONValue].self, from: data)
        else { return nil }
        return dict
    }
}
