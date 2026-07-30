//
//  LocationEventsClientTests.swift
//  Replicould — GameServices
//
//  Resolving a location event, driven through the generated client with a canned
//  transport. The success path is the one worth pinning: a 200 that the spec does
//  not describe is not "undocumented but harmless", it is a decode failure, and
//  the shape of the failure hides which side is at fault.
//

import API
import Dependencies
import Foundation
import GameDatabase
import GameSession
import HTTPTypes
import OpenAPIRuntime
import Testing
@testable import GameServices

@Suite("LocationEventsClient.complete")
struct LocationEventsClientTests {
    /// Serves one canned reply per path substring. Anything unmatched is a 404
    /// with an empty body, which fails loudly rather than looking like success.
    private struct CannedTransport: ClientTransport {
        let routes: [(match: String, status: Int, body: String)]

        func send(
            _ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String
        ) async throws -> (HTTPResponse, HTTPBody?) {
            let path = request.path ?? ""
            guard let route = routes.first(where: { path.contains($0.match) }) else {
                return (HTTPResponse(status: .init(code: 404)), HTTPBody("{}"))
            }
            return (
                HTTPResponse(
                    status: .init(code: route.status),
                    headerFields: [.contentType: "application/json"]
                ),
                HTTPBody(route.body)
            )
        }
    }

    private func client(_ routes: [(match: String, status: Int, body: String)]) -> GameClient {
        GameClient(make: {
            Client(serverURL: URL(string: "https://stub.invalid")!,
                   transport: CannedTransport(routes: routes))
        })
    }

    /// The authoritative re-read `complete` performs once the POST succeeds.
    private let emptyEventList = #"{"events":[],"next_cursor":null}"#

    /// The regression. The endpoint answers 200 with a resolution payload
    /// (`designation`, `event_status`, `rewards`, `status`, `title`), and until
    /// the spec described it that response was decoded against `DEFAULT_ERROR` —
    /// a STRICT schema knowing only `code`/`status`/`message`/`errors`. Four
    /// unknown keys, so the decoder threw and every successful completion
    /// surfaced to the player as a failed one.
    @Test func aResolvedEventIsSuccessRatherThanADecodeFailure() async throws {
        let database = try GameDatabase.bootstrap()
        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.gameClient = client([
                (match: "/events/", status: 200, body: #"""
                {"designation":"DERELICT_PROBE","event_status":"completed",
                 "rewards":{"credits":250},"status":"ok","title":"Derelict Probe"}
                """#),
                (match: "/accounts/events", status: 200, body: emptyEventList),
            ])
        } operation: {
            try await LocationEventsClient.liveValue.complete("SOL-3", "DERELICT_PROBE")
        }
    }

    /// A refusal still carries the server's own message through to the banner —
    /// the reason the `default` branch reads the body at all.
    @Test func aRefusalSurfacesTheServersMessage() async throws {
        let database = try GameDatabase.bootstrap()
        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.gameClient = client([
                (match: "/events/", status: 400,
                 body: #"{"code":400,"status":"Bad Request","message":"No replicant present."}"#),
                (match: "/accounts/events", status: 200, body: emptyEventList),
            ])
        } operation: {
            await #expect(throws: LocationEventError("No replicant present.")) {
                try await LocationEventsClient.liveValue.complete("SOL-3", "DERELICT_PROBE")
            }
        }
    }
}
