import Foundation
import HTTPTypes
import Testing
@testable import API

@Suite struct RateLimitMiddlewareTests {

    /// The spec carries no operationIds, so the generator synthesizes
    /// "method/path" ids — this is the string the runtime hands to middleware.
    /// The stars special-case must match it, not the Swift method name.
    @Test func generatedStarsOperationIDIsPathStyle() {
        #expect(Operations.GetV1Stars.id == "get/v1/stars")
    }

    /// The full-catalogue endpoint's dedicated 1/min headers must land in the
    /// `stars` bucket — and must NOT clamp the shared `reads` budget (which
    /// would stall every subsequent GET behind the stars cooldown).
    @Test func starsCatalogueHeadersRecordIntoStarsBucketNotReads() async throws {
        let governor = RateLimitGovernor(readLimit: 10, actionLimit: 5, reserve: 2)
        let middleware = RateLimitMiddleware(governor: governor)
        let reset = Date().addingTimeInterval(60).timeIntervalSince1970

        let headers: HTTPFields = {
            var fields = HTTPFields()
            fields[HTTPField.Name("X-RateLimit-Limit")!] = "1"
            fields[HTTPField.Name("X-RateLimit-Remaining")!] = "0"
            fields[HTTPField.Name("X-RateLimit-Reset")!] = String(reset)
            return fields
        }()

        let request = HTTPRequest(method: .get, scheme: "https", authority: "api.test", path: "/v1/stars")
        _ = try await middleware.intercept(
            request,
            body: nil,
            baseURL: URL(string: "https://api.test")!,
            operationID: Operations.GetV1Stars.id,
            next: { _, _, _ in (HTTPResponse(status: .ok, headerFields: headers), nil) }
        )

        let stars = await governor.snapshot(.stars)
        #expect(stars.limit == 1)
        #expect(stars.remaining == 0)
        #expect(stars.resetAt != nil)

        let reads = await governor.snapshot(.reads)
        #expect(reads.limit == 10, "stars limit must not clamp the shared reads limit")
        #expect(reads.remaining == 10, "a catalogue call must not consume or zero the reads budget")
    }
}
