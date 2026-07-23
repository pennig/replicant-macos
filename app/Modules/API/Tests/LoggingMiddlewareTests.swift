import Foundation
import HTTPTypes
import Testing
@testable import API

@Suite struct LoggingMiddlewareTests {

    /// Downgrading cancellation logging must not change error propagation: a
    /// cancelled request still rethrows so callers can end their streams.
    @Test func cancellationStillRethrows() async {
        let middleware = LoggingMiddleware()
        let request = HTTPRequest(method: .get, scheme: "https", authority: "api.test", path: "/v1/stars")

        await #expect(throws: CancellationError.self) {
            _ = try await middleware.intercept(
                request,
                body: nil,
                baseURL: URL(string: "https://api.test")!,
                operationID: "get/v1/stars",
                next: { _, _, _ in throw CancellationError() }
            )
        }
    }
}
