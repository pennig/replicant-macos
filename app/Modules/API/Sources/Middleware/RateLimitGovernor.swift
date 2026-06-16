import Foundation

/// Tracks the game's two token-scoped rate-limit buckets and gates outgoing
/// requests so the client throttles itself *before* the server has to.
///
/// Replicant Space limits (per API token):
///   - reads  (GET):                       120 / minute
///   - actions (POST/DELETE/PATCH/...):     60 / minute
///
/// Every response carries `X-RateLimit-Limit`, `X-RateLimit-Remaining`, and
/// `X-RateLimit-Reset` (epoch seconds). The governor starts from optimistic
/// local defaults and converges on the server's view as responses arrive.
///
/// Being an actor matters here: many tasks can fire requests concurrently,
/// and `acquire` must atomically check-and-decrement the local budget.
public actor RateLimitGovernor {

    public enum Bucket: String, Sendable, CaseIterable {
        /// GET requests.
        case reads
        /// Everything else (POST, DELETE, PATCH, ...).
        case actions
    }

    /// A read-only view, e.g. for showing budget in a debug HUD.
    public struct Snapshot: Sendable {
        public let limit: Int
        public let remaining: Int
        public let resetAt: Date?
    }

    private struct State {
        var limit: Int
        var remaining: Int
        var resetAt: Date?
    }

    private var states: [Bucket: State]

    /// Requests are delayed once `remaining` drops to this floor, leaving a
    /// few tokens of headroom for anything else sharing the API token
    /// (a curl from the CLI, a script, an agent).
    private let reserve: Int

    public init(readLimit: Int = 120, actionLimit: Int = 60, reserve: Int = 3) {
        self.states = [
            .reads: State(limit: readLimit, remaining: readLimit, resetAt: nil),
            .actions: State(limit: actionLimit, remaining: actionLimit, resetAt: nil),
        ]
        self.reserve = max(0, reserve)
    }

    /// Suspends until the bucket has budget, then consumes one token.
    /// Optimistically decrements the local count; `record` reconciles with
    /// the server's headers when the response lands.
    public func acquire(_ bucket: Bucket) async {
        while true {
            var state = states[bucket]!
            let now = Date()

            // Window rolled over — refill the local budget.
            if let reset = state.resetAt, now >= reset {
                state.remaining = state.limit
                state.resetAt = nil
            }

            if state.remaining > reserve {
                state.remaining -= 1
                states[bucket] = state
                return
            }

            states[bucket] = state
            let wait = max(0.25, state.resetAt?.timeIntervalSinceNow ?? 1.0)
            // Jitter avoids a thundering herd of queued tasks at reset.
            try? await Task.sleep(for: .seconds(wait + Double.random(in: 0...0.25)))
        }
    }

    /// Reconcile with the server's `X-RateLimit-*` headers.
    /// `min` keeps this safe against out-of-order responses: a stale, higher
    /// remaining can never inflate the local budget.
    public func record(
        bucket: Bucket,
        limit: Int?,
        remaining: Int?,
        resetEpoch: TimeInterval?
    ) {
        var state = states[bucket]!
        if let limit { state.limit = limit }
        if let remaining { state.remaining = min(state.remaining, remaining) }
        if let resetEpoch { state.resetAt = Date(timeIntervalSince1970: resetEpoch) }
        states[bucket] = state
    }

    /// Called on a 429: zero the budget until `Retry-After` elapses, so every
    /// queued task backs off together instead of dog-piling the server.
    public func penalize(bucket: Bucket, retryAfter: TimeInterval) {
        var state = states[bucket]!
        state.remaining = 0
        state.resetAt = Date().addingTimeInterval(max(1, retryAfter))
        states[bucket] = state
    }

    public func snapshot(_ bucket: Bucket) -> Snapshot {
        let state = states[bucket]!
        return Snapshot(limit: state.limit, remaining: state.remaining, resetAt: state.resetAt)
    }
}
