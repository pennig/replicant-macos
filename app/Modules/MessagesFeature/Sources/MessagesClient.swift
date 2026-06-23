//
//  MessagesClient.swift
//  Replicould — Messages feature
//
//  The dependency that talks to the messages endpoints. It fetches the inbox
//  (`GET /v1/messages`) and marks messages read (`POST /v1/messages/read`),
//  authenticating with the session bearer token. Decoded payloads are mapped to
//  value-typed `Message` records. Exposed via `@Dependency(\.messagesClient)`.
//
//  Like `RawAPIClient`, this stays on plain URLSession + Codable so the feature
//  doesn't pull in the generated OpenAPI client.
//

import ComposableArchitecture
import Foundation
import OSLog

public struct MessagePage: Equatable, Sendable {
    public var messages: [Message]
    public var nextCursor: Int?
    public var unreadCount: Int

    public init(messages: [Message], nextCursor: Int?, unreadCount: Int) {
        self.messages = messages
        self.nextCursor = nextCursor
        self.unreadCount = unreadCount
    }
}

public struct MessagesClient: Sendable {
    /// Fetch a page of the inbox. `cursor` pages forward; omit it for the head
    /// of the list. `unreadOnly` restricts to unread messages.
    public var fetch: @Sendable (
        _ apiKey: String,
        _ cursor: Int?,
        _ limit: Int,
        _ unreadOnly: Bool
    ) async throws -> MessagePage

    /// Mark messages read. Pass explicit `ids`, or `markAll: true` to clear the
    /// whole inbox.
    public var markRead: @Sendable (
        _ apiKey: String,
        _ ids: [Int]?,
        _ markAll: Bool
    ) async throws -> Void
}

enum MessagesClientError: LocalizedError {
    case invalidURL
    case nonHTTPResponse
    case http(status: Int, message: String?)

    var errorDescription: String? {
        switch self {
        case .invalidURL:          "The messages request URL is invalid."
        case .nonHTTPResponse:     "The server returned a non-HTTP response."
        case let .http(status, message):
            message ?? "The server responded with status \(status)."
        }
    }
}

extension MessagesClient {
    /// The game's default API base. Mirrors `ReplicantSpace.defaultServerURL`;
    /// kept local so this feature doesn't pull in the generated OpenAPI client.
    static let baseURL = URL(string: "https://api.replicant.space/v1")!
}

// MARK: - Live implementation

extension MessagesClient: DependencyKey {
    public static let liveValue = MessagesClient(
        fetch: { apiKey, cursor, limit, unreadOnly in
            guard var components = URLComponents(
                url: baseURL.appending(path: "messages"),
                resolvingAgainstBaseURL: false
            ) else { throw MessagesClientError.invalidURL }

            var items = [URLQueryItem(name: "limit", value: String(limit))]
            // `cursor` and `latest` are mutually exclusive per the API.
            if let cursor {
                items.append(URLQueryItem(name: "cursor", value: String(cursor)))
            } else {
                items.append(URLQueryItem(name: "latest", value: "true"))
            }
            if unreadOnly { items.append(URLQueryItem(name: "unread_only", value: "true")) }
            components.queryItems = items

            guard let url = components.url else { throw MessagesClientError.invalidURL }
            var request = URLRequest(url: url)
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

            let (data, response) = try await URLSession.shared.data(for: request)
            try validate(response, data: data)

            let payload = try JSONDecoder().decode(MessageListResponse.self, from: data)
            return MessagePage(
                messages: payload.messages.map(Message.init(dto:)),
                nextCursor: payload.next_cursor,
                unreadCount: payload.unread_message_count
            )
        },
        markRead: { apiKey, ids, markAll in
            guard let url = URLComponents(
                url: baseURL.appending(path: "messages/read"),
                resolvingAgainstBaseURL: false
            )?.url else { throw MessagesClientError.invalidURL }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(MessagesReadRequest(ids: ids, mark_all: markAll))

            let (data, response) = try await URLSession.shared.data(for: request)
            try validate(response, data: data)
        }
    )

    /// Throws a descriptive error for any non-2xx response, surfacing the
    /// backend's `message` field when present.
    private static func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw MessagesClientError.nonHTTPResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = try? JSONDecoder().decode(ErrorResponse.self, from: data).message
            throw MessagesClientError.http(status: http.statusCode, message: message)
        }
    }
}

// MARK: - Test / preview implementation

extension MessagesClient: TestDependencyKey {
    /// An empty inbox — the safe default for unit tests, which override `fetch`
    /// and `markRead` with their own behavior.
    public static let testValue = MessagesClient(
        fetch: { _, _, _, _ in MessagePage(messages: [], nextCursor: nil, unreadCount: 0) },
        markRead: { _, _, _ in }
    )

    /// Previews get the sample inbox so the UI renders with content.
    public static let previewValue = MessagesClient(
        fetch: { _, _, _, _ in
            MessagePage(
                messages: Message.previewInbox,
                nextCursor: nil,
                unreadCount: Message.previewInbox.filter { !$0.isRead }.count
            )
        },
        markRead: { _, _, _ in }
    )
}

extension DependencyValues {
    public var messagesClient: MessagesClient {
        get { self[MessagesClient.self] }
        set { self[MessagesClient.self] = newValue }
    }
}

// MARK: - Wire payloads

/// Decodes `app_schemas_messages_MessageListResponseSchema`.
private struct MessageListResponse: Decodable {
    var messages: [MessageDTO]
    var next_cursor: Int?
    var unread_message_count: Int
}

/// Decodes `app_schemas_messages_MessageSchema`.
struct MessageDTO: Decodable {
    var id: Int
    var message_type: String
    var title: String
    var body: String
    var is_read: Bool
    var created_at: String
}

private struct MessagesReadRequest: Encodable {
    var ids: [Int]?
    var mark_all: Bool
}

private struct ErrorResponse: Decodable {
    var message: String?
}

extension Message {
    /// Maps a decoded wire message onto the local record, parsing the ISO-8601
    /// `created_at` timestamp.
    init(dto: MessageDTO) {
        self.init(
            id: dto.id,
            messageType: dto.message_type,
            title: dto.title,
            body: dto.body,
            isRead: dto.is_read,
            createdAt: Self.parseTimestamp(dto.created_at)
        )
    }

    /// Parses an ISO-8601 timestamp, tolerating the presence or absence of
    /// fractional seconds. Falls back to the Unix epoch if unparseable so a
    /// malformed row still sorts predictably rather than crashing.
    static func parseTimestamp(_ string: String) -> Date {
        if let date = try? Date(string, strategy: isoWithFraction) { return date }
        if let date = try? Date(string, strategy: isoPlain) { return date }
        return Date(timeIntervalSince1970: 0)
    }

    private static let isoWithFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let isoPlain = Date.ISO8601FormatStyle()
}
