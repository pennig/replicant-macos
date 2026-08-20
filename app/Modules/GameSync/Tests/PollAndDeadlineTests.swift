//
//  PollAndDeadlineTests.swift
//  Replicould — GameSync
//
//  Phase 4 engine: the poll coordinator spends the read budget frugally
//  (coalesce / TTL / budget-aware deferral), and the deadline scheduler closes a
//  due operation with exactly one confirm-read — or none if a stream event beat
//  it.
//

import API
import ComposableArchitecture
import Foundation
import GameDatabase
import GameModels
import GameSession
import SQLiteData
import Testing
import Utils
@testable import GameServices
@testable import GameSync

/// Disambiguate from `Foundation.Operation`.
private typealias Operation = GameModels.Operation

// MARK: - Shared fixtures

private func device(_ code: String, status: String = "idle") -> Device {
    Device(
        deviceCode: code, deviceType: "mining_drone", replicantCode: "R1", status: status,
        location: nil, locationName: nil, operationalCapacity: 100, queueSize: 0,
        stowedInDeviceCode: nil, controllerDeviceCode: nil, attachedToDeviceCode: nil,
        createdAt: Date(timeIntervalSince1970: 0), availableCommands: [], features: [], tags: [],
        detail: .object([:]), updatedAt: Date(timeIntervalSince1970: 1_000),
        firstSeenAt: Date(timeIntervalSince1970: 1_000)
    )
}

private func travellingDevice(_ code: String, arrivesAt: Date) -> Device {
    var device = device(code, status: "travelling")
    device.detail = .object(["travel": .object(["arrives_at": .string(arrivesAt.ISO8601Format())])])
    return device
}

private func activeOp(
    _ id: String,
    device: String,
    completesAt: Date?,
    startedAt: Date = Date(timeIntervalSince1970: 0)
) -> Operation {
    Operation(
        id: id, entityCode: device, kind: OperationKind.travel.rawValue,
        status: OperationStatus.active, source: OperationSource.poll,
        startedAt: startedAt, completesAt: completesAt,
        lastConfirmedAt: startedAt, detail: .object([:])
    )
}

/// An active *continuous* mining op — no deadline, so it never enters the
/// deadline queue and relies on the continuous-op sweep as its lost-event backstop.
private func miningOp(_ id: String, device: String) -> Operation {
    Operation(
        id: id, entityCode: device, kind: OperationKind.mine.rawValue,
        status: OperationStatus.active, source: OperationSource.poll,
        startedAt: Date(timeIntervalSince1970: 0), completesAt: nil,
        lastConfirmedAt: Date(timeIntervalSince1970: 0), detail: .object([:])
    )
}

private func budgetGameClient(remaining: Int) -> GameClient {
    GameClient(
        make: { ReplicantSpace.client(apiKey: "") },
        budget: { _ in RateLimitGovernor.Snapshot(limit: 120, remaining: remaining, resetAt: nil) }
    )
}

// MARK: - PollCoordinator

@Suite struct PollCoordinatorTests {

    /// N concurrent refreshes for one device collapse into a single read.
    @Test func concurrentRefreshesCoalesceToOneRead() async throws {
        let database = try GameDatabase.bootstrap()
        let reads = LockIsolated(0)
        let started = AsyncStream.makeStream(of: Void.self)
        let gate = LockIsolated<CheckedContinuation<Void, Never>?>(nil)

        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.devicesClient.read = { code in
                reads.withValue { $0 += 1 }
                started.continuation.yield(())
                await withCheckedContinuation { gate.setValue($0) }
                return device(code)
            }
        } operation: {
            let coordinator = PollCoordinator(reconciler: Reconciler())
            let first = Task { await coordinator.refresh("D", priority: .high) }

            // Wait until the (single) read is actually in flight.
            var iterator = started.stream.makeAsyncIterator()
            _ = await iterator.next()

            // Fire more refreshes — they must join the in-flight read.
            let others = (0..<4).map { _ in Task { await coordinator.refresh("D", priority: .high) } }

            // Release the read and let everyone finish.
            while gate.value == nil { await Task.yield() }
            gate.value?.resume()
            _ = await first.value
            for task in others { _ = await task.value }
        }

