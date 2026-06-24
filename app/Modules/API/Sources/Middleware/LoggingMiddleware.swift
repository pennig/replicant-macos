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
public struct LoggingMiddleware: ClientMiddleware {

    private let logger: Logger
    /// Max body size to buffer for logging. A body larger than this causes
    /// `Data(collecting:upTo:)` to throw, which is caught and logged as a
    /// transport error before being rethrown — so keep this comfortably above
    /// the largest expected payload (game bodies are tiny JSON).
    private let maxBodyBytes: Int

    public init(
        logger: Logger = Logger(subsystem: "name.pennig.replicould.api", category: "http"),
        maxBodyBytes: Int = 64 * 1024
    ) {
        self.logger = logger
        self.maxBodyBytes = maxBodyBytes
    }

    public func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        let requestBody = try await buffer(body)
        logger.debug("""
            → \(request.method.rawValue, privacy: .public) \
            \(baseURL.absoluteString, privacy: .public)\(request.path ?? "", privacy: .public) \
            [\(operationID, privacy: .public)]
            headers: \(redacted(request.headerFields), privacy: .public)
            body: \(describe(requestBody), privacy: .public)
            """)

        do {
            let (response, responseBody) = try await next(
                request,
                requestBody.map { HTTPBody($0) } ?? body,
                baseURL
            )
            let buffered = try await buffer(responseBody)
            logger.debug("""
                ← \(response.status.code, privacy: .public) [\(operationID, privacy: .public)]
                headers: \(redacted(response.headerFields), privacy: .public)
                body: \(describe(buffered), privacy: .public)
                """)
            return (response, buffered.map { HTTPBody($0) } ?? responseBody)
        } catch {
            logger.error("✗ [\(operationID, privacy: .public)] transport error: \(error, privacy: .public)")
            throw error
        }
    }

    private func buffer(_ body: HTTPBody?) async throws -> Data? {
        guard let body else { return nil }
        return try await Data(collecting: body, upTo: maxBodyBytes)
    }

    private func describe(_ data: Data?) -> String {
        guard let data else { return "<none>" }
        return String(decoding: data, as: UTF8.self)
    }

    private func redacted(_ fields: HTTPFields) -> [String] {
        var fields = fields
        if fields[.authorization] != nil { fields[.authorization] = "Bearer <redacted>" }
        return fields.map({ "\($0.name): \($0.value)" })
    }
}

