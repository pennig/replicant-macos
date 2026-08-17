//
//  StalenessTrackerTests.swift
//  Replicould — GameServices
//
//  The device-staleness half of V3.5: marks are free, and are spent as
//  budgeted low-priority reads only for visible or op-holding devices, a
//  slow-drip aged tier, or on demand via `refreshIfStale`. Marks clear through
//  `markSatisfied` (driven by `Reconciler.ingest` in production) under an
//  issue-time guard — never blindly by the drain itself.
//

import ComposableArchitecture
import Foundation
import GameDatabase
import GameModels
import SQLiteData
import Testing
@testable import GameServices

/// Disambiguate from `Foundation.Operation`.
private typealias Operation = GameModels.Operation

@Suite struct StalenessTrackerTests {

    private func makeDevice(_ code: String) -> Device {
        Device(
            deviceCode: code, deviceType: "mining_drone", replicantCode: "R1", status: "idle",
            location: nil, locationName: nil, operationalCapacity: 100, queueSize: 0,
            stowedInDeviceCode: nil, controllerDeviceCode: nil, attachedToDeviceCode: nil,
            createdAt: Date(timeIntervalSince1970: 0), availableCommands: [], features: [], tags: [],
            detail: .object([:]), updatedAt: Date(timeIntervalSince1970: 1_000),
            firstSeenAt: Date(timeIntervalSince1970: 1_000)
        )
    }

    /// A refresher stub that mimics the production loop: a successful read
    /// reconciles, which spends the mark via `markSatisfied` at the read's
    /// issue time.
    private func satisfyingRefresher(
        _ tracker: StalenessTracker,
        recording refreshed: LockIsolated<[String]>,
        succeed: LockIsolated<Bool> = LockIsolated(true)
    ) -> DeviceRefreshClient {
        DeviceRefreshClient { code, _ in
            @Dependency(\.date) var date
            refreshed.withValue { $0.append(code) }
            guard succeed.value else { return nil }
            await tracker.markSatisfied(code, asOf: date.now)
            return self.makeDevice(code)
        }
    }

    private func seedOp(_ database: any DatabaseWriter, device: String) async throws {
        try await database.write { db in
            try Operation.insert {
                Operation(
                    id: "op-\(device)", entityCode: device, kind: OperationKind.mine.rawValue,
                    status: .active, source: OperationSource.poll,
                    startedAt: Date(timeIntervalSince1970: 900), completesAt: nil,
                    lastConfirmedAt: Date(timeIntervalSince1970: 900), detail: .object([:])
                )
            }.execute(db)
        }
    }

    /// A drain pass reads visible and op-holding marks (visible first) and
    /// leaves a *fresh* hidden idle device's mark unspent.
    @Test func drainReadsVisibleAndOpHoldingButNotFreshHiddenIdle() async throws {
        let database = try GameDatabase.bootstrap()
        let refreshed = LockIsolated<[String]>([])
        let tracker = StalenessTracker()

        try await withDependencies { [self] in
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.deviceRefresher = satisfyingRefresher(tracker, recording: refreshed)
        } operation: {
            try await seedOp(database, device: "OPDEV")

            await tracker.setVisible(["SEEN"])
            await tracker.markStale("HIDDEN", reason: "travel.cruising")
            await tracker.markStale("OPDEV", reason: "mining.tick")
            await tracker.markStale("SEEN", reason: "status.changed")

            await tracker.drainPass()

            #expect(refreshed.value.contains("SEEN"))
            #expect(refreshed.value.contains("OPDEV"))
            #expect(!refreshed.value.contains("HIDDEN"))
            #expect(refreshed.value.firstIndex(of: "SEEN")! < refreshed.value.firstIndex(of: "OPDEV")!)
        }
    }

    /// A spent mark isn't re-read; a mark whose read was suppressed (refresh
    /// returned nil, so nothing reconciled) is kept for a later pass.
    @Test func marksClearOnlyWhenAReadActuallyLands() async throws {
        let database = try GameDatabase.bootstrap()
        let refreshed = LockIsolated<[String]>([])
        let succeed = LockIsolated(false)
        let tracker = StalenessTracker()

        try await withDependencies { [self] in
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.deviceRefresher = satisfyingRefresher(tracker, recording: refreshed, succeed: succeed)
        } operation: {
            try await seedOp(database, device: "D")
            await tracker.markStale("D", reason: "x")

            await tracker.drainPass()   // read suppressed → mark kept
            succeed.setValue(true)
            await tracker.drainPass()   // read lands → mark spent via markSatisfied
            await tracker.drainPass()   // nothing left to do

            #expect(refreshed.value == ["D", "D"])
        }
    }

