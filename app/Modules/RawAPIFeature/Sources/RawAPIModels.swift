//
//  RawAPIModels.swift
//  Replicant
//
//  Value models for the direct API access feature: the editable request, the
//  captured response, and the in-session history entry. Everything here is a
//  Sendable value type so it can live in `@Shared(.inMemory)` history and cross
//  actor boundaries without involving the reference-typed `HTTPURLResponse`.
//

import Foundation

/// The HTTP verbs offered by the request editor.
enum HTTPMethod: String, CaseIterable, Identifiable, Sendable, Equatable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case patch = "PATCH"
    case delete = "DELETE"

    var id: String { rawValue }

    /// Whether a request body is sent for this method. GET requests don't carry one.
    var allowsBody: Bool { self != .get }
}

/// One editable row in the query-parameter or header editors. Empty-named rows
/// are dropped when the request is built, so a trailing blank row is harmless.
struct KeyValuePair: Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String = ""
    var value: String = ""
}

/// The user-composed request. The `path` is resolved against the game's default
/// server base; the session's API key is injected as a bearer token at send time
/// (see `RawAPIClient`), so it is deliberately not modeled here.
struct RawRequest: Equatable, Sendable {
    var method: HTTPMethod = .get
    var path: String = ""
    var queryItems: [KeyValuePair] = []
    var body: String = ""
}

/// A fully value-typed snapshot of a response. We avoid storing `HTTPURLResponse`
/// directly (it's a non-Sendable reference type) and instead reconstruct one on
/// demand for the response pane via `asResponse`.
///
/// Public because it rides along in `RawAPIFeature.Action`, whose conformance is
/// public; its members are deliberately the public value types it captures.
public struct CapturedResponse: Equatable, Sendable {
    public var url: URL
    public var statusCode: Int
    public var headerFields: [String: String]
    public var data: Data
    public var duration: Duration

    public init(
        url: URL,
        statusCode: Int,
        headerFields: [String: String],
        data: Data,
        duration: Duration
    ) {
        self.url = url
        self.statusCode = statusCode
        self.headerFields = headerFields
        self.data = data
        self.duration = duration
    }

    /// Rebuild the response-pane model. The header fields are plain strings, so
    /// `HTTPURLResponse`'s initializer never actually fails here.
    var asResponse: Response {
        let http = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: headerFields
        )!
        return Response(response: http, data: data, duration: duration)
    }
}

/// A single entry in the session request history. Holds both the request that
/// produced it and the captured response, so re-selecting it can repopulate the
/// editor and re-display the saved response without re-issuing the call.
struct RequestHistoryItem: Equatable, Identifiable, Sendable {
    let id: UUID
    var request: RawRequest
    var response: CapturedResponse
    var date: Date

    var statusCode: Int { response.statusCode }
}