        #expect(reads.value == 1)
    }

    /// A low-priority trigger within the TTL of the last read is suppressed.
    @Test func ttlSuppressesLowPriorityReread() async throws {
        let database = try GameDatabase.bootstrap()
        let reads = LockIsolated(0)

        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))   // no time passes
            $0.gameClient = budgetGameClient(remaining: 100)          // ample budget
            $0.devicesClient.read = { code in
                reads.withValue { $0 += 1 }
                return device(code)
            }
        } operation: {
            let coordinator = PollCoordinator(reconciler: Reconciler())
            _ = await coordinator.refresh("D", priority: .low)   // reads (1)
            let second = await coordinator.refresh("D", priority: .low)   // within TTL → suppressed
            #expect(second == nil)
        }

        #expect(reads.value == 1)
    }

    /// Under read-budget pressure, a low-priority refresh is deferred (no read).
    @Test func budgetPressureDefersLowPriority() async throws {
        let database = try GameDatabase.bootstrap()
        let reads = LockIsolated(0)

        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.gameClient = budgetGameClient(remaining: 5)   // below the floor
            $0.devicesClient.read = { code in
                reads.withValue { $0 += 1 }
                return device(code)
            }
        } operation: {
            let coordinator = PollCoordinator(reconciler: Reconciler(), budgetFloor: 12)
            let result = await coordinator.refresh("D", priority: .low)
            #expect(result == nil)
        }

        #expect(reads.value == 0)
    }

    /// A `.high` refresh must not join a read issued *before* its own request
    /// time — the inspector's poll racing a command's confirm-read would hand
    /// back a pre-command snapshot and TTL-suppress the SSE echo that should
    /// repair it. It waits the stale read out, then issues a fresh one.
    @Test func highPriorityRefusesToJoinEarlierRead() async throws {
        let database = try GameDatabase.bootstrap()
        let reads = LockIsolated(0)
        let started = AsyncStream.makeStream(of: Void.self)
        let gate = LockIsolated<CheckedContinuation<Void, Never>?>(nil)
        let now = LockIsolated(Date(timeIntervalSince1970: 1_000))

        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = DateGenerator { now.value }
            $0.gameClient = budgetGameClient(remaining: 100)   // the .low read must pass the floor
            $0.devicesClient.read = { code in
                let n = reads.withValue { $0 += 1; return $0 }
                if n == 1 {
                    // The pre-command read: block until the test releases it.
                    started.continuation.yield(())
                    await withCheckedContinuation { gate.setValue($0) }
                    return device(code, status: "idle")
                }
                return device(code, status: "travelling")
            }
        } operation: {
            let coordinator = PollCoordinator(reconciler: Reconciler())
            let stale = Task { await coordinator.refresh("D", priority: .low) }

            // Wait until the pre-command read is actually in flight.
            var iterator = started.stream.makeAsyncIterator()
            _ = await iterator.next()

            // The command lands; its confirm-read demands state as of t+1.
            now.setValue(Date(timeIntervalSince1970: 1_001))
            let confirm = Task { await coordinator.refresh("D", priority: .high) }

            // Deterministically wait for the confirm to hit the barrier — the
            // stale read is still gate-blocked, so its in-flight entry is
            // guaranteed present and the barrier path MUST be taken (a plain
            // gate release could race the confirm onto an empty coordinator,
            // passing without exercising the barrier at all).
            while await coordinator.barrierWaits == 0 { await Task.yield() }

            // Release the stale read; the confirm must then re-read fresh.
            while gate.value == nil { await Task.yield() }
            gate.value?.resume()
            let joined = await stale.value
            let fresh = await confirm.value
            #expect(joined?.status == "idle")
            #expect(fresh?.status == "travelling")
        }

        #expect(reads.value == 2)
    }

    /// A failed read must not stamp the TTL: the next low-priority trigger (the
    /// command's SSE echo) still gets to read and repair the miss.
    @Test func failedReadDoesNotSuppressFollowUp() async throws {
        let database = try GameDatabase.bootstrap()
        let reads = LockIsolated(0)

        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.gameClient = budgetGameClient(remaining: 100)
            $0.devicesClient.read = { code in
                let n = reads.withValue { $0 += 1; return $0 }
                if n == 1 { throw URLError(.timedOut) }
                return device(code)
            }
        } operation: {
            let coordinator = PollCoordinator(reconciler: Reconciler())
            let failed = await coordinator.refresh("D", priority: .high)
            #expect(failed == nil)
            let repaired = await coordinator.refresh("D", priority: .low)
            #expect(repaired != nil)
        }

        #expect(reads.value == 2)
    }

    /// A high-priority refresh ignores budget pressure (the deadline matters).
    @Test func highPriorityIgnoresBudget() async throws {
        let database = try GameDatabase.bootstrap()
        let reads = LockIsolated(0)

        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.gameClient = budgetGameClient(remaining: 1)
            $0.devicesClient.read = { code in
                reads.withValue { $0 += 1 }
                return device(code)
            }
        } operation: {
            let coordinator = PollCoordinator(reconciler: Reconciler(), budgetFloor: 12)
            _ = await coordinator.refresh("D", priority: .high)
        }

        #expect(reads.value == 1)
    }
}