    /// A snapshot issued *before* the mark must not spend it — the pre-mark
    /// read can't contain what the mark's event changed.
    @Test func preMarkSnapshotDoesNotSpendTheMark() async throws {
        let database = try GameDatabase.bootstrap()
        let refreshed = LockIsolated<[String]>([])
        let tracker = StalenessTracker()

        await withDependencies { [self] in
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.deviceRefresher = satisfyingRefresher(tracker, recording: refreshed)
        } operation: {
            await tracker.markStale("D", reason: "x")   // marked at t=1000

            await tracker.markSatisfied("D", asOf: Date(timeIntervalSince1970: 999))
            await tracker.refreshIfStale("D")           // mark survived → reads
            #expect(refreshed.value == ["D"])

            await tracker.refreshIfStale("D")           // spent at t=1000 → no read
            #expect(refreshed.value == ["D"])
        }
    }

    /// A hidden idle device's mark drains on the slow tier once aged — a
    /// one-shot transition (server-driven re-task with no follow-up event)
    /// still converges — and at most one aged mark drains per pass.
    @Test func agedHiddenMarksDrainSlowly() async throws {
        let database = try GameDatabase.bootstrap()
        let refreshed = LockIsolated<[String]>([])
        let now = LockIsolated(Date(timeIntervalSince1970: 1_000))
        let tracker = StalenessTracker(hiddenMarkDrainAge: 30)

        await withDependencies { [self] in
            $0.defaultDatabase = database
            $0.date = DateGenerator { now.value }
            $0.deviceRefresher = satisfyingRefresher(tracker, recording: refreshed)
        } operation: {
            await tracker.markStale("A", reason: "x")
            now.setValue(Date(timeIntervalSince1970: 1_001))
            await tracker.markStale("B", reason: "x")

            await tracker.drainPass()   // both too fresh → nothing
            #expect(refreshed.value.isEmpty)

            now.setValue(Date(timeIntervalSince1970: 1_040))
            await tracker.drainPass()   // one aged mark per pass, oldest first
            #expect(refreshed.value == ["A"])
            await tracker.drainPass()
            #expect(refreshed.value == ["A", "B"])
        }
    }

    /// Re-marking must not reset the age gate: a hidden device ticking events
    /// more often than the age threshold still drains once its FIRST mark
    /// ages — otherwise a busy hidden device would stay stale for the whole
    /// activity.
    @Test func busyHiddenDeviceStillAgesIntoTheSlowTier() async throws {
        let database = try GameDatabase.bootstrap()
        let refreshed = LockIsolated<[String]>([])
        let now = LockIsolated(Date(timeIntervalSince1970: 1_000))
        let tracker = StalenessTracker(hiddenMarkDrainAge: 30)

        await withDependencies { [self] in
            $0.defaultDatabase = database
            $0.date = DateGenerator { now.value }
            $0.deviceRefresher = satisfyingRefresher(tracker, recording: refreshed)
        } operation: {
            for tick in 0..<8 {   // an event every 5s — never 30s quiet
                now.setValue(Date(timeIntervalSince1970: 1_000 + Double(tick) * 5))
                await tracker.markStale("BUSY", reason: "mining.tick")
            }
            now.setValue(Date(timeIntervalSince1970: 1_031))   // first mark now 31s old
            await tracker.drainPass()
            #expect(refreshed.value == ["BUSY"])
        }
    }

    /// An aged mark whose read keeps failing yields the slot: it is retried
    /// only after the backoff, and other aged marks drain in between.
    @Test func failingAgedMarkDoesNotStarveTheTier() async throws {
        let database = try GameDatabase.bootstrap()
        let refreshed = LockIsolated<[String]>([])
        let now = LockIsolated(Date(timeIntervalSince1970: 1_000))
        let tracker = StalenessTracker(hiddenMarkDrainAge: 30, agedRetryBackoff: 60)

        await withDependencies {
            $0.defaultDatabase = database
            $0.date = DateGenerator { now.value }
            $0.deviceRefresher = DeviceRefreshClient { code, _ in
                refreshed.withValue { $0.append(code) }
                return nil   // every read fails — marks never satisfied
            }
        } operation: {
            await tracker.markStale("DEAD", reason: "x")
            now.setValue(Date(timeIntervalSince1970: 1_001))
            await tracker.markStale("NEXT", reason: "x")

            now.setValue(Date(timeIntervalSince1970: 1_040))
            await tracker.drainPass()   // oldest (DEAD) attempted
            await tracker.drainPass()   // DEAD in backoff → NEXT gets the slot
            await tracker.drainPass()   // both in backoff → nothing
            #expect(refreshed.value == ["DEAD", "NEXT"])

            now.setValue(Date(timeIntervalSince1970: 1_110))
            await tracker.drainPass()   // backoff elapsed → DEAD retried
            #expect(refreshed.value == ["DEAD", "NEXT", "DEAD"])
        }
    }

