import Foundation
import OpenAPIRuntime
import OSLog

/// Precise logging for OpenAPI response-body decode failures — i.e. server/spec
/// drift (a field the spec forbids or mistypes). These surface as a
/// `ClientError` wrapping a `DecodingError` thrown from the generated operation,
/// *after* any `ClientMiddleware` has returned — so a middleware can log the raw
/// body (see `LoggingMiddleware`) but never the `DecodingError` itself. Call this
/// at the client boundary (before the error is `try?`-swallowed) to capture the
/// exact coding path + reason, ready to report to the backend.
///
/// Pair with the body already logged by `LoggingMiddleware` (same operation) for
/// a complete drift report: "operation X rejected key `foo`, here's the payload."
public enum DecodingDiagnostics {

    public static let logger = Logger(
        subsystem: "name.pennig.replicould.api", category: "decoding")

    /// Logs a drift report if `error` is (or wraps) a response-body decode
    /// failure; a no-op for transport/HTTP/other errors. Always rethrow after.
    public static func log(_ error: any Error, operationID: String) {
        guard let decodingError = Self.decodingError(in: error) else { return }
        let (path, reason) = Self.describe(decodingError)
        logger.error("""
            ⚠️ OpenAPI response decode failed (likely spec drift — report to backend):
            operation: \(operationID, privacy: .public)
            codingPath: \(path, privacy: .public)
            reason: \(reason, privacy: .public)
            (raw response body is in the http log for this operation)
            """)
    }

    /// Runs `work`, logging a drift report on a decode failure, then rethrowing.
    /// A thin wrapper so a call site reads `try await DecodingDiagnostics.capture("op") { … }`.
    public static func capture<T>(
        _ operationID: String, _ work: () async throws -> T
    ) async throws -> T {
        do {
            return try await work()
        } catch {
            log(error, operationID: operationID)
            throw error
        }
    }

    // MARK: - Extraction

    /// Unwraps a `DecodingError` out of the layers the runtime nests it in
    /// (`ClientError.underlyingError`, and its own `underlyingError` chain).
    static func decodingError(in error: any Error) -> DecodingError? {
        if let decoding = error as? DecodingError { return decoding }
        if let client = error as? ClientError { return decodingError(in: client.underlyingError) }
        let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? Error
        return underlying.flatMap(decodingError(in:))
    }

    static func describe(_ error: DecodingError) -> (path: String, reason: String) {
        let kind: String
        let context: DecodingError.Context?
        switch error {
        case let .keyNotFound(key, ctx): kind = "missing key '\(key.stringValue)'"; context = ctx
        case let .typeMismatch(type, ctx): kind = "type mismatch (expected \(type))"; context = ctx
        case let .valueNotFound(type, ctx): kind = "null for non-optional \(type)"; context = ctx
        case let .dataCorrupted(ctx): kind = "data corrupted"; context = ctx
        @unknown default: kind = "unknown decoding error"; context = nil
        }
        let path = (context?.codingPath ?? []).map(\.stringValue).joined(separator: ".")
        let detail = context?.debugDescription ?? ""
        return (path.isEmpty ? "<root>" : path, detail.isEmpty ? kind : "\(kind) — \(detail)")
    }
}
