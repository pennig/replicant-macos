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
