import Foundation
import OpenAPIRuntime
import Utils

extension Client {

    /// One page of a replicant's event log, mapped to stable DTOs.
    struct EventLogPage {
        let entries: [GameLogEntry]
        /// Position to resume from for the next (older) page, or nil when the
        /// log's beginning has been reached.
        let nextCursor: Int?
    }

    /// Fetch one page of `GET /v1/replicants/{code}/events`.
    ///
    /// Unlike the former hand-rolled client, this goes through the generated
    /// client's middleware stack, so it inherits bearer auth, rate limiting,
    /// and request/response logging for free.
    ///
    /// - Parameters:
    ///   - cursor: resume position from a prior page's `nextCursor`. Mutually
    ///     exclusive with `latest`.
    ///   - latest: start from the newest events (pass on the first page only).
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
