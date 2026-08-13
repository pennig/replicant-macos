//
//  DeadlineScheduler.swift
//  Replicould — GameSync
//
//  The backstop that completes self-describing actions when their stream event is
//  lost (IMPLEMENTATION_PLAN §5.4 / Phase 4). It watches open `active` ops that
//  carry a `completesAt`, sleeps until the earliest one, and on the deadline
//  takes one high-priority confirm-read (via the poll coordinator) and closes
//  the op — unless a stream completion event already did, in which case the op is
//  no longer open and nothing happens (no wasted read).
//
//  Enqueued ops with no deadline are intentionally skipped here; their
//  completion arrives as a stream event (e.g. `print.completed`).
//
//  One exception has its own slow backstop: **continuous** mining ops also carry
//  no deadline (they run until stopped), so they're absent from the deadline
//  queue too — but their stop event (`site_resource_depleted`) can be lost,
//  which would leave the op open forever. `sweepContinuousOps` gives them a
//  throttled, low-priority "is the device idle yet?" check so a silently-settled
//  mine eventually closes without ever polling a still-running one hard.
//

import Dependencies
import Foundation
import GameModels
import GameServices
import OSLog
import SQLiteData

private let logger = Logger(subsystem: "name.pennig.replicould", category: "DeadlineScheduler")

/// Disambiguate from `Foundation.Operation`.
private typealias Operation = GameModels.Operation

