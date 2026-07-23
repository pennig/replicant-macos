import Foundation
import OpenAPIRuntime

/// Classifies errors thrown by the transport stack that mean "the caller tore
/// this request down" rather than "the request failed": a raw
/// `CancellationError` (structured-concurrency cancellation), `URLError.cancelled`
/// (URLSession's spelling of the same), or either wrapped in the generated
/// client's `ClientError`. Consumers use this to end streams cleanly and to log
/// cancellations quietly instead of surfacing them as transport failures.
public enum TransportCancellation {
    public static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        if let clientError = error as? ClientError {
            return isCancellation(clientError.underlyingError)
        }
        return false
    }
}