    /// `forget` (prune) drops a mark outright — a device that left the fleet
    /// can never satisfy its mark.
    @Test func forgetDropsMarks() async throws {
        let database = try GameDatabase.bootstrap()
        let refreshed = LockIsolated<[String]>([])
        let tracker = StalenessTracker()

        await withDependencies { [self] in
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.deviceRefresher = satisfyingRefresher(tracker, recording: refreshed)
        } operation: {
            await tracker.markStale("GONE", reason: "x")
            await tracker.forget(["GONE"])
            await tracker.refreshIfStale("GONE")
            #expect(refreshed.value.isEmpty)
        }
    }

    /// `refreshIfStale` spends a hidden device's mark on demand (the
    /// selection path), and is a no-op for an unmarked device.
    @Test func refreshIfStaleSpendsAMarkOnDemand() async throws {
        let database = try GameDatabase.bootstrap()
        let refreshed = LockIsolated<[String]>([])
        let tracker = StalenessTracker()

        await withDependencies { [self] in
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.deviceRefresher = satisfyingRefresher(tracker, recording: refreshed)
        } operation: {
            await tracker.markStale("D", reason: "x")

            await tracker.refreshIfStale("OTHER")   // unmarked → no read
            #expect(refreshed.value.isEmpty)

            await tracker.refreshIfStale("D")       // marked → one read
            await tracker.refreshIfStale("D")       // spent → no second read
            #expect(refreshed.value == ["D"])
        }
    }

    /// `markUrgent` drains ahead of visible/op-holding marks, at `.high`
    /// priority, capped at `urgentPerPass` per pass — a leftover urgent mark
    /// waits for the next pass rather than blowing through the cap.
    @Test func urgentMarksDrainAheadOfOrdinaryOnesWithinTheCap() async throws {
        let database = try GameDatabase.bootstrap()
        let refreshed = LockIsolated<[(code: String, priority: RefreshPriority)]>([])
        let tracker = StalenessTracker(maxPerPass: 3, urgentPerPass: 2)
        let now = LockIsolated(Date(timeIntervalSince1970: 1_000))

        try await withDependencies { [self] in
            $0.defaultDatabase = database
            $0.date = DateGenerator { now.value }
            $0.deviceRefresher = DeviceRefreshClient { code, priority in
                refreshed.withValue { $0.append((code, priority)) }
                await tracker.markSatisfied(code, asOf: now.value)
                return self.makeDevice(code)
            }
        } operation: {
            // OPDEV is an ordinary op-holding mark — op-holding drains without
            // the visible tier's own `drainSoon`, keeping this pass explicit.
            try await seedOp(database, device: "OPDEV")

            await tracker.markUrgent("U1", "printer.jammed")
            now.setValue(now.value.addingTimeInterval(1))
            await tracker.markUrgent("U2", "printer.jammed")
            now.setValue(now.value.addingTimeInterval(1))
            await tracker.markUrgent("U3", "printer.jammed")
            now.setValue(now.value.addingTimeInterval(1))
            await tracker.markStale("OPDEV", reason: "mining.tick")

            await tracker.drainPass()   // urgentPerPass caps urgent at 2; OPDEV fills the 3rd slot
            #expect(refreshed.value.map(\.code) == ["U1", "U2", "OPDEV"])
            #expect(refreshed.value[0].priority == .high)
            #expect(refreshed.value[1].priority == .high)
            #expect(refreshed.value[2].priority == .low)

            await tracker.drainPass()   // U3 carried over, drains next pass
            #expect(refreshed.value.map(\.code) == ["U1", "U2", "OPDEV", "U3"])
            #expect(refreshed.value[3].priority == .high)
        }
    }

