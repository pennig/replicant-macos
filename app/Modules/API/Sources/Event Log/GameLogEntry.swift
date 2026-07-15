import Foundation
import Utils

/// One entry from `GET /v1/replicants/{code}/events`.
///
/// A deliberately stable DTO: it insulates `UnifiedEvent`'s fingerprinting
/// from the regenerated OpenAPI types (whose `payload` is an
/// `OpenAPIValueContainer`, not `[String: JSONValue]`). The bridge from the
/// generated `EventSchema` lives in `GameLogFetching.swift`.
public struct GameLogEntry: Decodable, Sendable {
    /// Monotonic event id — the log's forward-paging cursor key. Newer events
    /// have larger ids; `GET …/events?cursor=<id>` returns entries with a
    /// greater id (see `APIProtocol.eventLog`).
    public let id: Int?
    public let createdAt: String
    public let deviceCode: String?
    public let deviceType: String?
    public let eventType: String?
    public let message: String?
    public let payload: [String: JSONValue]?

    enum CodingKeys: String, CodingKey {
        case id
        case createdAt = "created_at"
        case deviceCode = "device_code"
        case deviceType = "device_type"
        case eventType = "event_type"
        case message
        case payload
    }
}
