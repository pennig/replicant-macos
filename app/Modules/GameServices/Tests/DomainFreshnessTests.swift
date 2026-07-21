//
//  DomainFreshnessTests.swift
//  Replicould — GameServices
//
//  The per-domain freshness engine (V3.5): an event burst's invalidates
//  collapse through the trailing debounce into one refresh; `refreshIfStale`
//  refreshes only when marked stale or past the TTL; `reset` (logout) cancels
//  pending work and forgets the stamps.
//

import ComposableArchitecture
import Foundation
import Testing
@testable import GameServices

@Suite struct DomainFreshnessTests {

    /// A burst of invalidates runs exactly one refresh, after the debounce
    /// window closes — not one per event.
    @Test func burstCollapsesToOneRefresh() async throws {
        let clock = TestClock()
        let refreshes = LockIsolated(0)

        await withDependencies {
            $0.continuousClock = clock
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
        } operation: {
            let engine = DomainFreshnessEngine()
            engine.register(.inbox, DomainRegistration(debounce: .seconds(2), refresh: {
                refreshes.withValue { $0 += 1 }; return true
            }))

            for _ in 0..<5 { engine.invalidate(.inbox) }
            #expect(refreshes.value == 0)   // nothing runs on the invalidate path

            await clock.advance(by: .seconds(2))
            await Task.megaYield()
            #expect(refreshes.value == 1)
        }
    }

    /// Each invalidate re-arms the window: the refresh fires only once the
    /// events quiet, measured from the *last* invalidate.
    @Test func invalidateReArmsTheTrailingWindow() async throws {
        let clock = TestClock()
        let refreshes = LockIsolated(0)

        await withDependencies {
            $0.continuousClock = clock
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
        } operation: {
            let engine = DomainFreshnessEngine()
            engine.register(.inbox, DomainRegistration(debounce: .seconds(2), refresh: {
                refreshes.withValue { $0 += 1 }; return true
            }))

            engine.invalidate(.inbox)
            await clock.advance(by: .seconds(1))
            engine.invalidate(.inbox)   // re-arms
            await clock.advance(by: .seconds(1))
            await Task.megaYield()
            #expect(refreshes.value == 0)   // first window was superseded

            await clock.advance(by: .seconds(1))
            await Task.megaYield()
            #expect(refreshes.value == 1)
        }
    }

    /// `refreshIfStale` refreshes when the domain has never refreshed, skips
    /// within the TTL, and refreshes again once the TTL expires.
    @Test func refreshIfStaleHonorsTTL() async throws {
        let clock = TestClock()
        let refreshes = LockIsolated(0)
        let now = LockIsolated(Date(timeIntervalSince1970: 1_000))

        await withDependencies {
            $0.continuousClock = clock
            $0.date = DateGenerator { now.value }
        } operation: {
            let engine = DomainFreshnessEngine()
            engine.register(.inbox, DomainRegistration(ttl: 30, refresh: {
                refreshes.withValue { $0 += 1 }; return true
            }))

            await engine.refreshIfStale(.inbox)   // never refreshed → runs
            #expect(refreshes.value == 1)

            now.setValue(Date(timeIntervalSince1970: 1_010))
            await engine.refreshIfStale(.inbox)   // 10s < 30s TTL → skipped
            #expect(refreshes.value == 1)

            now.setValue(Date(timeIntervalSince1970: 1_031))
            await engine.refreshIfStale(.inbox)   // TTL expired → runs
            #expect(refreshes.value == 2)
        }
    }

    /// A stale mark makes `refreshIfStale` refresh immediately (no debounce
    /// wait), and the superseded pending debounce is cancelled — one read, not
    /// two.
    @Test func refreshIfStaleRunsImmediatelyWhenMarkedAndAbsorbsTheDebounce() async throws {
        let clock = TestClock()
        let refreshes = LockIsolated(0)
        let now = LockIsolated(Date(timeIntervalSince1970: 1_000))

        await withDependencies {
            $0.continuousClock = clock
            $0.date = DateGenerator { now.value }
        } operation: {
            let engine = DomainFreshnessEngine()
            engine.register(.inbox, DomainRegistration(debounce: .seconds(2), ttl: 30, refresh: {
                refreshes.withValue { $0 += 1 }; return true
            }))

            // Seed a fresh stamp so only the stale mark can explain a refresh.
            await engine.refreshIfStale(.inbox)
            #expect(refreshes.value == 1)

            engine.invalidate(.inbox)             // mark + arm debounce
            await engine.refreshIfStale(.inbox)   // within TTL, but marked → runs
            #expect(refreshes.value == 2)

            await clock.advance(by: .seconds(2))  // the armed debounce was absorbed
            await Task.megaYield()
            #expect(refreshes.value == 2)
        }
    }