// MARK: - DeadlineScheduler

@Suite struct DeadlineSchedulerTests {

    private func schedulerProcessing(now: Date, database: any DatabaseWriter, reads: LockIsolated<Int>) async {
        let reconciler = Reconciler()
        let coordinator = PollCoordinator(reconciler: reconciler)
        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(now)
            $0.devicesClient.read = { code in
                reads.withValue { $0 += 1 }
                return device(code)
            }
            $0.deviceRefresher = DeviceRefreshClient { code, priority in
                await coordinator.refresh(code, priority: priority)
            }
        } operation: {
            let scheduler = DeadlineScheduler(reconciler: reconciler)
            await scheduler.processDue(now: now)
        }
    }

    /// A due op is closed with exactly one confirm-read.
    @Test func dueOperationCompletesWithOneRead() async throws {
        let database = try GameDatabase.bootstrap()
        let deadline = Date(timeIntervalSince1970: 1_000)
        try await database.write { db in
            try Operation.insert { activeOp("op1", device: "D", completesAt: deadline) }.execute(db)
        }
        let reads = LockIsolated(0)

        await schedulerProcessing(now: deadline.addingTimeInterval(1), database: database, reads: reads)

        let stored = try await database.read { db in try Operation.where { $0.id.eq("op1") }.fetchOne(db) }
        #expect(stored?.status == OperationStatus.completed)
        #expect(reads.value == 1)
    }

    /// At the deadline the device is still working and the server offers a
    /// *fresh forward* ETA (`arrivesAt > now + rearmBackoff`): the op is NOT
    /// completed — it's re-armed to that ETA (the fresh-ETA branch) so polling
    /// continues. Guards against the deadline preempting a not-quite-finished
    /// action (and against a lost arrival event leaving it stuck).
    @Test func stillBusyAtDeadlineRearmsInsteadOfCompleting() async throws {
        let database = try GameDatabase.bootstrap()
        let deadline = Date(timeIntervalSince1970: 1_000)
        try await database.write { db in
            try Operation.insert {
                activeOp("op1", device: "D", completesAt: deadline)
            }.execute(db)
        }
        let now = deadline.addingTimeInterval(1)
        let arrivesAt = now.addingTimeInterval(5)   // server now says 5 more seconds
        let reads = LockIsolated(0)

        let reconciler = Reconciler()
        let coordinator = PollCoordinator(reconciler: reconciler)
        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(now)
            $0.gameClient = budgetGameClient(remaining: 100)
            $0.devicesClient.read = { code in
                reads.withValue { $0 += 1 }
                return travellingDevice(code, arrivesAt: arrivesAt)
            }
            $0.deviceRefresher = DeviceRefreshClient { code, priority in
                await coordinator.refresh(code, priority: priority)
            }
        } operation: {
            let scheduler = DeadlineScheduler(reconciler: reconciler)
            await scheduler.processDue(now: now)
        }

        let stored = try await database.read { db in try Operation.where { $0.id.eq("op1") }.fetchOne(db) }
        #expect(stored?.status == OperationStatus.active)              // not completed
        #expect((stored?.completesAt).map { $0 > deadline } == true)            // re-armed forward
        #expect(reads.value == 1)
    }

    /// Regression (V3.3-S3): a LONG op — dispatched an hour ago — whose deadline
    /// just slipped must be re-armed, not abandoned. The old code measured the
    /// give-up window from `startedAt`, so any op longer than the window was
    /// marked `unknown` on its very first overdue confirm.
    @Test func longOpWithSlippedDeadlineRearmsInsteadOfGivingUp() async throws {
        let database = try GameDatabase.bootstrap()
        let deadline = Date(timeIntervalSince1970: 10_000)
        try await database.write { db in
            try Operation.insert {
                activeOp("op1", device: "D", completesAt: deadline, startedAt: deadline.addingTimeInterval(-3_600))
            }.execute(db)
        }
        let now = deadline.addingTimeInterval(1)
        let reconciler = Reconciler()
        let coordinator = PollCoordinator(reconciler: reconciler)

        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(now)
            $0.gameClient = budgetGameClient(remaining: 100)
            // Still travelling, and the server offers no *fresh* forward ETA —
            // the harshest slip: the estimate simply passed.
            $0.devicesClient.read = { code in travellingDevice(code, arrivesAt: deadline) }
            $0.deviceRefresher = DeviceRefreshClient { code, priority in
                await coordinator.refresh(code, priority: priority)
            }
        } operation: {
            let scheduler = DeadlineScheduler(reconciler: reconciler)
            await scheduler.processDue(now: now)
        }

        let stored = try await database.read { db in try Operation.where { $0.id.eq("op1") }.fetchOne(db) }
        #expect(stored?.status == OperationStatus.active, "a fresh slip re-arms; it never gives up")
        #expect((stored?.completesAt).map { $0 > deadline } == true)
    }

    /// A genuinely stuck op — overdue past the give-up window with the device
    /// never advancing its ETA — is still conceded `unknown`, with the window
    /// measured from the first unanswered deadline.
    @Test func stuckOpIsMarkedUnknownMeasuredFromItsDeadline() async throws {
        let database = try GameDatabase.bootstrap()
        let deadline = Date(timeIntervalSince1970: 10_000)
        try await database.write { db in
            try Operation.insert {
                activeOp("op1", device: "D", completesAt: deadline, startedAt: deadline.addingTimeInterval(-3_600))
            }.execute(db)
        }
        let reconciler = Reconciler()
        let coordinator = PollCoordinator(reconciler: reconciler)
        let scheduler = DeadlineScheduler(reconciler: reconciler, giveUpAfter: 300)

        func process(at now: Date) async {
            await withDependencies {
                $0.defaultDatabase = database
                $0.date = .constant(now)
                $0.gameClient = budgetGameClient(remaining: 100)
                $0.devicesClient.read = { code in travellingDevice(code, arrivesAt: deadline) }
                $0.deviceRefresher = DeviceRefreshClient { code, priority in
                    await coordinator.refresh(code, priority: priority)
                }
            } operation: {
                await scheduler.processDue(now: now)
            }
        }

        await process(at: deadline.addingTimeInterval(1))     // overdue → re-arm, window opens
        let mid = try await database.read { db in try Operation.where { $0.id.eq("op1") }.fetchOne(db) }
        #expect(mid?.status == OperationStatus.active)

        // 301s past the DEADLINE (> 300) but exactly 300s — not more — past the
        // first pass, so this only trips if the window is seeded from the
        // deadline itself, as the name claims.
        await process(at: deadline.addingTimeInterval(301))
        let stored = try await database.read { db in try Operation.where { $0.id.eq("op1") }.fetchOne(db) }
        #expect(stored?.status == OperationStatus.unknown)
    }

    /// A fresh forward ETA doesn't just re-arm — it RESETS the give-up window.
    /// A later slip is then measured from the new deadline, not the original
    /// one, so an op that keeps making visible progress is never abandoned.
    @Test func freshForwardETAResetsTheGiveUpWindow() async throws {
        let database = try GameDatabase.bootstrap()
        let deadline = Date(timeIntervalSince1970: 10_000)
        try await database.write { db in
            try Operation.insert {
                activeOp("op1", device: "D", completesAt: deadline)
            }.execute(db)
        }
        let reconciler = Reconciler()
        let coordinator = PollCoordinator(reconciler: reconciler)
        let scheduler = DeadlineScheduler(reconciler: reconciler, giveUpAfter: 300)

        func process(at now: Date, deviceArrivesAt: Date) async {
            await withDependencies {
                $0.defaultDatabase = database
                $0.date = .constant(now)
                $0.gameClient = budgetGameClient(remaining: 100)
                $0.devicesClient.read = { code in travellingDevice(code, arrivesAt: deviceArrivesAt) }
                $0.deviceRefresher = DeviceRefreshClient { code, priority in
                    await coordinator.refresh(code, priority: priority)
                }
            } operation: {
                await scheduler.processDue(now: now)
            }
        }

        // Pass 1: overdue, no forward ETA → window opens at the deadline.
        await process(at: deadline.addingTimeInterval(1), deviceArrivesAt: deadline)
        // Pass 2: the server now reports real progress (ETA deadline+150) →
        // re-arm to it and clear the window.
        await process(at: deadline.addingTimeInterval(100), deviceArrivesAt: deadline.addingTimeInterval(150))
        // Pass 3: overdue again at deadline+400 — 400s past the ORIGINAL
        // deadline (> 300, would be unknown had the window never reset) but
        // only 250s past the fresh one → must still be re-arming.
        await process(at: deadline.addingTimeInterval(400), deviceArrivesAt: deadline.addingTimeInterval(150))

        let stored = try await database.read { db in try Operation.where { $0.id.eq("op1") }.fetchOne(db) }
        #expect(stored?.status == OperationStatus.active, "the reset window is measured from the fresh deadline")
    }

    /// An op whose deadline is still in the future is left alone (no read).
    @Test func futureOperationIsUntouched() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Operation.insert {
                activeOp("op1", device: "D", completesAt: Date(timeIntervalSince1970: 9_999))
            }.execute(db)
        }
        let reads = LockIsolated(0)

        await schedulerProcessing(now: Date(timeIntervalSince1970: 1_000), database: database, reads: reads)

        let stored = try await database.read { db in try Operation.where { $0.id.eq("op1") }.fetchOne(db) }
        #expect(stored?.status == OperationStatus.active)
        #expect(reads.value == 0)
    }

    /// Continuous-op backstop: a deadline-less mining op whose device has
    /// silently settled to idle (its `site_resource_depleted` stop event was
    /// lost) is completed by the sweep — the read shows the mine is over.
    @Test func continuousOpOnSettledDeviceIsCompleted() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Operation.insert { miningOp("m1", device: "D") }.execute(db)
        }
        let now = Date(timeIntervalSince1970: 5_000)
        let reconciler = Reconciler()
        let coordinator = PollCoordinator(reconciler: reconciler)

        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(now)
            $0.gameClient = budgetGameClient(remaining: 100)
            $0.devicesClient.read = { code in device(code, status: "idle") }   // settled
            $0.deviceRefresher = DeviceRefreshClient { code, priority in
                await coordinator.refresh(code, priority: priority)
            }
        } operation: {
            let scheduler = DeadlineScheduler(reconciler: reconciler)
            await scheduler.sweepContinuousOps(now: now)
        }

        let stored = try await database.read { db in try Operation.where { $0.id.eq("m1") }.fetchOne(db) }
        #expect(stored?.status == OperationStatus.completed)
        #expect(stored?.source == OperationSource.poll)
    }

    /// The sweep closes ITSELF — not an older, unrelated live sibling on the
    /// same device (inserted first) that a bare oldest-first fallback would
    /// otherwise pick.
    @Test func continuousOpClosesItselfNotAnOlderSibling() async throws {
        let database = try GameDatabase.bootstrap()
        let olderSibling = Operation(
            id: "op-enq", entityCode: "D", kind: OperationKind.print.rawValue,
            status: OperationStatus.enqueued, source: OperationSource.poll,
            startedAt: Date(timeIntervalSince1970: 0), completesAt: nil,
            lastConfirmedAt: Date(timeIntervalSince1970: 0), detail: .object([:])
        )
        let activeMine = Operation(
            id: "m1", entityCode: "D", kind: OperationKind.mine.rawValue,
            status: OperationStatus.active, source: OperationSource.poll,
            startedAt: Date(timeIntervalSince1970: 1_000), completesAt: nil,
            lastConfirmedAt: Date(timeIntervalSince1970: 1_000), detail: .object([:])
        )
        try await database.write { db in
            try Operation.insert { olderSibling }.execute(db)
            try Operation.insert { activeMine }.execute(db)
        }
        let now = Date(timeIntervalSince1970: 5_000)
        let reconciler = Reconciler()
        let coordinator = PollCoordinator(reconciler: reconciler)

        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(now)
            $0.gameClient = budgetGameClient(remaining: 100)
            $0.devicesClient.read = { code in device(code, status: "idle") }
            $0.deviceRefresher = DeviceRefreshClient { code, priority in
                await coordinator.refresh(code, priority: priority)
            }
        } operation: {
            let scheduler = DeadlineScheduler(reconciler: reconciler)
            await scheduler.sweepContinuousOps(now: now)
        }

        let ops = try await database.read { db in try Operation.where { $0.entityCode.eq("D") }.fetchAll(db) }
        let byId = Dictionary(uniqueKeysWithValues: ops.map { ($0.id, $0.status) })
        #expect(byId["m1"] == OperationStatus.completed)
        #expect(byId["op-enq"] == OperationStatus.enqueued)
    }

    /// The sweep must NOT complete a mine that's still running — a legitimately
    /// long mine stays open (only a settled device ends it).
    @Test func continuousOpOnStillMiningDeviceStaysOpen() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Operation.insert { miningOp("m1", device: "D") }.execute(db)
        }
        let now = Date(timeIntervalSince1970: 5_000)
        let reconciler = Reconciler()
        let coordinator = PollCoordinator(reconciler: reconciler)

        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(now)
            $0.gameClient = budgetGameClient(remaining: 100)
            $0.devicesClient.read = { code in device(code, status: "mining (iron)") }   // still working
            $0.deviceRefresher = DeviceRefreshClient { code, priority in
                await coordinator.refresh(code, priority: priority)
            }
        } operation: {
            let scheduler = DeadlineScheduler(reconciler: reconciler)
            await scheduler.sweepContinuousOps(now: now)
        }

        let stored = try await database.read { db in try Operation.where { $0.id.eq("m1") }.fetchOne(db) }
        #expect(stored?.status == OperationStatus.active)
    }

    /// A due op closes ITSELF, by id — not the oldest live op, which here is
    /// the OLDER enqueued sibling (inserted first, defeating an unordered
    /// pick): a bare oldest-first fallback would pick the wrong one.
    @Test func deadlineClosesItsOwnOperation() async throws {
        let database = try GameDatabase.bootstrap()
        let deadline = Date(timeIntervalSince1970: 1_000)
        let opB: Operation = {
            var op = activeOp("OP-B", device: "B1", completesAt: nil, startedAt: deadline.addingTimeInterval(-120))
            op.status = .enqueued
            return op
        }()
        let opA = activeOp("OP-A", device: "B1", completesAt: deadline, startedAt: deadline.addingTimeInterval(-60))
        try await database.write { db in
            try Operation.insert { opB }.execute(db)
            try Operation.insert { opA }.execute(db)
            try Device.upsert { device("B1", status: "idle") }.execute(db)
        }

        let now = deadline.addingTimeInterval(1)
        let reconciler = Reconciler()
        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(now)
            // Bypasses the shared coordinator's own ingest-driven close; the
            // seeded row above is the settled read `processDue` itself consults.
            $0.deviceRefresher = DeviceRefreshClient { _, _ in nil }
        } operation: {
            let scheduler = DeadlineScheduler(reconciler: reconciler)
            await scheduler.processDue(now: now)
        }

        let ops = try await database.read { db in try Operation.where { $0.entityCode.eq("B1") }.fetchAll(db) }
        let byId = Dictionary(uniqueKeysWithValues: ops.map { ($0.id, $0.status) })
        #expect(byId["OP-A"] == OperationStatus.completed)
        #expect(byId["OP-B"] == OperationStatus.enqueued)
    }

    /// If a stream event already completed the op, the deadline does nothing —
    /// no wasted read.
    @Test func alreadyCompletedOperationTriggersNoRead() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            var op = activeOp("op1", device: "D", completesAt: Date(timeIntervalSince1970: 1_000))
            op.status = OperationStatus.completed
            try Operation.insert { op }.execute(db)
        }
        let reads = LockIsolated(0)

        await schedulerProcessing(now: Date(timeIntervalSince1970: 2_000), database: database, reads: reads)

        #expect(reads.value == 0)
    }
}
