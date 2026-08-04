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
        /// The full star catalogue (`GET /v1/stars`), which the server meters on
        /// its own tight budget (≈1 request/minute) reported on the same
        /// `X-RateLimit-*` headers. Kept apart so its `limit: 1 / remaining: 0`
        /// never clamps the shared `reads` budget. Not gated by `acquire`; the
        /// feature reads its `resetAt` to gate the survey button instead.
        case stars
    }

    /// A read-only view, e.g. for showing budget in a debug HUD.
    public struct Snapshot: Sendable, Equatable {
        public let limit: Int
        public let remaining: Int
        public let resetAt: Date?
        /// When the SERVER last answered 429 for this bucket, or nil if it
        /// never has this session.
        ///
        /// Deliberately a separate fact from `remaining`/`resetAt`, not
        /// something to be inferred from them. `penalize` zeroes `remaining`
        /// and sets `resetAt`, so a reader could *guess* a 429 from that
        /// shape — but so can an ordinary window that the server's own
        /// headers reported as spent (`record`), and self-throttling
        /// (`acquire` refusing to spend below `reserve`) looks similar
        /// again. Being rate-limited BY the server and pacing ourselves are
        /// different operational facts with different fixes, and the one
        /// that matters is the one an inference would hide.
        public let rateLimitedAt: Date?

        public init(limit: Int, remaining: Int, resetAt: Date?, rateLimitedAt: Date? = nil) {
            self.limit = limit
            self.remaining = remaining
            self.resetAt = resetAt
            self.rateLimitedAt = rateLimitedAt
        }
    }

    private struct State {
        var limit: Int
        var remaining: Int
        var resetAt: Date?
        /// Set only by `penalize` — i.e. only by a real 429.
        var rateLimitedAt: Date?
    }

    private var states: [Bucket: State]

    /// Requests are delayed once `remaining` drops to this floor, leaving a
    /// few tokens of headroom for anything else sharing the API token
    /// (a curl from the CLI, a script, an agent).
    private let reserve: Int

    public init(readLimit: Int = 120, actionLimit: Int = 60, reserve: Int = 3) {
        self.states = [
            .reads: State(limit: readLimit, remaining: readLimit, resetAt: nil, rateLimitedAt: nil),
            .actions: State(limit: actionLimit, remaining: actionLimit, resetAt: nil, rateLimitedAt: nil),
            // Only ever reconciled from response headers / read for its reset; the
            // optimistic defaults are never consulted since `stars` isn't gated.
            .stars: State(limit: 1, remaining: 1, resetAt: nil, rateLimitedAt: nil),
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
        // The one place a 429 is recorded as a 429. Everything else that
        // lowers `remaining` is either our own spending or the server's
        // header telling us what it has already counted.
        state.rateLimitedAt = Date()
        states[bucket] = state
    }

    public func snapshot(_ bucket: Bucket) -> Snapshot {
        let state = states[bucket]!
        return Snapshot(
            limit: state.limit,
            remaining: state.remaining,
            resetAt: state.resetAt,
            rateLimitedAt: state.rateLimitedAt
        )
    }
}
