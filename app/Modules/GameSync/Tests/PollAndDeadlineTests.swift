//
//  PollAndDeadlineTests.swift
//  Replicould — GameSync
//
//  Phase 4 engine: the poll coordinator spends the read budget frugally
//  (coalesce / TTL / budget-aware deferral), and the deadline scheduler closes a
//  due operation with exactly one confirm-read — or none if a relay event beat
//  it.
//

import API
import ComposableArchitecture
import Foundation
import GameModels
import SQLiteData
import Testing
import Utils
@testable import GameServices
@testable import GameSync

/// Disambiguate from `Foundation.Operation`.
private typealias Operation = GameModels.Operation

// MARK: - Shared fixtures

private func makeDatabase() throws -> any DatabaseWriter {
    let database = try SQLiteData.defaultDatabase()
    var migrator = DatabaseMigrator()
    Device.registerMigrations(&migrator)
    Operation.registerMigrations(&migrator)
    try migrator.migrate(database)
    return database
}

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
        let database = try makeDatabase()
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
        let database = try makeDatabase()
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
        let database = try makeDatabase()
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

    /// A high-priority refresh ignores budget pressure (the deadline matters).
    @Test func highPriorityIgnoresBudget() async throws {
        let database = try makeDatabase()
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
        let database = try makeDatabase()
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

    /// At the deadline the device is still working (estimate slipped): the op is
    /// NOT completed — it's re-armed to the device's fresh ETA so polling
    /// continues. Guards against the deadline preempting a not-quite-finished
    /// action (and against a lost arrival event leaving it stuck).
    @Test func stillBusyAtDeadlineRearmsInsteadOfCompleting() async throws {
        let database = try makeDatabase()
        let deadline = Date(timeIntervalSince1970: 1_000)
        try await database.write { db in
            // Started just before the deadline, so it's well within the give-up cap.
            try Operation.insert {
                activeOp("op1", device: "D", completesAt: deadline, startedAt: deadline.addingTimeInterval(-50))
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

    /// An op whose deadline is still in the future is left alone (no read).
    @Test func futureOperationIsUntouched() async throws {
        let database = try makeDatabase()
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
        let database = try makeDatabase()
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

    /// The sweep must NOT complete a mine that's still running — a legitimately
    /// long mine stays open (only a settled device ends it).
    @Test func continuousOpOnStillMiningDeviceStaysOpen() async throws {
        let database = try makeDatabase()
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

    /// If a relay event already completed the op, the deadline does nothing —
    /// no wasted read.
    @Test func alreadyCompletedOperationTriggersNoRead() async throws {
        let database = try makeDatabase()
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
