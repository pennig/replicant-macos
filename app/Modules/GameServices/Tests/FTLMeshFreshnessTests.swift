//
//  FTLMeshFreshnessTests.swift
//  Replicould — GameServices
//
//  The `.ftlMesh` domain's own freshness policy. Its appear-path TTL has to
//  outlast the sweep it can trigger, or revisiting the Stars view queues one
//  full per-relay read after another.
//

import ComposableArchitecture
import Foundation
import Testing
@testable import GameServices

@Suite struct FTLMeshFreshnessTests {

    /// A sweep reads every relay serially against a rate-limited budget, so the
    /// TTL must comfortably exceed one sweep's own duration.
    private static let sweepDuration: TimeInterval = 600

    private func engine(
        now: LockIsolated<Date>,
        refreshes: LockIsolated<Int>,
        _ body: @Sendable (DomainFreshnessEngine) async -> Void
    ) async {
        await withDependencies {
            $0.continuousClock = TestClock()
            $0.date = .init { now.value }
            $0.ftlMeshRefresher = FTLMeshRefresher(refresh: { refreshes.withValue { $0 += 1 } })
        } operation: {
            let engine = DomainFreshnessEngine()
            engine.register(.ftlMesh, FTLMeshRefresher.domainRegistration)
            await body(engine)
        }
    }

    @Test func revisitingThePaneWithinTheTTLDoesNotSweepAgain() async {
        let now = LockIsolated(Date(timeIntervalSince1970: 1_000))
        let refreshes = LockIsolated(0)

        await engine(now: now, refreshes: refreshes) { engine in
            await engine.refreshIfStale(.ftlMesh)
            #expect(refreshes.value == 1)

            now.withValue { $0 = $0.addingTimeInterval(Self.sweepDuration) }
            await engine.refreshIfStale(.ftlMesh)
            #expect(refreshes.value == 1)
        }
    }

    /// The TTL is a throttle, not an off switch — the appear path still repairs
    /// a mesh the event route missed, just not on every visit.
    @Test func revisitingLongAfterTheTTLSweepsAgain() async {
        let now = LockIsolated(Date(timeIntervalSince1970: 1_000))
        let refreshes = LockIsolated(0)

        await engine(now: now, refreshes: refreshes) { engine in
            await engine.refreshIfStale(.ftlMesh)
            now.withValue { $0 = $0.addingTimeInterval(24 * 60 * 60) }
            await engine.refreshIfStale(.ftlMesh)
            #expect(refreshes.value == 2)
        }
    }

    /// A relay event still refreshes immediately: `invalidate` marks the domain
    /// stale, which outranks the TTL.
    @Test func aRelayEventRefreshesRegardlessOfTheTTL() async {
        let now = LockIsolated(Date(timeIntervalSince1970: 1_000))
        let refreshes = LockIsolated(0)

        await engine(now: now, refreshes: refreshes) { engine in
            await engine.refreshIfStale(.ftlMesh)
            #expect(refreshes.value == 1)

            engine.invalidate(.ftlMesh)
            await engine.refreshIfStale(.ftlMesh)
            #expect(refreshes.value == 2)
        }
    }
}
