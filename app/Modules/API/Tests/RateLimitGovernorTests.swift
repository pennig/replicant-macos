import Foundation
import Testing
@testable import API

@Suite struct RateLimitGovernorTests {

    @Test func acquireConsumesBudget() async {
        let governor = RateLimitGovernor(readLimit: 10, actionLimit: 5, reserve: 2)
        await governor.acquire(.reads)
        let snapshot = await governor.snapshot(.reads)
        #expect(snapshot.remaining == 9)
    }

    @Test func recordNeverInflatesBudget() async {
        let governor = RateLimitGovernor(readLimit: 10, actionLimit: 5, reserve: 0)
        await governor.acquire(.reads) // local: 9
        // A stale response claiming more budget must not raise the local count.
        await governor.record(bucket: .reads, limit: 10, remaining: 10, resetEpoch: nil)
        let snapshot = await governor.snapshot(.reads)
        #expect(snapshot.remaining == 9)
        // A lower server count wins.
        await governor.record(bucket: .reads, limit: 10, remaining: 3, resetEpoch: nil)
        let after = await governor.snapshot(.reads)
        #expect(after.remaining == 3)
    }

    @Test func penaltyDelaysAcquire() async {
        let governor = RateLimitGovernor(readLimit: 10, actionLimit: 5, reserve: 0)
        await governor.penalize(bucket: .actions, retryAfter: 1)

        let start = Date()
        await governor.acquire(.actions)
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed > 0.9, "acquire should wait out the penalty window")
    }

    /// `rateLimitedAt` records a 429 AND NOTHING ELSE.
    ///
    /// It is the one fact behind the brain's why-view distinguishing "the
    /// server refused us" from "we paced ourselves", so the negative half is
    /// the point: draining the bucket ourselves (`acquire`) and being told by
    /// the server's own headers that it is drained (`record`, right down to
    /// `remaining: 0`) must both leave it nil. If either stamped it, the
    /// surface would report a rate limit that never happened.
    @Test func onlyA429StampsRateLimitedAt() async {
        let governor = RateLimitGovernor(readLimit: 10, actionLimit: 5, reserve: 0)

        await governor.acquire(.actions)
        await governor.record(bucket: .actions, limit: 5, remaining: 0, resetEpoch: nil)
        #expect(await governor.snapshot(.actions).rateLimitedAt == nil)

        let before = Date()
        await governor.penalize(bucket: .actions, retryAfter: 1)
        let stamped = await governor.snapshot(.actions).rateLimitedAt
        #expect(stamped != nil)
        #expect(stamped.map { $0 >= before && $0 <= Date() } == true)

        // Buckets are stamped independently — a 429 on actions says nothing
        // about reads.
        #expect(await governor.snapshot(.reads).rateLimitedAt == nil)
    }

    /// A shared bucket's denominator is PINNED to the limit it was configured
    /// with. The game meters several endpoints on their own budgets and reports
    /// every one of them on the same `X-RateLimit-*` headers, so a header that
    /// disagrees is a foreign limiter's reading, not news about this bucket.
    @Test func aForeignLimitHeaderIsRejectedWhole() async {
        let governor = RateLimitGovernor(readLimit: 120, actionLimit: 60, reserve: 0)
        await governor.acquire(.actions)

        // An hourly per-endpoint limiter (webhook changes, feedback) answering
        // on the shared headers.
        await governor.record(bucket: .actions, limit: 12, remaining: 11, resetEpoch: nil)

        let snapshot = await governor.snapshot(.actions)
        #expect(snapshot.limit == 60, "the denominator must stay pinned to the actions limit")
        #expect(snapshot.remaining == 59, "a foreign remaining must not ratchet this bucket down")
    }

    /// The exact shape the brain's why-view was reporting: the reads limit
    /// arriving on an actions response and rewriting the denominator, so the
    /// line read "116 of 120" for a bucket that only ever holds 60.
    @Test func theReadsLimitNeverBecomesTheActionsDenominator() async {
        let governor = RateLimitGovernor(readLimit: 120, actionLimit: 60, reserve: 0)
        await governor.record(bucket: .actions, limit: 120, remaining: 116, resetEpoch: nil)

        let snapshot = await governor.snapshot(.actions)
        #expect(snapshot.limit == 60)
        #expect(snapshot.remaining == 60)
    }

    /// `stars` is one endpoint's private budget, so nothing else can pollute it
    /// and the server's word is the only source it has. Validating it would
    /// silently break the survey button's cooldown if the server ever retuned.
    @Test func theStarsBucketTakesTheServersWord() async {
        let governor = RateLimitGovernor(readLimit: 120, actionLimit: 60, reserve: 0)
        let reset = Date().addingTimeInterval(45)
        await governor.record(bucket: .stars, limit: 2, remaining: 0, resetEpoch: reset.timeIntervalSince1970)

        let snapshot = await governor.snapshot(.stars)
        #expect(snapshot.limit == 2)
        #expect(snapshot.resetAt != nil)
    }

    /// The server refilling its window must be believed. `min` alone cannot see
    /// a refill, so a bucket drained late in one window stayed drained through
    /// the whole of the next — throttling us locally against budget the server
    /// had already handed back.
    @Test func aNewWindowAdoptsTheServersRefill() async {
        let governor = RateLimitGovernor(readLimit: 120, actionLimit: 60, reserve: 3)
        let firstReset = Date().addingTimeInterval(30)
        await governor.record(
            bucket: .reads, limit: 120, remaining: 3, resetEpoch: firstReset.timeIntervalSince1970
        )

        // A later reset epoch is the server saying "different window".
        await governor.record(
            bucket: .reads,
            limit: 120,
            remaining: 119,
            resetEpoch: firstReset.addingTimeInterval(60).timeIntervalSince1970
        )

        #expect(await governor.snapshot(.reads).remaining == 119)
    }

    /// The other half of that rule: inside ONE window the server's count may
    /// only ever lower ours. Without this the refill fix would re-open the
    /// out-of-order-response hole `min` exists to close.
    @Test func withinOneWindowTheServerCanOnlyLowerTheCount() async {
        let governor = RateLimitGovernor(readLimit: 120, actionLimit: 60, reserve: 0)
        let reset = Date().addingTimeInterval(30).timeIntervalSince1970
        await governor.record(bucket: .reads, limit: 120, remaining: 10, resetEpoch: reset)
        await governor.record(bucket: .reads, limit: 120, remaining: 90, resetEpoch: reset)

        #expect(await governor.snapshot(.reads).remaining == 10)
    }

    /// The behaviour all of the above is for: a walk that would have parked at
    /// the reserve floor for a full minute proceeds immediately once the server
    /// says the window rolled.
    @Test func aRolledWindowUnblocksAcquireWithoutWaiting() async {
        let governor = RateLimitGovernor(readLimit: 120, actionLimit: 60, reserve: 3)
        let firstReset = Date().addingTimeInterval(30)
        await governor.record(
            bucket: .reads, limit: 120, remaining: 0, resetEpoch: firstReset.timeIntervalSince1970
        )
        await governor.record(
            bucket: .reads,
            limit: 120,
            remaining: 120,
            resetEpoch: firstReset.addingTimeInterval(60).timeIntervalSince1970
        )

        let start = Date()
        await governor.acquire(.reads)
        #expect(Date().timeIntervalSince(start) < 0.2, "a refilled bucket must not sleep")
    }

    @Test func budgetRefillsAfterReset() async {
        let governor = RateLimitGovernor(readLimit: 2, actionLimit: 2, reserve: 0)
        // Drain, with a reset window slightly in the future.
        await governor.acquire(.reads)
        await governor.acquire(.reads)
        await governor.record(
            bucket: .reads,
            limit: 2,
            remaining: 0,
            resetEpoch: Date().addingTimeInterval(0.5).timeIntervalSince1970
        )
        // This acquire must block until the window rolls, then succeed.
        let start = Date()
        await governor.acquire(.reads)
        #expect(Date().timeIntervalSince(start) > 0.3)
    }
}
