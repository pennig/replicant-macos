//
//  EventLogClient.swift
//  Replicould — GameServices (shared clients + command engine)
//
//  Persists every dispatched SSE event into the `EventLog` diagnostic table. It's
//  called from the single ingestion choke point (`EventRouter.dispatch`), so the
//  raw ledger stays complete without any feature having to opt in. Factored behind
//  a dependency (rather than writing to the DB inline in the router) so routing
//  stays unit-testable: the `testValue`/`previewValue` are no-ops, leaving
//  `GameSyncTests` and previews untouched by DB writes. Exposed via
//  `@Dependency(\.eventLogClient)`.
//

import API
import Dependencies
import Foundation
import GameModels
import SQLiteData

public struct EventLogClient: Sendable {
    /// Record one dispatched event, flagged handled/unhandled and tagged with the
    /// feature-specific routes that matched it. Best-effort — never throws.
    public var record: @Sendable (
        _ event: GameEventEnvelope,
        _ isHandled: Bool,
        _ matchedRouteIDs: [String]
    ) async -> Void
}

// MARK: - Live implementation

extension EventLogClient: DependencyKey {
    public static let liveValue = EventLogClient(
        record: { event, isHandled, matchedRouteIDs in
            @Dependency(\.defaultDatabase) var database
            @Dependency(\.date) var date
            let row = EventLog(
                envelope: event,
                isHandled: isHandled,
                matchedRouteIDs: matchedRouteIDs,
                receivedAt: date.now
            )
            // Upsert on the stream-id primary key: catch-up replay can re-deliver an
            // id the live stream already logged, so the last write simply wins.
            try? await database.write { db in
                try EventLog.upsert { row }.execute(db)
            }
        }
    )
}

// MARK: - Test / preview implementation

extension EventLogClient: TestDependencyKey {
    /// No-op: recording is a side effect of dispatch, irrelevant to routing tests
    /// and previews, and shouldn't drag a database into either.
    public static let testValue = EventLogClient(record: { _, _, _ in })
    public static let previewValue = EventLogClient(record: { _, _, _ in })
}

extension DependencyValues {
    public var eventLogClient: EventLogClient {
        get { self[EventLogClient.self] }
        set { self[EventLogClient.self] = newValue }
    }
}
