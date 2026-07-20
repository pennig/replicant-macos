//
//  EventStreamClient.swift
//  Replicould — API (event stream)
//
//  Client for the game's native SSE endpoint, `GET /v1/events/stream`. Replaces
//  the custom Rust relay (`RelayClient`): the game now pushes events directly, so
//  there is no separate backend to authenticate against — the stream uses the
//  ordinary session bearer token, sourced fresh per (re)connect via an injected
//  provider (mirroring how `GameClient` reads the Keychain on every call).
//
//  Like `RawAPIClient`, this deliberately owns its own `URLSession` and bypasses
//  the generated client's middleware: a long-lived `text/event-stream` response
//  can't be buffered/rate-limited the way a normal request is.
//

import Foundation
import OSLog

/// One raw Server-Sent Event off the stream, before envelope decoding.
public struct StreamedEvent: Sendable, Identifiable {
    /// The SSE `id:` field — a Redis stream ID; doubles as the resume cursor.
    public let id: String
    /// The SSE `event:` field — the dotted event name, e.g. `mining.started`.
    public let eventName: String
    /// The SSE `data:` field bytes — decode to `GameEventEnvelope`.
    public let raw: Data

    public init(id: String, eventName: String, raw: Data) {
        self.id = id
        self.eventName = eventName
        self.raw = raw
    }
}

public enum EventStreamError: Error {
    case badStatus(Int)
    case malformedResponse
}

/// A long-lived stream of raw game events over SSE. Injectable so `GameSync` can
/// build the live version (Keychain token) and tests can substitute a canned one.
public struct EventStreamClient: Sendable {
    /// Open the stream, resuming after `cursor` (nil = start from the live tip).
    /// Auto-reconnects on transient failures; finishes on a permanent auth error.
    public var stream: @Sendable (_ cursor: String?) -> AsyncThrowingStream<StreamedEvent, Error>

    public init(stream: @escaping @Sendable (_ cursor: String?) -> AsyncThrowingStream<StreamedEvent, Error>) {
        self.stream = stream
    }
}

extension EventStreamClient {
    /// The live game SSE endpoint. Mirrors `ReplicantSpace.defaultServerURL`.
    public static let defaultEndpoint = URL(string: "https://api.replicant.space/v1/events/stream")!

    /// Build a live client.
    ///
    /// - Parameters:
    ///   - endpoint: the SSE URL (defaults to the live game endpoint).
    ///   - token: reads the current session bearer token; called on every
    ///     (re)connect so login/logout is tracked without reconfiguration.
    public static func live(
        endpoint: URL = defaultEndpoint,
        token: @escaping @Sendable () -> String?,
        session: URLSession = .shared,
        logger: Logger? = nil
    ) -> EventStreamClient {
        let log = logger ?? Logger(subsystem: "name.pennig.replicould.events", category: "stream")
        return EventStreamClient { cursor in
            AsyncThrowingStream { continuation in
                let task = Task {
                    var lastEventID: String? = cursor
                    var retryDelay: Duration = .seconds(1)
                    var hasConnected = false

                    while !Task.isCancelled {
                        do {
                            var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
                            if let id = lastEventID {
                                components.queryItems = [URLQueryItem(name: "cursor", value: id)]
                            }
                            var request = URLRequest(url: components.url!)
                            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                            request.setValue("Bearer \(token() ?? "")", forHTTPHeaderField: "Authorization")
                            if let id = lastEventID {
                                request.setValue(id, forHTTPHeaderField: "Last-Event-ID")
                            }

                            log.info("\(hasConnected ? "Reconnecting" : "Connecting") to event stream (SSE)…")

                            let (bytes, response) = try await session.bytes(for: request)
                            guard let http = response as? HTTPURLResponse else {
                                throw EventStreamError.malformedResponse
                            }
                            guard http.statusCode == 200 else {
                                throw EventStreamError.badStatus(http.statusCode)
                            }

                            var pendingID: String?
                            var pendingEvent: String?
                            var dataLines: [String] = []

                            for try await line in bytes.lines {
                                guard !Task.isCancelled else { break }
                                hasConnected = true

                                if line.isEmpty {
                                    // Blank line = dispatch the accumulated event.
                                    if let id = pendingID, !dataLines.isEmpty {
                                        let dataStr = dataLines.joined(separator: "\n")
                                        if let data = dataStr.data(using: .utf8) {
                                            lastEventID = id
                                            continuation.yield(
                                                StreamedEvent(id: id, eventName: pendingEvent ?? "", raw: data)
                                            )
                                        }
                                    }
                                    pendingID = nil
                                    pendingEvent = nil
                                    dataLines.removeAll(keepingCapacity: true)
                                } else if line.hasPrefix("id:") {
                                    pendingID = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                                } else if line.hasPrefix("event:") {
                                    pendingEvent = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                                } else if line.hasPrefix("data:") {
                                    // SSE permits multiple `data:` lines per event; join them.
                                    dataLines.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
                                } else if line.hasPrefix("retry:") {
                                    if let ms = Int(line.dropFirst(6).trimmingCharacters(in: .whitespaces)) {
                                        retryDelay = .milliseconds(ms)
                                    }
                                } else if line.hasPrefix(":") && !line.hasPrefix(":keepalive") {
                                    // Comment - do NOT reset the pending event.
                                    log.debug("comment: \(line.dropFirst(1), privacy: .public)")
                                }
                            }
                        } catch is CancellationError {
                            break
                        } catch {
                            guard !Task.isCancelled else { break }
                            // A bad/expired session token fails permanently — reconnecting
                            // can't fix it, so finish the stream (the app keeps working over
                            // REST until the next login refreshes the token). Everything else
                            // is transient (network blip, server restart): back off and retry.
                            if case EventStreamError.badStatus(let code) = error, code == 401 || code == 403 {
                                log.error("event stream auth failed (\(code)) — stopping")
                                continuation.finish(throwing: error)
                                return
                            }
                            try? await Task.sleep(for: retryDelay)
                            continue
                        }

                        // Server closed the connection normally. Reconnect quickly;
                        // Last-Event-ID / cursor ensures no events are missed.
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
}
