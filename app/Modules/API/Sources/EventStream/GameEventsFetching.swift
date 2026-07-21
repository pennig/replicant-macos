//
//  GameEventsFetching.swift
//  Replicould — API (event stream)
//
//  The account-wide pull companion to the SSE stream: `GET /v1/events`. Same
//  envelope, same dotted taxonomy, same string (Redis stream ID) cursor as the
//  stream, so it's used for catch-up on (re)start — paging forward from the
//  stored cursor to the tip — without any cross-taxonomy translation. Replaces
//  the old per-replicant `GET /v1/replicants/{code}/events` tier-2 walk.
//

import Foundation

/// Persists the event-stream resume cursor across app launches.
public protocol EventCursorStore: Sendable {
    func load() -> String?
    func save(_ cursor: String)
}

public struct UserDefaultsEventCursorStore: EventCursorStore {
    private let key: String
    // `UserDefaults` is thread-safe but not marked `Sendable`; the access here is safe.
    nonisolated(unsafe) private let defaults: UserDefaults

    /// A fresh key (`replicant.events.cursor`): the old relay cursor lived under a
    /// different key in a foreign id space, so first launch after the migration
    /// reads nil here and seeds fresh from the live stream tip.
    public init(key: String = "replicant.events.cursor", defaults: UserDefaults = .standard) {
        self.key = key
        self.defaults = defaults
    }

    public func load() -> String? { defaults.string(forKey: key) }
    public func save(_ cursor: String) { defaults.set(cursor, forKey: key) }
}

/// One page of `GET /v1/events`, oldest-first, with the cursor to resume from.
public struct GameEventsPage: Sendable {
    public let events: [GameEventEnvelope]
    /// Cursor for the next (newer) page — nil once the tip is reached.
    public let nextCursor: String?

    public init(events: [GameEventEnvelope], nextCursor: String?) {
        self.events = events
        self.nextCursor = nextCursor
    }
}

extension APIProtocol {

    /// Fetch one page of `GET /v1/events` (the account-wide event log).
    ///
    /// Goes through the generated client's middleware, so it inherits bearer
    /// auth, rate limiting, and logging.
    ///
    /// - Parameters:
    ///   - cursor: resume position — returns events *after* this stream ID.
    ///   - filtered: apply the account's event subscription/mute filters (matches
    ///     the stream, which applies them automatically).
    func gameEvents(
        cursor: String? = nil,
        filtered: Bool = true,
        limit: Int = 100
    ) async throws -> GameEventsPage {
        let output = try await getV1Events(
            query: .init(cursor: cursor, limit: limit, filtered: filtered)
        )
        let body = try output.ok.body.json
        let events = (body.events ?? []).map { GameEventEnvelope(schema: $0, provenance: .catchUp) }
        return GameEventsPage(events: events, nextCursor: body.nextCursor)
    }
}
