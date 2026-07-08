import Foundation
import OpenAPIRuntime
import OpenAPIURLSession

/// Entry point for the generated game client.
///
/// `Client` below is generated at build time by swift-openapi-generator from
/// `openapi.{yaml,json}` in this target — run `scripts/fetch-spec.sh` once
/// before the first build. Operation method names come from the spec's
/// operationIds, so explore them via autocomplete on the returned client.
public enum ReplicantSpace {

    public static let defaultServerURL = URL(string: "https://api.replicant.space/")!

    /// A fully wired game API client: bearer auth + self-throttling.
    ///
    /// Share one `RateLimitGovernor` across every client you create for the
    /// same API token — the limits are token-scoped, not client-scoped. The
    /// default parameter creates a fresh governor, which is correct for the
    /// common case of a single client in the app.
    /// Returns `any APIProtocol` (not the concrete `Client`) so it can be wrapped
    /// in `DiagnosticAPIClient` — every operation is routed through decode-error
    /// diagnostics from one place, transparently to call sites.
    public static func client(
        apiKey: String,
        serverURL: URL = defaultServerURL,
        governor: RateLimitGovernor = RateLimitGovernor()
    ) -> any APIProtocol {
        DiagnosticAPIClient(wrapped: Client(
            serverURL: serverURL,
            transport: URLSessionTransport(),
            middlewares: [
                LoggingMiddleware(),
                BearerAuthMiddleware(token: apiKey),
                RateLimitMiddleware(governor: governor),
            ]
        ))
    }
}
