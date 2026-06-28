//
//  DeadlineScheduler.swift
//  Replicould — GameSync
//
//  The backstop that completes self-describing actions when their relay event is
//  lost (IMPLEMENTATION_PLAN §5.4 / Phase 4). It watches open `active` ops that
//  carry a `completesAt`, sleeps until the earliest one, and on the deadline
//  takes one high-priority confirm-read (via the poll coordinator) and closes
//  the op — unless a relay completion event already did, in which case the op is
//  no longer open and nothing happens (no wasted read).
//
//  Enqueued ops with no deadline are intentionally skipped here; their
//  completion arrives as a relay event (e.g. `print_complete`).
//

import ComposableArchitecture
import DependencyClients
import Foundation
import OSLog
import SQLiteData

private let logger = Logger(subsystem: "name.pennig.replicould", category: "DeadlineScheduler")

/// Disambiguate from `Foundation.Operation`.
private typealias Operation = DependencyClients.Operation

actor DeadlineScheduler {
    private let coordinator: PollCoordinator
    private let reconciler: Reconciler
    /// Upper bound on a single sleep, so ops inserted after the current sleep
    /// began are still picked up promptly.
    private let cap: Duration

    private var loopTask: Task<Void, Never>?

    /// Minimum spacing between re-poll attempts once a deadline has passed but
    /// the device is still working (so a slipped estimate doesn't busy-loop).
    private let rearmBackoff: TimeInterval
    /// How long past `startedAt` to keep polling a still-busy op before giving up
    /// and marking it `unknown` (a truly stuck backend, not a small skew).
    private let giveUpAfter: TimeInterval

    init(
        coordinator: PollCoordinator,
        reconciler: Reconciler,
        cap: Duration = .seconds(30),
        rearmBackoff: TimeInterval = 4,
        giveUpAfter: TimeInterval = 30 * 60
    ) {
        self.coordinator = coordinator
        self.reconciler = reconciler
        self.cap = cap
        self.rearmBackoff = rearmBackoff
        self.giveUpAfter = giveUpAfter
    }

    func start() {
        guard loopTask == nil else { return }
        loopTask = Task { await run() }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    private func run() async {
        @Dependency(\.continuousClock) var clock
        @Dependency(\.date) var date
        while !Task.isCancelled {
            let now = date.now
            await processDue(now: now)

            let upcoming = await openDatedOps()
                .compactMap(\.completesAt)
                .filter { $0 > now }
                .min()
            let delay: Duration = upcoming.map { .seconds(max(0, $0.timeIntervalSince(now))) } ?? cap
            try? await clock.sleep(for: min(delay, cap))
        }
    }

    /// Resolve every operation whose deadline has passed. Extracted so the core
    /// behavior is testable without the sleep loop.
    ///
    /// The deadline is only a *trigger to confirm*, never proof of completion: the
    /// server's ETA can be optimistic (the read may show 98% with seconds to go),
    /// and the arrival event can be lost. So after one high-priority confirm-read
    /// we decide from the freshly-reconciled device:
    ///   • settled → the action finished → complete the op;
    ///   • still working → re-arm to the device's fresh ETA and keep polling
    ///     (never complete prematurely, never leave it stuck);
    ///   • stuck far past dispatch → give up and mark `unknown`.
    func processDue(now: Date) async {
        @Dependency(\.defaultDatabase) var database

        for due in await openDatedOps() where (due.completesAt ?? .distantFuture) <= now {
            logger.info("deadline reached for op \(due.id, privacy: .public) (\(due.kind, privacy: .public)) on \(due.entityCode, privacy: .public) — confirming")
            await coordinator.refresh(due.entityCode, priority: .high)

            // A relay completion event may have closed it during the read.
            guard
                let op = try? await database.read({ db in
                    try Operation.where { $0.id.eq(due.id) }.fetchOne(db)
                }),
                op.status == OperationStatus.active.rawValue
            else { continue }

            let device = try? await database.read { db in
                try Device.where { $0.deviceCode.eq(op.entityCode) }.fetchOne(db)
            }

            if let device, device.isSettled {
                logger.info("op \(op.id, privacy: .public): device settled (\(device.status, privacy: .public)) — completing")
                await reconciler.completeOpenOperation(on: op.entityCode, source: .poll, eventTime: now, result: nil)
            } else if now.timeIntervalSince(op.startedAt) > giveUpAfter {
                logger.error("op \(op.id, privacy: .public): still busy \(Int(now.timeIntervalSince(op.startedAt)))s after dispatch — marking unknown")
                await setStatus(op.id, to: .unknown, at: now)
            } else {
                // Still executing: re-arm to the device's fresh ETA (clamped so we
                // don't re-poll faster than the backoff), so the next loop iteration
                // confirms again rather than completing now.
                let next = max(device?.activityDeadline ?? .distantPast, now.addingTimeInterval(rearmBackoff))
                logger.info("op \(op.id, privacy: .public): still executing — re-armed to \(next.ISO8601Format(), privacy: .public)")
                await rearm(op.id, to: next, at: now)
            }
        }
    }

    /// Open (`active`) operations that carry a completion deadline.
    private func openDatedOps() async -> [Operation] {
        @Dependency(\.defaultDatabase) var database
        let active = (try? await database.read { db in
            try Operation.where { $0.status.eq(OperationStatus.active.rawValue) }.fetchAll(db)
        }) ?? []
        return active.filter { $0.completesAt != nil }
    }

    /// Push an op's deadline out (and refresh its freshness stamp) so the loop
    /// polls it again instead of completing it.
    private func rearm(_ id: String, to deadline: Date, at now: Date) async {
        @Dependency(\.defaultDatabase) var database
        try? await database.write { db in
            guard var op = try Operation.where({ $0.id.eq(id) }).fetchOne(db) else { return }
            op.completesAt = deadline
            op.lastConfirmedAt = now
            op.source = OperationSource.poll.rawValue
            try Operation.upsert { op }.execute(db)
        }
    }

    private func setStatus(_ id: String, to status: OperationStatus, at now: Date) async {
        @Dependency(\.defaultDatabase) var database
        try? await database.write { db in
            guard var op = try Operation.where({ $0.id.eq(id) }).fetchOne(db) else { return }
            op.status = status.rawValue
            op.lastConfirmedAt = now
            op.source = OperationSource.poll.rawValue
            try Operation.upsert { op }.execute(db)
        }
    }
}
