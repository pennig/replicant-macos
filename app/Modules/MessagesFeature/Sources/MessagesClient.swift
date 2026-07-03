//
//  MessagesClient.swift
//  Replicould — Messages feature
//
//  The dependency that talks to the messages endpoints. It fetches the inbox
//  (`GET /v1/messages`) and marks messages read (`POST /v1/messages/read`) via
//  the generated `ReplicantSpace` client, so every call inherits bearer auth,
//  rate limiting, and logging from its middleware stack. Generated payloads are
//  mapped to value-typed `Message` records. Exposed via `@Dependency(\.messagesClient)`.
//

import API
import ComposableArchitecture
import DependencyClients
import Foundation
import GameModels

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
        _ cursor: Int?,
        _ limit: Int,
        _ unreadOnly: Bool
    ) async throws -> MessagePage

    /// Mark messages read. Pass explicit `ids`, or `markAll: true` to clear the
    /// whole inbox.
    public var markRead: @Sendable (
        _ ids: [Int]?,
        _ markAll: Bool
    ) async throws -> Void
}

// MARK: - Live implementation

extension MessagesClient: DependencyKey {
    public static let liveValue = MessagesClient(
        fetch: { cursor, limit, unreadOnly in
            @Dependency(\.gameClient) var gameClient
            let client = gameClient()
            // `cursor` and `latest` are mutually exclusive per the API.
            let output = try await client.getV1Messages(query: .init(
                cursor: cursor,
                limit: limit,
                latest: cursor == nil ? true : nil,
                unreadOnly: unreadOnly
            ))
            let body = try output.ok.body.json
            return MessagePage(
                messages: (body.messages ?? []).map(Message.init(schema:)),
                nextCursor: body.nextCursor,
                unreadCount: body.unreadMessageCount ?? 0
            )
        },
        markRead: { ids, markAll in
            @Dependency(\.gameClient) var gameClient
            _ = try await gameClient().postV1MessagesRead(
                body: .json(.init(ids: ids, markAll: markAll))
            ).ok
        }
    )
}

// MARK: - Test / preview implementation

extension MessagesClient: TestDependencyKey {
    /// An empty inbox — the safe default for unit tests, which override `fetch`
    /// and `markRead` with their own behavior.
    public static let testValue = MessagesClient(
        fetch: { _, _, _ in MessagePage(messages: [], nextCursor: nil, unreadCount: 0) },
        markRead: { _, _ in }
    )

    /// Previews get the sample inbox so the UI renders with content.
    public static let previewValue = MessagesClient(
        fetch: { _, _, _ in
            MessagePage(
                messages: Message.previewInbox,
                nextCursor: nil,
                unreadCount: Message.previewInbox.filter { !$0.isRead }.count
            )
        },
        markRead: { _, _ in }
    )
}

extension DependencyValues {
    public var messagesClient: MessagesClient {
        get { self[MessagesClient.self] }
        set { self[MessagesClient.self] = newValue }
    }
}

// MARK: - Mapping

extension Message {
    /// Maps a generated message schema onto the local record, parsing the
    /// ISO-8601 `createdAt` timestamp.
    init(schema: Components.Schemas.AppSchemasMessagesMessageSchema) {
        self.init(
            id: schema.id ?? 0,
            messageType: schema.messageType ?? "",
            title: schema.title ?? "",
            body: schema.body ?? "",
            isRead: schema.isRead ?? false,
            createdAt: Self.parseTimestamp(schema.createdAt ?? "")
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
