//
//  PollCoordinator.swift
//  Replicould — GameServices (shared clients + command engine)
//
//  Spends the read budget where it matters (IMPLEMENTATION_PLAN §4.3 / Phase 4).
//  Every device confirm-read — whether triggered by a stream event or by a
//  deadline — funnels through here so a burst of triggers collapses into the
//  fewest authoritative reads:
//
//    • Coalescing: a read already in flight for a device is shared rather than
//      duplicated — except that a `.high` refresh only joins a read issued
//      at-or-after its own request time (a post-command confirm must not adopt
//      a pre-command snapshot; it waits the stale read out and re-reads).
//    • TTL: a device read very recently is not re-read for low-priority
//      (event-invalidation) triggers.
//    • Budget-aware deferral: under read-budget pressure (Phase-0 snapshot),
//      low-priority refreshes are skipped — a deadline (high priority) or a
//      later event will catch the row up.
//
//  An actor so the in-flight map and last-read timestamps stay consistent under
//  concurrent triggers.
//

import Dependencies
import Foundation
import GameModels
import GameSession
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

    private var inFlight: [String: (issuedAt: Date, seq: Int, task: Task<Device?, Never>)] = [:]
    private var lastReadAt: [String: Date] = [:]
    /// Monotonic tag for in-flight entries, so a read's cleanup can tell "my
    /// entry" from a successor's that replaced it (see the `.high` barrier).
    private var readSeq = 0
    /// How many times a `.high` refresh declined a stale in-flight join and
    /// waited it out. Internal so tests can await the barrier deterministically.
    private(set) var barrierWaits = 0

    /// Where low-priority reads start being deferred. Surfaced through
    /// `DeviceRefreshClient.readFloor` so the brain's why-view can state the
    /// number this coordinator enforces rather than a literal that could drift.
    static let defaultBudgetFloor = 12

    init(reconciler: Reconciler, ttl: TimeInterval = 2, budgetFloor: Int = PollCoordinator.defaultBudgetFloor) {
        self.reconciler = reconciler
        self.ttl = ttl
        self.budgetFloor = budgetFloor
    }

    /// Refresh a device's authoritative snapshot, subject to coalescing, TTL, and
    /// budget. Returns the device if a read happened (or one was already in
    /// flight), or nil if the refresh was coalesced-away / suppressed / deferred.
    @discardableResult
    func refresh(_ deviceCode: String, priority: RefreshPriority) async -> Device? {
        @Dependency(\.date) var date
        let requestedAt = date.now

        // Join an in-flight read rather than firing a second — with one guard: a
        // `.high` refresh demands state as of *its own request time* (it follows
        // a command POST / a deadline), so it may only join a read issued
        // at-or-after that moment. Joining an *earlier* read — say the
        // inspector's poll that began just before a command was accepted — would
        // reconcile a pre-command snapshot, stamp the TTL, and suppress the SSE
        // echo that should have repaired it: the row would show stale state with
        // its repair path closed. `.low` is a mere invalidation hint, so any
        // in-flight read satisfies it.
        if let existing = inFlight[deviceCode] {
            if priority == .low || existing.issuedAt >= requestedAt {
                logger.debug("refresh \(deviceCode, privacy: .public) [\(String(describing: priority), privacy: .public)]: coalesced into in-flight read")
                return await existing.task.value
            }
            // Wait the stale read out (its response would race ours anyway)…
            logger.debug("refresh \(deviceCode, privacy: .public) [high]: in-flight read predates request — waiting it out, then re-reading")
            barrierWaits += 1
            _ = await existing.task.value
            // …then join a successor started while we waited, if it's fresh
            // enough; otherwise fall through and read for ourselves. One
            // re-check, deliberately not a loop: awaiting an already-finished
            // task resumes without suspending, so a re-check loop could hold
            // the actor and starve the very cleanup it waits on.
            if let successor = inFlight[deviceCode], successor.issuedAt >= requestedAt {
                return await successor.task.value
            }
        }

        if priority == .low {
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
        readSeq += 1
        let seq = readSeq
        // May overwrite a completed read's not-yet-cleaned entry (the barrier
        // fall-through above); the seq guard below keeps that read's cleanup
        // from clobbering this fresh entry in return.
        inFlight[deviceCode] = (issuedAt: date.now, seq: seq, task: task)
        let device = await task.value
        if inFlight[deviceCode]?.seq == seq {
            inFlight[deviceCode] = nil
            // Stamp the TTL only when the read *succeeded* — a failed read that
            // stamped it would TTL-suppress the very SSE-echo refresh that could
            // repair the miss, leaving the row stale with no near-term retry.
            // A superseded read (a `.high` barrier replaced this entry) defers
            // the stamp to its successor for the same reason: its snapshot may
            // be pre-command, and the successor stamps iff it succeeded.
            if device != nil {
                lastReadAt[deviceCode] = date.now
            }
        }
        return device
    }
}
