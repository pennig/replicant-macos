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
import SQLiteData

/// Disambiguate from `Foundation.Operation`.
private typealias Operation = DependencyClients.Operation

actor DeadlineScheduler {
    private let coordinator: PollCoordinator
    private let reconciler: Reconciler
    /// Upper bound on a single sleep, so ops inserted after the current sleep
    /// began are still picked up promptly.
    private let cap: Duration

    private var loopTask: Task<Void, Never>?

    init(coordinator: PollCoordinator, reconciler: Reconciler, cap: Duration = .seconds(30)) {
        self.coordinator = coordinator
        self.reconciler = reconciler
        self.cap = cap
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

    /// Close every operation whose deadline has passed. Extracted so the core
    /// behavior is testable without the sleep loop.
    func processDue(now: Date) async {
        for op in await openDatedOps() where (op.completesAt ?? .distantFuture) <= now {
            // One high-priority confirm-read to refresh the device, then close the
            // op if a relay event hasn't already (completeOpenOperation re-checks).
            await coordinator.refresh(op.entityCode, priority: .high)
            await reconciler.completeOpenOperation(on: op.entityCode, source: .poll, eventTime: now, result: nil)
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
}
