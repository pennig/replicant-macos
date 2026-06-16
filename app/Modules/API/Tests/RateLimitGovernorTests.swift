import XCTest
@testable import ReplicantKit

final class RateLimitGovernorTests: XCTestCase {

    func testAcquireConsumesBudget() async {
        let governor = RateLimitGovernor(readLimit: 10, actionLimit: 5, reserve: 2)
        await governor.acquire(.reads)
        let snapshot = await governor.snapshot(.reads)
        XCTAssertEqual(snapshot.remaining, 9)
    }

    func testRecordNeverInflatesBudget() async {
        let governor = RateLimitGovernor(readLimit: 10, actionLimit: 5, reserve: 0)
        await governor.acquire(.reads) // local: 9
        // A stale response claiming more budget must not raise the local count.
        await governor.record(bucket: .reads, limit: 10, remaining: 10, resetEpoch: nil)
        let snapshot = await governor.snapshot(.reads)
        XCTAssertEqual(snapshot.remaining, 9)
        // A lower server count wins.
        await governor.record(bucket: .reads, limit: 10, remaining: 3, resetEpoch: nil)
        let after = await governor.snapshot(.reads)
        XCTAssertEqual(after.remaining, 3)
    }

    func testPenaltyDelaysAcquire() async {
        let governor = RateLimitGovernor(readLimit: 10, actionLimit: 5, reserve: 0)
        await governor.penalize(bucket: .actions, retryAfter: 1)

        let start = Date()
        await governor.acquire(.actions)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertGreaterThan(elapsed, 0.9, "acquire should wait out the penalty window")
    }

    func testBudgetRefillsAfterReset() async {
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
        XCTAssertGreaterThan(Date().timeIntervalSince(start), 0.3)
    }
}
