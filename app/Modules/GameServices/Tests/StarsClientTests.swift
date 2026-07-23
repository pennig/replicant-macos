import API
import Dependencies
import Foundation
import GameSession
import HTTPTypes
import OpenAPIRuntime
import Testing
@testable import GameServices

@Suite struct StarsClientTests {

    /// A cancelled page request means the consumer tore the walk down (or the
    /// task was cancelled) — the stream must end cleanly, not surface the
    /// cancellation as a failure to whoever is still listening.
    @Test func surveyEndsCleanlyWhenTransportReportsCancellation() async throws {
        try await withDependencies {
            $0.gameClient = GameClient(make: {
                Client(
                    serverURL: URL(string: "https://stub.invalid")!,
                    transport: ThrowingTransport(makeError: { CancellationError() })
                )
            })
        } operation: {
            var pages = 0
            // Must complete without throwing; the generated client wraps the
            // transport's CancellationError in a ClientError.
            for try await _ in StarsClient.liveValue.survey("99380EDF", 100) {
                pages += 1
            }
            #expect(pages == 0)
        }
    }

    /// Non-cancellation transport failures still fail the stream loudly.
    @Test func surveyStillThrowsOnRealTransportErrors() async {
        struct BoomError: Error {}
        await withDependencies {
            $0.gameClient = GameClient(make: {
                Client(
                    serverURL: URL(string: "https://stub.invalid")!,
                    transport: ThrowingTransport(makeError: { BoomError() })
                )
            })
        } operation: {
            await #expect(throws: (any Error).self) {
                for try await _ in StarsClient.liveValue.survey("99380EDF", 100) {}
            }
        }
    }
}

/// A transport whose every send fails with the given error.
private struct ThrowingTransport: ClientTransport {
    let makeError: @Sendable () -> any Error
    func send(
        _ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        throw makeError()
    }
}
