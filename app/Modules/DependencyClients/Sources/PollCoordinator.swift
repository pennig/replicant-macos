//
//  PollCoordinator.swift
//  Replicould — shared dependency clients
//
//  Spends the read budget where it matters (IMPLEMENTATION_PLAN §4.3 / Phase 4).
//  Every device confirm-read — whether triggered by a relay event or by a
//  deadline — funnels through here so a burst of triggers collapses into the
//  fewest authoritative reads:
//
//    • Coalescing: a read already in flight for a device is shared, never
//      duplicated.
//    • TTL: a device read very recently is not re-read for low-priority
//      (event-invalidation) triggers.
//    • Budget-aware deferral: under read-budget pressure (Phase-0 snapshot),
//      low-priority refreshes are skipped — a deadline (high priority) or a
//      later event will catch the row up.
//
//  An actor so the in-flight map and last-read timestamps stay consistent under
//  concurrent triggers.
//

import ComposableArchitecture
import Foundation
import OSLog

private let logger = Logger(subsystem: "name.pennig.replicould", category: "PollCoordinator")

/// How urgent a device refresh is. Deadline confirmations are `high` (always
/// worth a read); event-driven invalidations are `low` (skippable under
/// pressure / TTL). Public so the `deviceRefresher` client can vend it.
public enum RefreshPriority: Sendable { case low, high }

actor PollCoordinator {
    private let reconciler: Reconciler
    /// Suppress a low-priority re-read within this window of the last read.
    private let ttl: TimeInterval
    /// Defer low-priority reads once the reads bucket drops to this many tokens.
    private let budgetFloor: Int

    private var inFlight: [String: Task<Device?, Never>] = [:]
    private var lastReadAt: [String: Date] = [:]

    init(reconciler: Reconciler, ttl: TimeInterval = 2, budgetFloor: Int = 12) {
        self.reconciler = reconciler
        self.ttl = ttl
        self.budgetFloor = budgetFloor
    }

    /// Refresh a device's authoritative snapshot, subject to coalescing, TTL, and
    /// budget. Returns the device if a read happened (or one was already in
    /// flight), or nil if the refresh was coalesced-away / suppressed / deferred.
    @discardableResult
    func refresh(_ deviceCode: String, priority: RefreshPriority) async -> Device? {
        // Join an in-flight read rather than firing a second.
        if let existing = inFlight[deviceCode] {
            logger.debug("refresh \(deviceCode, privacy: .public) [\(String(describing: priority), privacy: .public)]: coalesced into in-flight read")
            return await existing.value
        }

        if priority == .low {
            @Dependency(\.date) var date
            if let last = lastReadAt[deviceCode], date.now.timeIntervalSince(last) < ttl {
                logger.debug("refresh \(deviceCode, privacy: .public) [low]: suppressed (within \(self.ttl, format: .fixed(precision: 0))s TTL)")
                return nil   // read too recently for a low-priority trigger
            }
            @Dependency(\.gameClient) var gameClient
            let budget = await gameClient.budget(.reads)
            if budget.remaining <= budgetFloor {
                logger.notice("refresh \(deviceCode, privacy: .public) [low]: deferred (reads budget \(budget.remaining) ≤ floor \(self.budgetFloor))")
                return nil   // defer under budget pressure
            }
        }

        logger.debug("refresh \(deviceCode, privacy: .public) [\(String(describing: priority), privacy: .public)]: reading")
        let reconciler = self.reconciler
        let task = Task<Device?, Never> {
            @Dependency(\.devicesClient) var devicesClient
            guard let device = try? await devicesClient.read(deviceCode) else { return nil }
            await reconciler.ingest(device)
            return device
        }
        inFlight[deviceCode] = task
        let device = await task.value
        inFlight[deviceCode] = nil

        @Dependency(\.date) var date
        lastReadAt[deviceCode] = date.now
        return device
    }
}
