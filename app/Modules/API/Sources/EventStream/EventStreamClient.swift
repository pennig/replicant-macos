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
    /// The connection has been down longer than the server's cursor replay can
    /// be trusted to cover (e.g. the machine slept for hours). Reconnecting
    /// internally would make the server replay whatever it still retains as
    /// live `.stream` events with the rest silently lost — the owner must
    /// instead tear down and restart with the authoritative catch-up pull.
    case staleGap(idleSeconds: TimeInterval)
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
    ///   - staleAfter: reconnects are handled internally only while the quiet
    ///     gap stays inside this window (matching the pipeline's catch-up
    ///     freshness window); beyond it the stream finishes with `.staleGap`
    ///     so the owner restarts through the authoritative catch-up pull
    ///     instead of trusting cursor replay (sleep/wake lands here).
    public static func live(
        endpoint: URL = defaultEndpoint,
        token: @escaping @Sendable () -> String?,
        session: URLSession = .shared,
        staleAfter: TimeInterval = 15 * 60,
        logger: Logger? = nil
    ) -> EventStreamClient {
        let log = logger ?? Logger(subsystem: "name.pennig.replicould.events", category: "stream")
        return EventStreamClient { cursor in
            AsyncThrowingStream { continuation in
                let task = Task {
                    var lastEventID: String? = cursor
                    var retryDelay: Duration = .seconds(1)
                    // Exponential reconnect backoff: reset to `retryDelay` on a
                    // successful connect, doubled (with jitter, capped at 60s)
                    // per consecutive failure so a down/fast-closing server
                    // isn't hammered at 1 connect/sec indefinitely.
                    var reconnectDelay: Duration = .seconds(1)
                    var hasConnected = false
                    // Wall-clock of the last line received (data OR keepalive) —
                    // the staleness clock for the `.staleGap` check. Seeded at
                    // task start so a client that NEVER manages to receive a
                    // line (offline at launch/restart) still hands off after
                    // the window instead of eventually reconnecting from a
                    // stale cursor as if nothing happened.
                    var lastActivityAt = Date()
                    // Whether the current connection has delivered any line —
                    // gates the backoff reset (a 200 that closes without bytes
                    // is not a healthy connection) and the quick clean-close
                    // reconnect.
                    var receivedLineThisConnection = false

                    // One jittered, doubling backoff sleep (floor 500ms, cap 60s).
                    func sleepForBackoff() async {
                        let seconds = Double(reconnectDelay.components.seconds)
                            + Double(reconnectDelay.components.attoseconds) / 1e18
                        let jittered = Duration.seconds(seconds * Double.random(in: 0.8...1.2))
                        try? await Task.sleep(for: max(jittered, .milliseconds(500)))
                        reconnectDelay = min(reconnectDelay * 2, .seconds(60))
                    }

                    while !Task.isCancelled {
                        let idle = Date().timeIntervalSince(lastActivityAt)
                        if idle > staleAfter {
                            log.notice("event stream idle \(Int(idle))s — beyond cursor-replay trust; handing off for catch-up restart")
                            continuation.finish(throwing: EventStreamError.staleGap(idleSeconds: idle))
                            return
                        }
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
                            receivedLineThisConnection = false

                            // The wire protocol (line framing + field parsing)
                            // lives in `SSEWire.swift`, where it's unit-tested;
                            // this loop keeps only the connection-level side
                            // effects (liveness, backoff, cursor advancement).
                            var framer = SSELineFramer()
                            var parser = SSEFieldParser()
                            for try await byte in bytes {
                                guard !Task.isCancelled else { break }
                                hasConnected = true

                                guard let line = framer.consume(byte) else { continue }
                                lastActivityAt = Date()   // any line — keepalives count as liveness
                                if !receivedLineThisConnection {
                                    receivedLineThisConnection = true
                                    // Only a connection that actually delivers
                                    // counts as healthy: resetting on the bare
                                    // 200 would let an accept-then-close server
                                    // (drain, misconfigured proxy) be hammered
                                    // at the floor rate forever.
                                    reconnectDelay = retryDelay
                                }

                                switch parser.consume(line) {
                                case .none:
                                    break
                                case .event(let event):
                                    lastEventID = event.id
                                    continuation.yield(event)
                                case .retryHint(let ms):
                                    retryDelay = .milliseconds(ms)
                                case .comment(let text):
                                    log.debug("comment: \(text, privacy: .public)")
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
                            await sleepForBackoff()
                            continue
                        }

                        // Server closed the connection normally. After a
                        // productive connection, reconnect quickly (Last-Event-ID
                        // / cursor ensures no events are missed); a 200 that
                        // closed without delivering a single line rides the
                        // backoff like a failure, so an accept-then-close server
                        // can't induce a connect storm.
                        if !Task.isCancelled {
                            if receivedLineThisConnection {
                                try? await Task.sleep(for: .milliseconds(100))
                            } else {
                                await sleepForBackoff()
                            }
                        }
                    }
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    }
}
