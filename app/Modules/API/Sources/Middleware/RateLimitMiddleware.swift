import Foundation
import HTTPTypes
import OpenAPIRuntime
import OSLog

/// OpenAPI client middleware that:
///   1. Classifies each request into a rate-limit bucket (GET → reads,
///      everything else → actions) and awaits budget from the governor.
///   2. Feeds `X-RateLimit-*` response headers back into the governor.
///   3. On 429, honors `Retry-After`, penalizes the bucket (so concurrent
///      tasks back off too), and retries a bounded number of times.
public struct RateLimitMiddleware: ClientMiddleware {

    private let governor: RateLimitGovernor
    private let logger: Logger
    private let maxRetriesOn429: Int

    public init(
        governor: RateLimitGovernor,
        logger: Logger = Logger(subsystem: "space.replicant.api", category: "ratelimit"),
        maxRetriesOn429: Int = 3
    ) {
        self.governor = governor
        self.logger = logger
        self.maxRetriesOn429 = maxRetriesOn429
    }

    public func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        let bucket: RateLimitGovernor.Bucket = (request.method == .get) ? .reads : .actions

        // HTTPBody is a single-pass async sequence; buffer it so the request
        // can be replayed after a 429. Game payloads are tiny JSON bodies.
        var bodyData: Data?
        if let body {
            bodyData = try await Data(collecting: body, upTo: 4 * 1024 * 1024)
        }

        var attempt = 0
        while true {
            await governor.acquire(bucket)

            let (response, responseBody) = try await next(
                request,
                bodyData.map { HTTPBody($0) },
                baseURL
            )

            await governor.record(
                bucket: bucket,
                limit: response.headerFields.intValue(.xRateLimitLimit),
                remaining: response.headerFields.intValue(.xRateLimitRemaining),
                resetEpoch: response.headerFields.doubleValue(.xRateLimitReset)
            )

            guard response.status == .tooManyRequests, attempt < maxRetriesOn429 else {
                return (response, responseBody)
            }

            logger.debug("↻ Rate limited! Retrying... [\(operationID, privacy: .public)]")
            
            attempt += 1
            let retryAfter = response.headerFields.doubleValue(.retryAfter) ?? 5
            await governor.penalize(bucket: bucket, retryAfter: retryAfter)
            // The next `acquire` sleeps until the penalty window passes.
        }
    }
}

// MARK: - Header helpers

extension HTTPFields {
    fileprivate func intValue(_ name: HTTPField.Name) -> Int? {
        self[name].flatMap(Int.init)
    }

    fileprivate func doubleValue(_ name: HTTPField.Name) -> Double? {
        self[name].flatMap(Double.init)
    }
}

extension HTTPField.Name {
    fileprivate static let xRateLimitLimit = HTTPField.Name("X-RateLimit-Limit")!
    fileprivate static let xRateLimitRemaining = HTTPField.Name("X-RateLimit-Remaining")!
    fileprivate static let xRateLimitReset = HTTPField.Name("X-RateLimit-Reset")!
    fileprivate static let retryAfter = HTTPField.Name("Retry-After")!
}
