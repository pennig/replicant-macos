//
//  LocationEventsClient.swift
//  Replicould — GameServices (shared clients + command engine)
//
//  The location-events ("quests") client. One authoritative call —
//  `GET /v1/accounts/events?status=all` — returns the whole account's discovered
//  events with full detail (criteria, live progress, rewards), paged by an integer
//  cursor. `refresh` walks every page and upserts into the `LocationEvent` table
//  (preserving local `firstSeenAt`), so the Location Events screen and its sidebar
//  badge stay live via `@FetchAll`. This mirrors `ReplicantsClient.refresh`: a
//  self-contained authoritative re-read, reused both by the feature on appear and
//  by a relay nudge (the same shape as the inbox refresh). Exposed via
//  `@Dependency(\.locationEventsClient)`.
//

import API
import ComposableArchitecture
import Foundation
import GameModels
import SQLiteData
import Utils

public struct LocationEventsClient: Sendable {
    /// Walk the whole `accounts/events` list and upsert it into the
    /// `LocationEvent` table. Returns the number of events now known.
    public var refresh: @Sendable () async throws -> Int
    /// Resolve (complete) a single event — an empty POST to
    /// `locations/{location}/events/{designation}` — then re-read the
    /// authoritative list so the row flips to `completed`. Throws
    /// `LocationEventError.rejected` with the server's message on failure.
    public var complete: @Sendable (_ location: String, _ designation: String) async throws -> Void
}

/// A location-event completion that the server refused (e.g. no replicant present,
/// objectives not yet met), carrying the server's message for the UI banner.
public struct LocationEventError: Error, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var localizedDescription: String { message }
}

// MARK: - Live implementation

extension LocationEventsClient: DependencyKey {
    /// Page size (the endpoint caps at 200); a generous page keeps the walk to a
    /// handful of requests.
    private static let pageSize = 200
    /// A backstop so a misbehaving cursor can't loop forever.
    private static let maxPages = 50

    public static let liveValue = LocationEventsClient(
        refresh: { try await performRefresh() },
        complete: { location, designation in
            @Dependency(\.gameClient) var gameClient

            let output = try await gameClient().postV1LocationsLocationCodeEventsDesignation(
                path: .init(locationCode: location, designation: designation)
            )
            // The endpoint documents only a `default` response, so success and
            // failure both arrive here — split on the status code.
            switch output {
            case let .default(statusCode, response):
                guard (200..<300).contains(statusCode) else {
                    let message = (try? response.body.json.message)
                        ?? "The event could not be completed (\(statusCode))."
                    throw LocationEventError(message)
                }
            }
            // Re-read the authoritative list so the resolved event flips to
            // `completed` (and its objectivesMet/progress settle).
            _ = try await performRefresh()
        }
    )

    /// Walk every `accounts/events` page and upsert into the `LocationEvent` table,
    /// preserving local `firstSeenAt`. Returns the total event count.
    private static func performRefresh() async throws -> Int {
        @Dependency(\.gameClient) var gameClient
        @Dependency(\.defaultDatabase) var database
        @Dependency(\.date) var date

        // Resolve the client once and reuse it across the whole paged walk.
        let client = gameClient()
        var cursor: Int? = nil
        var pages = 0
        repeat {
            let body = try await client.getV1AccountsEvents(
                query: .init(status: "all", cursor: cursor, limit: pageSize)
            ).ok.body.json
            // Re-encode the freeform payload to `JSONValue` so criteria/progress/
            // rewards ride through verbatim for the quest sheet.
            let events = jsonValue(from: body)["events"]?.arrayValue ?? []
            try await database.write { db in
                try LocationEvent.upsert(events: events, into: db, now: date.now)
            }
            cursor = body.nextCursor
            pages += 1
        } while cursor != nil && pages < maxPages

        return try await database.read { db in try LocationEvent.fetchCount(db) }
    }

    private static let jsonEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    /// Re-encode a generated payload into a `JSONValue`, preserving the freeform
    /// criteria/progress/rewards subtrees the typed schema leaves opaque.
    private static func jsonValue(from value: some Encodable) -> JSONValue {
        guard
            let data = try? jsonEncoder.encode(value),
            let json = try? JSONDecoder().decode(JSONValue.self, from: data)
        else { return .object([:]) }
        return json
    }
}

// MARK: - Test / preview implementation

extension LocationEventsClient: TestDependencyKey {
    /// Unimplemented by default so a test that reaches the network without
    /// stubbing it fails loudly.
    public static let testValue = LocationEventsClient(
        refresh: unimplemented("LocationEventsClient.refresh", placeholder: 0),
        complete: unimplemented("LocationEventsClient.complete")
    )
}

extension DependencyValues {
    public var locationEventsClient: LocationEventsClient {
        get { self[LocationEventsClient.self] }
        set { self[LocationEventsClient.self] = newValue }
    }
}