actor DeadlineScheduler {
    private let reconciler: Reconciler
    /// Upper bound on a single sleep, so ops inserted after the current sleep
    /// began are still picked up promptly.
    private let cap: Duration

    private var loopTask: Task<Void, Never>?

    /// Wait this much *past* a deadline before the confirm-read, so the common
    /// case lands after the server has actually settled the action — sparing a
    /// re-arm round-trip. `completesAt` stays the honest server ETA (the progress
    /// bar reaches 100% on time); only the confirm is nudged a beat later.
    private let confirmGrace: TimeInterval
    /// Minimum spacing between re-poll attempts once a deadline has passed but
    /// the device is still working (so a slipped estimate doesn't busy-loop).
    private let rearmBackoff: TimeInterval
    /// How long past the first *unanswered* deadline to keep polling a
    /// still-busy op before giving up and marking it `unknown` (a truly stuck
    /// backend, not a small skew). Measured from when the deadline went overdue
    /// — NOT from `startedAt`: a long op's total runtime says nothing about
    /// whether it's stuck, and measuring from dispatch marked every op longer
    /// than this window `unknown` on its first slipped estimate (V3.3-S3).
    private let giveUpAfter: TimeInterval
    /// op id → the deadline that first went overdue without the device offering
    /// a fresh forward ETA. Give-up is measured from here; cleared whenever the
    /// op settles, closes, or the server supplies a genuinely later estimate.
    /// In-memory on purpose: after a relaunch a stuck op simply earns a fresh
    /// give-up window, which only delays the `unknown` verdict.
    private var overdueSince: [String: Date] = [:]
    /// Minimum spacing between continuous-op backstop sweeps (mining). Slow on
    /// purpose — a running mine that legitimately continues shouldn't be polled
    /// hard; this only needs to eventually notice a *settled* one.
    private let continuousSweepInterval: TimeInterval
    /// When the last continuous-op sweep ran, so `run()` throttles them.
    private var lastContinuousSweepAt: Date?
    /// Minimum spacing between retention sweeps over the `operations` table.
    /// Housekeeping rides this loop because it is the only periodic one in
    /// GameSync and retention needs no timeliness whatsoever — hourly is
    /// already far more often than a 7-day window requires.
    private let retentionSweepInterval: TimeInterval
    /// When the last retention sweep ran, so `run()` throttles them.
    private var lastRetentionSweepAt: Date?
    /// Minimum spacing between per-type depot stock reads.
    private let depotInventoryInterval: TimeInterval = 3600
    private var lastDepotInventoryAt: Date?
    /// Minimum spacing between blueprint catalog refreshes.
    private let blueprintCatalogInterval: TimeInterval = 3600
    private var lastBlueprintCatalogAt: Date?

    init(
        reconciler: Reconciler,
        cap: Duration = .seconds(30),
        confirmGrace: TimeInterval = 1,
        rearmBackoff: TimeInterval = 4,
        giveUpAfter: TimeInterval = 5 * 60,
        continuousSweepInterval: TimeInterval = 2 * 60,
        retentionSweepInterval: TimeInterval = 60 * 60
    ) {
        self.reconciler = reconciler
        self.cap = cap
        self.confirmGrace = confirmGrace
        self.rearmBackoff = rearmBackoff
        self.giveUpAfter = giveUpAfter
        self.continuousSweepInterval = continuousSweepInterval
        self.retentionSweepInterval = retentionSweepInterval
    }

    func start() {
        // Refuse a cancelled caller: the engine arms the scheduler from inside
        // its consume task, so a stop() that already cancelled that task must
        // not be followed by a fresh loop arming out of order.
        guard !Task.isCancelled, loopTask == nil else { return }
        loopTask = Task { await run() }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
        overdueSince.removeAll()
    }

    private func run() async {
        @Dependency(\.continuousClock) var clock
        @Dependency(\.date) var date
        while !Task.isCancelled {
            let now = date.now
            await processDue(now: now)

            // Throttled backstop for deadline-less continuous ops (mining).
            if lastContinuousSweepAt.map({ now.timeIntervalSince($0) >= continuousSweepInterval }) ?? true {
                lastContinuousSweepAt = now
                await sweepContinuousOps(now: now)
            }

            // Housekeeping: age finished rows out of tables nothing else prunes.
            if lastRetentionSweepAt.map({ now.timeIntervalSince($0) >= retentionSweepInterval }) ?? true {
                lastRetentionSweepAt = now
                @Dependency(\.defaultDatabase) var database
                await OperationRetention.sweep(database, now: now)
                await DirectiveLogRetention.sweep(database, now: now)
                await DirectiveRetention.sweep(database, now: now)
            }

            if Self.depotInventoryDue(lastAt: lastDepotInventoryAt, now: now, interval: depotInventoryInterval) {
                lastDepotInventoryAt = now
                await refreshDepotInventories()
            }

            if Self.blueprintCatalogDue(lastAt: lastBlueprintCatalogAt, now: now, interval: blueprintCatalogInterval) {
                lastBlueprintCatalogAt = now
                await refreshBlueprintCatalog()
            }

            let upcoming = await openDatedOps()
                .compactMap(\.completesAt)
                .filter { $0 > now }
                .min()
            // Wake a grace beat past the ETA so the confirm-read usually finds the
            // action already settled (no re-arm needed).
            let delay: Duration = upcoming.map { .seconds(max(0, $0.timeIntervalSince(now) + confirmGrace)) } ?? cap
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
    ///   • overdue past the give-up window with no forward ETA → mark `unknown`.
    func processDue(now: Date) async {
        @Dependency(\.defaultDatabase) var database
        @Dependency(\.deviceRefresher) var deviceRefresher

        let dueOps = await openDatedOps()
        // Drop give-up tracking for ops that left the active set *between*
        // passes (closed by an event, superseded, pruned) — op ids are never
        // reused, so stale entries would otherwise accrete for the session.
        let liveIDs = Set(dueOps.map(\.id))
        overdueSince = overdueSince.filter { liveIDs.contains($0.key) }

        for due in dueOps where (due.completesAt ?? .distantFuture) <= now {
            logger.info("deadline reached for op \(due.id, privacy: .public) (\(due.kind, privacy: .public)) on \(due.entityCode, privacy: .public) — confirming")
            _ = await deviceRefresher.refresh(due.entityCode, .high)

            // A stream completion event may have closed it during the read.
            guard
                let op = try? await database.read({ db in
                    try Operation.where { $0.id.eq(due.id) }.fetchOne(db)
                }),
                op.status == .active
            else { continue }   // closed mid-pass; the next pass's sweep untracks it

            let device = try? await database.read { db in
                try Device.where { $0.deviceCode.eq(op.entityCode) }.fetchOne(db)
            }

            if let device, device.isSettled {
                logger.info("op \(op.id, privacy: .public): device settled (\(device.status, privacy: .public)) — completing")
                overdueSince[op.id] = nil
                await reconciler.completeOpenOperation(on: op.entityCode, source: .poll, eventTime: nil, result: nil)
            } else if let freshETA = device?.activityDeadline, freshETA > now.addingTimeInterval(rearmBackoff) {
                // The server supplied a genuinely later estimate — the action is
                // progressing, not stuck. Re-arm to it and restart give-up
                // tracking from the new deadline.
                overdueSince[op.id] = nil
                logger.info("op \(op.id, privacy: .public): still executing — re-armed to fresh ETA \(freshETA.ISO8601Format(), privacy: .public)")
                await rearm(op.id, to: freshETA, at: now)
            } else {
                // Overdue with no forward estimate. Poll on the backoff until the
                // give-up window — measured from the deadline that first went
                // unanswered — expires; only then concede `unknown`.
                let since = overdueSince[op.id] ?? due.completesAt ?? now
                overdueSince[op.id] = since
                if now.timeIntervalSince(since) > giveUpAfter {
                    logger.error("op \(op.id, privacy: .public): still busy \(Int(now.timeIntervalSince(since)))s past its deadline with no fresh ETA — marking unknown")
                    overdueSince[op.id] = nil
                    await setStatus(op.id, to: .unknown, at: now)
                } else {
                    let next = now.addingTimeInterval(rearmBackoff)
                    logger.info("op \(op.id, privacy: .public): still executing — re-armed to backoff \(next.ISO8601Format(), privacy: .public)")
                    await rearm(op.id, to: next, at: now)
                }
            }
        }
    }

    /// Best-effort backstop for **continuous** ops (mining): active operations
    /// with no `completesAt`, which never enter the deadline queue. If their stop
    /// event (`site_resource_depleted`) is lost, the op would linger open. On the
    /// throttled cadence, low-priority confirm-read each and complete any whose
    /// device has settled to idle — the mine is over. Bounded by the slow
    /// interval + `.low` priority (TTL-suppressed / budget-deferred), so a mine
    /// that legitimately keeps running costs almost nothing. Extracted (like
    /// `processDue`) so it's testable without the sleep loop.
    func sweepContinuousOps(now: Date) async {
        @Dependency(\.defaultDatabase) var database
        @Dependency(\.deviceRefresher) var deviceRefresher

        let active = (try? await database.read { db in
            try Operation.where { $0.status.eq(OperationStatus.active) }.fetchAll(db)
        }) ?? []
        let ops = active.filter { $0.completesAt == nil && $0.kind == OperationKind.mine.rawValue }
        guard !ops.isEmpty else { return }

        for op in ops {
            _ = await deviceRefresher.refresh(op.entityCode, .low)
            let device = try? await database.read { db in
                try Device.where { $0.deviceCode.eq(op.entityCode) }.fetchOne(db)
            }
            // `Reconciler.ingest` deliberately leaves a settled device's
            // deadline-less op open (continuous ops own their stop signal), so
            // completing it here is the backstop for a lost stop event.
            if let device, device.isSettled {
                logger.info("continuous op \(op.id, privacy: .public) (\(op.kind, privacy: .public)) on \(op.entityCode, privacy: .public): device settled (\(device.status, privacy: .public)) — completing (stop event lost)")
                await reconciler.completeOpenOperation(on: op.entityCode, source: .poll, eventTime: nil, result: nil)
            }
        }
    }

    /// The depot locations worth a per-type stock read: where a print-capable
    /// device stands. A stowed one carries no location and is skipped.
    nonisolated static func depotLocations(in devices: [Device]) -> [String] {
        Array(Set(devices.filter(\.isPrintHub).compactMap(\.location))).sorted()
    }

    /// Whether `run()`'s hourly depot sweep is due: never run yet, or spaced
    /// at least `interval` past its last run.
    nonisolated static func depotInventoryDue(lastAt: Date?, now: Date, interval: TimeInterval) -> Bool {
        lastAt.map { now.timeIntervalSince($0) >= interval } ?? true
    }

    /// One per-type stock read per depot, hourly. The planner degrades to its
    /// static weights when these rows age, so a skipped round costs efficiency
    /// and never correctness.
    func refreshDepotInventories() async {
        @Dependency(\.defaultDatabase) var database
        @Dependency(\.locationsClient) var locationsClient
        guard let devices = try? await database.read({ db in try Device.all.fetchAll(db) })
        else { return }
        let depots = Self.depotLocations(in: devices)
        guard !depots.isEmpty else { return }
        logger.debug("depot stock: refreshing \(depots.count, privacy: .public) depot(s)")
        await locationsClient.refreshDepotInventories(depots)
    }

    /// Whether `run()`'s hourly blueprint catalog refresh is due: never run
    /// yet, or spaced at least `interval` past its last run.
    nonisolated static func blueprintCatalogDue(lastAt: Date?, now: Date, interval: TimeInterval) -> Bool {
        lastAt.map { now.timeIntervalSince($0) >= interval } ?? true
    }

    /// One request for the full unlocked catalog, hourly. The brain's demand
    /// pricing degrades to zero-priced device demand when this table is empty,
    /// so a skipped round costs efficiency and never correctness.
    func refreshBlueprintCatalog() async {
        @Dependency(\.defaultDatabase) var database
        @Dependency(\.blueprintsClient) var blueprintsClient
        guard let blueprints = try? await blueprintsClient.fetchAll() else { return }
        try? await database.write { db in
            try Blueprint.upsert { blueprints }.execute(db)
        }
        logger.debug("blueprint catalog: refreshed \(blueprints.count, privacy: .public) blueprint(s)")
    }

    /// Open (`active`) operations that carry a completion deadline.
    private func openDatedOps() async -> [Operation] {
        @Dependency(\.defaultDatabase) var database
        let active = (try? await database.read { db in
            try Operation.where { $0.status.eq(OperationStatus.active) }.fetchAll(db)
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
            op.source = OperationSource.poll
            try Operation.upsert { op }.execute(db)
        }
    }

    private func setStatus(_ id: String, to status: OperationStatus, at now: Date) async {
        @Dependency(\.defaultDatabase) var database
        try? await database.write { db in
            guard var op = try Operation.where({ $0.id.eq(id) }).fetchOne(db) else { return }
            op.status = status
            op.lastConfirmedAt = now
            op.source = OperationSource.poll
            try Operation.upsert { op }.execute(db)
        }
    }
}
