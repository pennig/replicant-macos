import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing
@testable import API

@Suite struct TransportCancellationTests {

    private struct SomeOtherError: Error {}

    @Test func bareCancellationErrorMatches() {
        #expect(TransportCancellation.isCancellation(CancellationError()))
    }

    @Test func cancelledURLErrorMatches() {
        #expect(TransportCancellation.isCancellation(URLError(.cancelled)))
    }

    @Test func otherURLErrorsDoNotMatch() {
        #expect(!TransportCancellation.isCancellation(URLError(.timedOut)))
    }

    /// The shape the generated client actually throws: the transport's
    /// `CancellationError` wrapped in a `ClientError`.
    @Test func clientErrorWrappingCancellationMatches() {
        let wrapped = ClientError(
            operationID: Operations.GetV1ReplicantsReplicantCodeStars.id,
            operationInput: "input",
            causeDescription: "Transport threw an error.",
            underlyingError: CancellationError()
        )
        #expect(TransportCancellation.isCancellation(wrapped))
    }

    @Test func clientErrorWrappingOtherErrorsDoesNotMatch() {
        let wrapped = ClientError(
            operationID: Operations.GetV1Stars.id,
            operationInput: "input",
            causeDescription: "Transport threw an error.",
            underlyingError: SomeOtherError()
        )
        #expect(!TransportCancellation.isCancellation(wrapped))
        #expect(!TransportCancellation.isCancellation(SomeOtherError()))
    }
}
