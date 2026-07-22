//
//  BobnetClient.swift
//  Replicould — Bobnet feature
//
//  The dependency that talks to the Bobnet endpoints: a relay's channel
//  directory + message history (`GET /v1/devices/{code}/channels|messages`) and
//  sending via the active replicant (`POST /v1/replicants/{code}/message`).
//  Cursor semantics (probed live): `cursor=N` pages forward (ascending ids > N,
//  `next_cursor` = last id of the page, nil at the tail); `latest=true` returns
//  the newest page descending with a nil cursor. Generated payloads map onto
//  the locally-persisted `BobnetMessage`. Exposed via `@Dependency(\.bobnetClient)`.
//

import API
import ComposableArchitecture
import Foundation
import GameModels
import GameSession

/// One entry of a relay's channel directory.
public struct BobnetChannelInfo: Equatable, Sendable {
    public var name: String
    public var lastActive: Date?

    public init(name: String, lastActive: Date?) {
        self.name = name
        self.lastActive = lastActive
    }
}

/// One page of a relay's message history.
public struct BobnetPage: Equatable, Sendable {
    public var messages: [BobnetMessage]
    public var nextCursor: Int?

    public init(messages: [BobnetMessage], nextCursor: Int?) {
        self.messages = messages
        self.nextCursor = nextCursor
    }
}

public struct BobnetClient: Sendable {
    /// The channel directory seen by a relay-capable device.
    public var channels: @Sendable (_ relayCode: String) async throws -> [BobnetChannelInfo]
    /// A page of message history visible from a relay. `cursor` pages forward
    /// (ascending ids after it); `latest` returns the newest page instead and is
    /// incompatible with `cursor`.
    public var messages: @Sendable (
        _ relayCode: String,
        _ cursor: Int?,
        _ limit: Int,
        _ latest: Bool
    ) async throws -> BobnetPage
    /// Send a message to a channel as the given replicant. Sending to a channel
    /// that doesn't exist yet creates it (and subscribes the account).
    public var send: @Sendable (
        _ replicantCode: String,
        _ channel: String,
        _ text: String
    ) async throws -> BobnetMessage
}

/// The send endpoint answered without a usable message payload.
public struct BobnetMalformedResponse: Error {}

// MARK: - Live implementation

extension BobnetClient: DependencyKey {
    public static let liveValue = BobnetClient(
        channels: { relayCode in
            @Dependency(\.gameClient) var gameClient
            let output = try await gameClient().getV1DevicesDeviceCodeChannels(
                path: .init(deviceCode: relayCode)
            )
            let body = try output.ok.body.json
            return (body.channels ?? []).compactMap { item in
                guard let name = item.name, !name.isEmpty else { return nil }
                return BobnetChannelInfo(
                    name: name,
                    lastActive: item.lastActive.map { BobnetTimestamp.parse($0) }
                )
            }
        },
        messages: { relayCode, cursor, limit, latest in
            @Dependency(\.gameClient) var gameClient
            let output = try await gameClient().getV1DevicesDeviceCodeMessages(
                path: .init(deviceCode: relayCode),
                query: .init(cursor: cursor, limit: limit, latest: latest ? true : nil)
            )
            let body = try output.ok.body.json
            return BobnetPage(
                messages: (body.messages ?? []).compactMap(BobnetMessage.init(item:)),
                nextCursor: body.nextCursor
            )
        },
        send: { replicantCode, channel, text in
            @Dependency(\.gameClient) var gameClient
            let output = try await gameClient().postV1ReplicantsReplicantCodeMessage(
                path: .init(replicantCode: replicantCode),
                body: .json(.init(channel: channel, text: text))
            )
            let body = try output.ok.body.json
            guard let message = BobnetMessage(sendResponse: body) else {
                throw BobnetMalformedResponse()
            }
            return message
        }
    )
}

// MARK: - Test / preview implementation

extension BobnetClient: TestDependencyKey {
    /// Unimplemented by default so a test that reaches the network without
    /// stubbing it fails loudly.
    public static let testValue = BobnetClient(
        channels: unimplemented("BobnetClient.channels", placeholder: []),
        messages: unimplemented(
            "BobnetClient.messages",
            placeholder: BobnetPage(messages: [], nextCursor: nil)
        ),
        send: unimplemented("BobnetClient.send")
    )
}

extension DependencyValues {
    public var bobnetClient: BobnetClient {
        get { self[BobnetClient.self] }
        set { self[BobnetClient.self] = newValue }
    }
}

// MARK: - Mapping

extension BobnetMessage {
    /// Maps a relay-history item onto the local record. Returns nil without a
    /// numeric `id` (nothing to key/dedup on).
    init?(item: Components.Schemas.AppSchemasDevicesBobnetMessageItemSchema) {
        guard let id = item.id else { return nil }
        self.init(
            id: id,
            replicantName: item.replicantName ?? "",
            replicantCode: item.replicantCode ?? "",
            currentStar: item.currentStar,
            channel: item.channel ?? "",
            message: item.message ?? "",
            time: BobnetTimestamp.parse(item.time)
        )
    }

    /// Maps the send endpoint's echo of the created message onto the local
    /// record. Returns nil without a numeric `id`.
    init?(sendResponse body: Components.Schemas.AppSchemasReplicantsReplicantMessageResponseSchema) {
        guard let id = body.id else { return nil }
        self.init(
            id: id,
            replicantName: body.replicantName ?? "",
            replicantCode: body.replicantCode ?? "",
            currentStar: body.currentStar,
            channel: body.channel ?? "",
            message: body.message ?? "",
            time: BobnetTimestamp.parse(body.time)
        )
    }
}

/// ISO-8601 parsing shared by every Bobnet payload (with or without fractional
/// seconds), falling back to the Unix epoch so malformed rows still sort
/// predictably. Plain namespace — testable without SwiftUI.
enum BobnetTimestamp {
    static func parse(_ string: String?) -> Date {
        guard let string else { return Date(timeIntervalSince1970: 0) }
        if let date = try? Date(string, strategy: isoWithFraction) { return date }
        if let date = try? Date(string, strategy: isoPlain) { return date }
        return Date(timeIntervalSince1970: 0)
    }

    private static let isoWithFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let isoPlain = Date.ISO8601FormatStyle()
}
