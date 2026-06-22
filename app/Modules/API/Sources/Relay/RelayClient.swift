import Foundation
import Utils

/// The common envelope of a replicant.space webhook delivery.
/// Top-level `type` is one of: "event", "message", "bobnet"
/// ("webhook_verification" never reaches the log — the relay consumes it).
public struct GameEvent: Decodable, Sendable {
    public let type: String
    public let eventType: String?
    public let deviceCode: String?
    public let deviceType: String?
    public let replicantCode: String?
    /// ISO-8601 with timezone offset, kept as a string to sidestep
    /// fractional-seconds parsing inconsistencies. Parse at the call site
    /// if you need a Date.
    public let timestamp: String?
    public let payload: [String: JSONValue]?

    enum CodingKeys: String, CodingKey {
        case type
        case eventType = "event_type"
        case deviceCode = "device_code"
        case deviceType = "device_type"
        case replicantCode = "replicant_code"
        case timestamp
        case payload
    }
}

/// One entry from the relay's event log.
public struct RelayEvent: Sendable, Identifiable {
    /// Redis stream ID, e.g. "1779087998123-0". Doubles as the cursor.
    public let id: String
    /// The raw webhook payload as delivered by the game.
    public let raw: Data

    public func decoded() throws -> GameEvent {
        try JSONDecoder().decode(GameEvent.self, from: raw)
    }
}

public struct RelayPage: Sendable {
    public let events: [RelayEvent]
    /// Pass this back as `after:` to fetch strictly newer events.
    public let nextCursor: String
}

public enum RelayError: Error {
    case badStatus(Int)
    case malformedResponse
}

/// Client for the Rust relay's `/api/events` endpoint. Polling this is free
/// and unlimited — it never counts against the game's rate limits.
public struct RelayClient: Sendable {

    private let baseURL: URL
    private let clientToken: String
    private let session: URLSession

    /// - Parameters:
    ///   - baseURL: e.g. `https://your-relay.vercel.app`
    ///   - clientToken: must match the relay's `RELAY_CLIENT_TOKEN` env var.
    public init(baseURL: URL, clientToken: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.clientToken = clientToken
        self.session = session
    }

    /// Fetch one page of events after the given cursor (nil = from the
    /// start of the retained log).
    public func events(after cursor: String?, limit: Int = 100) async throws -> RelayPage {
        var components = URLComponents(
            url: baseURL.appending(path: "api/events"),
            resolvingAgainstBaseURL: false
        )!
        var queryItems = [URLQueryItem(name: "limit", value: String(limit))]
        if let cursor, !cursor.isEmpty {
            queryItems.append(URLQueryItem(name: "cursor", value: cursor))
        }
        components.queryItems = queryItems

        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(clientToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw RelayError.malformedResponse }
        guard http.statusCode == 200 else { throw RelayError.badStatus(http.statusCode) }

        struct Page: Decodable {
            struct Item: Decodable {
                let id: String
                let event: JSONValue
            }
            let events: [Item]
            let nextCursor: String

            enum CodingKeys: String, CodingKey {
                case events
                case nextCursor = "next_cursor"
            }
        }

        let page = try JSONDecoder().decode(Page.self, from: data)
        let encoder = JSONEncoder()
        let events = try page.events.map { item in
            RelayEvent(id: item.id, raw: try encoder.encode(item.event))
        }
        return RelayPage(events: events, nextCursor: page.nextCursor)
    }

    /// A long-lived stream of events using SSE. Drains history after `cursor`,
    /// then receives new events in near-real-time as they arrive. The server
    /// closes the connection at Vercel's max function duration; the client
    /// reconnects automatically using `Last-Event-ID`.
    ///
    /// Persist each consumed event's `id` (it's the cursor) so the app resumes
    /// where it left off across launches.
    ///
    ///     for try await event in relay.stream(from: savedCursor) {
    ///         let game = try event.decoded()
    ///         saveCursor(event.id)
    ///     }
    public func stream(from cursor: String? = nil) -> AsyncThrowingStream<RelayEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var lastEventID: String? = cursor
                var retryDelay: Duration = .seconds(1)

                while !Task.isCancelled {
                    do {
                        var components = URLComponents(
                            url: baseURL.appending(path: "api/stream"),
                            resolvingAgainstBaseURL: false
                        )!
                        if let id = lastEventID {
                            components.queryItems = [URLQueryItem(name: "cursor", value: id)]
                        }

                        var request = URLRequest(url: components.url!)
                        request.setValue("Bearer \(clientToken)", forHTTPHeaderField: "Authorization")
                        if let id = lastEventID {
                            request.setValue(id, forHTTPHeaderField: "Last-Event-ID")
                        }

                        let (bytes, response) = try await session.bytes(for: request)
                        guard let http = response as? HTTPURLResponse else {
                            throw RelayError.malformedResponse
                        }
                        guard http.statusCode == 200 else {
                            throw RelayError.badStatus(http.statusCode)
                        }

                        var pendingID: String? = nil
                        var pendingData: String? = nil

                        for try await line in bytes.lines {
                            guard !Task.isCancelled else { break }

                            if line.isEmpty {
                                // Blank line = end of SSE event.
                                if let id = pendingID, let dataStr = pendingData,
                                   let data = dataStr.data(using: .utf8)
                                {
                                    lastEventID = id
                                    continuation.yield(RelayEvent(id: id, raw: data))
                                }
                                pendingID = nil
                                pendingData = nil
                            } else if line.hasPrefix("id:") {
                                pendingID = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                            } else if line.hasPrefix("data:") {
                                pendingData = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                            } else if line.hasPrefix("retry:") {
                                if let ms = Int(line.dropFirst(6).trimmingCharacters(in: .whitespaces)) {
                                    retryDelay = .milliseconds(ms)
                                }
                            }
                            // Lines starting with ":" are SSE comments (keepalive); skip.
                        }
                    } catch is CancellationError {
                        break
                    } catch {
                        // Network or server error — back off before reconnecting.
                        guard !Task.isCancelled else { break }
                        try? await Task.sleep(for: retryDelay)
                        continue
                    }

                    // Server closed the connection normally (e.g. Vercel max duration hit).
                    // Reconnect quickly; Last-Event-ID ensures no events are missed.
                    if !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                }

                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
