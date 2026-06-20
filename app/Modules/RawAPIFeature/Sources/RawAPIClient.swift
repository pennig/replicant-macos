//
//  RawAPIClient.swift
//  Replicant
//
//  The dependency that actually issues a raw request. It resolves the editor's
//  relative path against the game's default server, injects the session bearer
//  token, applies custom headers/body, times the round-trip, and returns a
//  value-typed `CapturedResponse`. Exposed via `@Dependency(\.rawAPIClient)`.
//

import ComposableArchitecture
import Foundation

enum RawAPIError: LocalizedError {
    case invalidURL
    case nonHTTPResponse

    var errorDescription: String? {
        switch self {
        case .invalidURL:     "The request URL is invalid."
        case .nonHTTPResponse: "The server returned a non-HTTP response."
        }
    }
}

struct RawAPIClient: Sendable {
    /// Send `request`, authenticating with `apiKey` as a bearer token.
    var send: @Sendable (_ request: RawRequest, _ apiKey: String) async throws -> CapturedResponse
}

extension RawAPIClient {
    /// The game's default API base. Mirrors `ReplicantSpace.defaultServerURL`;
    /// kept local so this feature doesn't pull in the generated OpenAPI client.
    static let baseURL = URL(string: "https://api.replicant.space/v1")!
}

// MARK: - Live implementation

extension RawAPIClient: DependencyKey {
    static let liveValue = RawAPIClient { request, apiKey in
        // Resolve the relative path against the base. A leading slash would make
        // `appending(path:)` treat it oddly, so normalize it off first.
        let trimmedPath = request.path.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmedPath.hasPrefix("/") ? String(trimmedPath.dropFirst()) : trimmedPath
        let resolved = normalized.isEmpty ? baseURL : baseURL.appending(path: normalized)

        guard var components = URLComponents(url: resolved, resolvingAgainstBaseURL: false) else {
            throw RawAPIError.invalidURL
        }
        let queryItems = request.queryItems
            .filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { URLQueryItem(name: $0.name, value: $0.value) }
        if !queryItems.isEmpty { components.queryItems = queryItems }

        guard let url = components.url else { throw RawAPIError.invalidURL }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        if request.method.allowsBody, !request.body.isEmpty {
            urlRequest.httpBody = Data(request.body.utf8)
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let clock = ContinuousClock()
        let start = clock.now
        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        let duration = clock.now - start

        guard let http = response as? HTTPURLResponse else { throw RawAPIError.nonHTTPResponse }

        var headerFields: [String: String] = [:]
        for (key, value) in http.allHeaderFields { headerFields["\(key)"] = "\(value)" }

        return CapturedResponse(
            url: http.url ?? url,
            statusCode: http.statusCode,
            headerFields: headerFields,
            data: data,
            duration: duration
        )
    }
}

// MARK: - Test / preview implementation

extension RawAPIClient: TestDependencyKey {
    /// Returns a representative device payload so previews and tests can exercise
    /// the send → history → response flow without hitting the network.
    static var testValue: RawAPIClient {
        RawAPIClient { _, _ in
            CapturedResponse(
                url: baseURL,
                statusCode: 200,
                headerFields: ["Content-Type": "application/json"],
                data: .mockDeviceJSON,
                duration: .milliseconds(342)
            )
        }
    }

    static let previewValue = testValue
}

extension DependencyValues {
    var rawAPIClient: RawAPIClient {
        get { self[RawAPIClient.self] }
        set { self[RawAPIClient.self] = newValue }
    }
}