    /// Urgent marks whose reads never land cannot take a whole pass: one
    /// ordinary slot is reserved, so the visible/op-holding/aged tiers keep
    /// draining beside them.
    @Test func stuckUrgentMarksDoNotStarveTheOrdinaryTiers() async throws {
        let database = try GameDatabase.bootstrap()
        let refreshed = LockIsolated<[String]>([])
        let now = LockIsolated(Date(timeIntervalSince1970: 1_000))
        let tracker = StalenessTracker(maxPerPass: 4, urgentPerPass: 4)

        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = DateGenerator { now.value }
            $0.deviceRefresher = DeviceRefreshClient { code, _ in
                refreshed.withValue { $0.append(code) }
                return nil   // no read ever lands, so no mark is ever spent
            }
        } operation: {
            try await seedOp(database, device: "OPDEV")
            for code in ["U1", "U2", "U3", "U4"] {
                await tracker.markUrgent(code, "print.completed")
                now.setValue(now.value.addingTimeInterval(1))
            }
            await tracker.markStale("OPDEV", reason: "mining.tick")

            await tracker.drainPass()
            #expect(refreshed.value.filter { $0.hasPrefix("U") }.count == 3)
            #expect(refreshed.value.contains("OPDEV"))
        }
    }

    /// An urgent mark whose read never lands is paced by `urgentRetryBackoff`,
    /// then demoted after `urgentAttemptLimit` attempts — after which it drains
    /// as an ordinary mark, at `.low`, where the coordinator throttles it.
    @Test func urgentRetriesArePacedThenDemoted() async throws {
        let database = try GameDatabase.bootstrap()
        let refreshed = LockIsolated<[RefreshPriority]>([])
        let now = LockIsolated(Date(timeIntervalSince1970: 1_000))
        let tracker = StalenessTracker(
            hiddenMarkDrainAge: 30, agedRetryBackoff: 60,
            urgentRetryBackoff: 15, urgentAttemptLimit: 3
        )

        await withDependencies {
            $0.defaultDatabase = database
            $0.date = DateGenerator { now.value }
            $0.deviceRefresher = DeviceRefreshClient { _, priority in
                refreshed.withValue { $0.append(priority) }
                return nil
            }
        } operation: {
            await tracker.markNew("CLONE")   // a clone code that 404s forever

            await tracker.drainPass()   // attempt 1
            await tracker.drainPass()   // inside the backoff → no read
            #expect(refreshed.value == [.high])

            now.setValue(Date(timeIntervalSince1970: 1_015))
            await tracker.drainPass()   // attempt 2
            now.setValue(Date(timeIntervalSince1970: 1_030))
            await tracker.drainPass()   // attempt 3 — and the demotion
            #expect(refreshed.value == [.high, .high, .high])

            now.setValue(Date(timeIntervalSince1970: 1_045))
            await tracker.drainPass()   // ordinary now: the aged tier, at `.low`
            #expect(refreshed.value == [.high, .high, .high, .low])
        }
    }

    /// `markUrgent` on a device already in `visible` self-triggers a drain —
    /// no explicit `drainPass()` call needed, matching `markStale`'s own
    /// visible-tier promptness.
    @Test func urgentMarkOnAVisibleDeviceSelfTriggersADrain() async throws {
        let database = try GameDatabase.bootstrap()
        let refreshed = LockIsolated<[(code: String, priority: RefreshPriority)]>([])
        let tracker = StalenessTracker()

        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.deviceRefresher = DeviceRefreshClient { code, priority in
                refreshed.withValue { $0.append((code, priority)) }
                return nil
            }
        } operation: {
            await tracker.setVisible(["V1"])
            await tracker.markUrgent("V1", "travel.arrived")   // no explicit drainPass()

            for _ in 0..<200 where refreshed.value.isEmpty {
                await Task.yield()
            }

            #expect(refreshed.value.map(\.code) == ["V1"])
            #expect(refreshed.value.first?.priority == .high)
        }
    }

    /// `markNew` marks a code with NO local `Device` row (the print clone) —
    /// the drain still issues the read, through the same urgent tier.
    @Test func markNewDrainsACodeWithNoLocalRow() async throws {
        let database = try GameDatabase.bootstrap()
        let refreshed = LockIsolated<[(code: String, priority: RefreshPriority)]>([])
        let tracker = StalenessTracker()

        try await withDependencies { [self] in
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.deviceRefresher = DeviceRefreshClient { code, priority in
                @Dependency(\.date) var date
                refreshed.withValue { $0.append((code, priority)) }
                await tracker.markSatisfied(code, asOf: date.now)
                return self.makeDevice(code)
            }
        } operation: {
            let codes = try await database.read { db in try Device.fetchAll(db) }
            #expect(codes.isEmpty, "CLONE has no local row before the drain reads it in")

            await tracker.markNew("CLONE")
            await tracker.drainPass()

            #expect(refreshed.value.map(\.code) == ["CLONE"])
            #expect(refreshed.value[0].priority == .high)

            await tracker.drainPass()   // mark satisfied → no second read
            #expect(refreshed.value.count == 1)
        }
    }

    /// `stopDraining` forgets every mark (logout) — a later pass reads nothing.
    @Test func stopForgetsMarks() async throws {
        let database = try GameDatabase.bootstrap()
        let refreshed = LockIsolated<[String]>([])
        let tracker = StalenessTracker()

        try await withDependencies { [self] in
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.deviceRefresher = satisfyingRefresher(tracker, recording: refreshed)
        } operation: {
            try await seedOp(database, device: "D")
            await tracker.markStale("D", reason: "x")
            await tracker.stopDraining()
            await tracker.drainPass()
            await tracker.refreshIfStale("D")

            #expect(refreshed.value.isEmpty)
        }
    }
}