    /// `reset` cancels an armed debounce (logout: nothing may fire into wiped
    /// tables) and forgets `lastRefreshedAt` (the next session's first
    /// `refreshIfStale` must re-read).
    @Test func resetCancelsPendingAndForgetsStamps() async throws {
        let clock = TestClock()
        let refreshes = LockIsolated(0)
        let now = LockIsolated(Date(timeIntervalSince1970: 1_000))

        await withDependencies {
            $0.continuousClock = clock
            $0.date = DateGenerator { now.value }
        } operation: {
            let engine = DomainFreshnessEngine()
            engine.register(.inbox, DomainRegistration(debounce: .seconds(2), ttl: 30, refresh: {
                refreshes.withValue { $0 += 1 }; return true
            }))

            engine.invalidate(.inbox)
            engine.reset()
            await clock.advance(by: .seconds(2))
            await Task.megaYield()
            #expect(refreshes.value == 0)   // armed debounce was cancelled

            await engine.refreshIfStale(.inbox)   // stamps forgotten → re-reads
            #expect(refreshes.value == 1)
        }
    }

    /// An invalidate landing *while a refresh runs* is not silently dropped:
    /// its debounced pass joins the running refresh (which read state from
    /// before the invalidate), and completion re-arms a trailing pass so the
    /// tail of a long burst still gets read.
    @Test func invalidateDuringRunningRefreshEarnsFollowUpPass() async throws {
        let clock = TestClock()
        let refreshes = LockIsolated(0)
        let started = AsyncStream.makeStream(of: Void.self)
        let gate = LockIsolated<CheckedContinuation<Void, Never>?>(nil)

        await withDependencies {
            $0.continuousClock = clock
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
        } operation: {
            let engine = DomainFreshnessEngine()
            engine.register(.ftlMesh, DomainRegistration(debounce: .seconds(2), refresh: {
                let n = refreshes.withValue { $0 += 1; return $0 }
                if n == 1 {
                    // The long first rebuild: block until the test releases it.
                    started.continuation.yield(())
                    await withCheckedContinuation { gate.setValue($0) }
                }
                return true
            }))

            engine.invalidate(.ftlMesh)
            await clock.advance(by: .seconds(2))

            // Wait until the first refresh is genuinely executing.
            var iterator = started.stream.makeAsyncIterator()
            _ = await iterator.next()

            engine.invalidate(.ftlMesh)   // lands mid-refresh
            await clock.advance(by: .seconds(2))
            await Task.megaYield()
            #expect(refreshes.value == 1)   // its pass joined the running one

            // Release the long refresh: completion must re-arm a trailing pass.
            while gate.value == nil { await Task.yield() }
            gate.value?.resume()
            await Task.megaYield()
            await clock.advance(by: .seconds(2))
            await Task.megaYield()
            #expect(refreshes.value == 2)
        }
    }

    /// A refresh that reports failure must not stamp the domain fresh — the
    /// next `refreshIfStale` re-reads instead of trusting the TTL.
    @Test func failedRefreshLeavesDomainStale() async throws {
        let clock = TestClock()
        let refreshes = LockIsolated(0)

        await withDependencies {
            $0.continuousClock = clock
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
        } operation: {
            let engine = DomainFreshnessEngine()
            engine.register(.inbox, DomainRegistration(ttl: 30, refresh: {
                let n = refreshes.withValue { $0 += 1; return $0 }
                return n > 1   // first read fails, later ones succeed
            }))

            await engine.refreshIfStale(.inbox)   // runs, fails
            #expect(refreshes.value == 1)
            await engine.refreshIfStale(.inbox)   // still stale → re-reads
            #expect(refreshes.value == 2)
            await engine.refreshIfStale(.inbox)   // now fresh → skipped
            #expect(refreshes.value == 2)
        }
    }

    /// An invalidate with no registration is dropped (never crashes, never
    /// arms anything).
    @Test func unregisteredDomainIsDropped() async throws {
        let clock = TestClock()
        await withDependencies {
            $0.continuousClock = clock
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
        } operation: {
            let engine = DomainFreshnessEngine()
            engine.invalidate(.ftlMesh)
            await engine.refreshIfStale(.ftlMesh)
            await clock.advance(by: .seconds(5))
        }
    }
}

extension Task where Success == Never, Failure == Never {
    /// Yield enough times that independently-spawned tasks (the debounce fire →
    /// refresh chain) get to run to completion on the cooperative pool.
    static func megaYield() async {
        for _ in 0..<20 { await Task.yield() }
    }
}
