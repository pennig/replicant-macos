import Foundation
import OpenAPIRuntime
import Utils

/// One page of a replicant's event log, mapped to stable DTOs. (File-scope, not
/// nested — a type can't be nested in a protocol extension.)
struct EventLogPage {
    /// This page's entries, **oldest-first** (unless the request passed
    /// `latest: true`, which returns the newest-first tail).
    let entries: [GameLogEntry]
    /// Cursor to resume from for the next (newer) page — the largest event id
    /// in this page. Passing it as `cursor` returns entries with a greater id.
    /// Nil once the newest entry (the log's tip) has been reached.
    let nextCursor: Int?
}

extension APIProtocol {

    /// Fetch one page of `GET /v1/replicants/{code}/events`.
    ///
    /// Unlike the former hand-rolled client, this goes through the generated
    /// client's middleware stack, so it inherits bearer auth, rate limiting,
    /// and request/response logging for free.
    ///
    /// - Parameters:
    ///   - cursor: resume position from a prior page's `nextCursor` — returns
    ///     entries with a greater id (forward, toward newest). Mutually
    ///     exclusive with `latest`.
    ///   - latest: fetch the newest tail (newest-first) instead of paging
    ///     forward. Use once to seed a resume point on a cold start.
    func eventLog(
        replicantCode: String,
        cursor: Int? = nil,
        limit: Int = 100,
        latest: Bool? = nil,
        eventType: String? = nil
    ) async throws -> EventLogPage {
        let output = try await getV1ReplicantsReplicantCodeEvents(
            path: .init(replicantCode: replicantCode),
            query: .init(eventType: eventType, cursor: cursor, limit: limit, latest: latest)
        )
        let body = try output.ok.body.json
        let entries = (body.events ?? []).map(GameLogEntry.init(schema:))
        return EventLogPage(entries: entries, nextCursor: body.nextCursor)
    }
}

extension GameLogEntry {

    /// Map a generated event into the stable DTO.
    init(schema: Components.Schemas.AppSchemasEventsEventSchema) {
        self.init(
            id: schema.id,
            createdAt: schema.createdAt ?? "",
            deviceCode: schema.deviceCode,
            deviceType: schema.deviceType,
            eventType: schema.eventType,
            message: schema.message,
            payload: schema.payload.flatMap(GameLogEntry.bridgePayload)
        )
    }

    /// The generated `payload` is a free-form object container; re-encode it
    /// through `JSONValue` so the rest of the app sees one payload type. An
    /// empty payload collapses to nil to match the relay channel's shape.
    private static func bridgePayload(
        _ payload: Components.Schemas.AppSchemasEventsEventSchema.PayloadPayload
    ) -> [String: JSONValue]? {
        guard !payload.additionalProperties.isEmpty else { return nil }
        guard
            let data = try? JSONEncoder().encode(payload),
            let dict = try? JSONDecoder().decode([String: JSONValue].self, from: data)
        else { return nil }
        return dict
    }
}
