import Foundation
import HTTPTypes
import OpenAPIRuntime
import OSLog

/// Logs every request/response pair flowing through the generated client.
/// Bodies are buffered so they can be logged and then replayed downstream
/// (`HTTPBody` is single-pass). Keep this outermost in the middleware array:
/// each logical request logs as a single pair, and 429 retries are surfaced
/// separately by `RateLimitMiddleware` rather than reprinted here. A side
/// benefit is that the `Authorization` header is injected further in, so the
/// bearer token never reaches the log.
///
/// Body buffering is gated: a body is only collected into memory when debug
/// logging is actually being captured for this subsystem AND its length is known
/// to fit within `maxBodyBytes`. Otherwise the original `HTTPBody` is passed
/// through untouched and logged as a metadata placeholder — so a large payload
/// (e.g. the global achievements catalog) is neither held in memory nor able to
/// overflow the collect limit and surface as a spurious transport error.
public struct LoggingMiddleware: ClientMiddleware {

    private let logger: Logger
    /// Max body size to buffer for logging. Bodies whose known length exceeds it
    /// (or whose length is unknown) are passed through unbuffered and logged as a
    /// placeholder rather than collected into memory.
    private let maxBodyBytes: Int

    public init(
        subsystem: String = "name.pennig.replicould.api",
        category: String = "http",
        maxBodyBytes: Int = 4 * 1024 * 1024
    ) {
        self.logger = Logger(subsystem: subsystem, category: category)
        self.maxBodyBytes = maxBodyBytes
    }

    public func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        // Only pay the buffering cost when someone is actually capturing these
        // debug logs; otherwise the `logger.debug` lines are dropped anyway.
        let capturing = logger.isEnabled(type: .debug)

        let loggedRequestBody = capturing ? await bufferForLogging(body) : nil
        logger.debug("""
            → \(request.method.rawValue, privacy: .public) \
            \(baseURL.absoluteString, privacy: .public)\(request.path ?? "", privacy: .public) \
            [\(operationID, privacy: .public)]
            headers: \(redacted(request.headerFields), privacy: .public)
            body: \(describe(loggedRequestBody, orLengthOf: body), privacy: .public)
            """)

        do {
            let (response, responseBody) = try await next(
                request,
                loggedRequestBody.map { HTTPBody($0) } ?? body,
                baseURL
            )
            let loggedResponseBody = capturing ? await bufferForLogging(responseBody) : nil
            logger.debug("""
                ← \(response.status.code, privacy: .public) [\(operationID, privacy: .public)]
                headers: \(redacted(response.headerFields), privacy: .public)
                body: \(describe(loggedResponseBody, orLengthOf: responseBody), privacy: .public)
                """)
            return (response, loggedResponseBody.map { HTTPBody($0) } ?? responseBody)
        } catch {
            logger.error("✗ [\(operationID, privacy: .public)] transport error: \(error, privacy: .public)")
            throw error
        }
    }

    /// Collect a body into `Data` for logging — but only when it's safe to do so
    /// without consuming a body we then couldn't replay. We buffer only bodies
    /// whose length is *known* and within `maxBodyBytes`; anything larger (or of
    /// unknown length) returns nil so the caller passes the original body through
    /// untouched. This makes the collect below unable to overflow or partially
    /// consume the stream.
    private func bufferForLogging(_ body: HTTPBody?) async -> Data? {
        guard let body, case let .known(length) = body.length, length <= Int64(maxBodyBytes)
        else { return nil }
        return try? await Data(collecting: body, upTo: maxBodyBytes)
    }

    /// Render a body for the log: its decoded contents when we buffered it, else a
    /// placeholder noting why (absent / too large / unknown length).
    private func describe(_ data: Data?, orLengthOf body: HTTPBody?) -> String {
        if let data { return String(decoding: data, as: UTF8.self) }
        guard let body else { return "<none>" }
        switch body.length {
        case let .known(length): return "<\(length) bytes, not buffered>"
        case .unknown: return "<streamed, not buffered>"
        }
    }

    private func redacted(_ fields: HTTPFields) -> [String] {
        var fields = fields
        if fields[.authorization] != nil { fields[.authorization] = "Bearer <redacted>" }
        return fields.map({ "\($0.name): \($0.value)" })
    }
}
