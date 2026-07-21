//
//  StalenessTracker.swift
//  Replicould — GameServices (shared clients + command engine)
//
//  The device-side half of the V3.5 staleness model. Today's event policy was
//  binary — read-now or forget — so every thin device event paid an immediate
//  (if TTL'd) read, catch-up replays paid full price, and a suppressed refresh
//  was forgotten rather than remembered. This actor is the memory: the device
//  route *marks* a device stale (free), and the marks are spent as reads only
//  where they matter —
//
//    • a visible (inspected) device drains promptly, so the on-screen row keeps
//      its live feel;
//    • op-holding devices drain on the slow loop, so an operation's row can't
//      quietly rot between deadline confirmations;
//    • everything else stays marked at zero cost until it's actually looked at
//      (`refreshIfStale`, wired to the inspector's selection path).
//
//  Draining goes through `deviceRefresher.refresh(_, .low)`, so the
//  coordinator's coalescing, TTL, and budget floor all still apply — a mark is
//  cleared only when a read actually landed, and a deferred read simply keeps
//  its mark for the next pass. Exposed via `@Dependency(\.deviceStaleness)`
//  over one process-shared instance; the sync engine starts/stops the drain
//  loop with the session.
//

import ComposableArchitecture
import Foundation
import GameModels
import OSLog
import SQLiteData

private let logger = Logger(subsystem: "name.pennig.replicould", category: "Staleness")

public actor StalenessTracker {
    struct Mark: Sendable {
        /// When the device FIRST went stale — the aged-tier's age gate. Never
        /// re-stamped: a busy hidden device that keeps re-marking must still
        /// age into the slow tier, or its row would stay stale for the whole
        /// duration of a ticking server-driven activity.
        var firstMarkedAt: Date
        /// When the device most recently went stale — the `markSatisfied`
        /// guard. Re-stamped on every event so a pre-event snapshot can't
        /// spend the mark.
        var markedAt: Date
        /// When the aged tier last spent a read on this mark — paces retries
        /// for a mark whose device can't be read (destroyed/traded away), so
        /// it can't hog the tier's single slot every pass.
        var lastAgedAttemptAt: Date?
        var reason: String
    }

    private var stale: [String: Mark] = [:]
    /// The device codes some view is actively presenting (today: the Devices
    /// inspector's selection). Marks for these drain promptly.
    private var visible: Set<String> = []
    private var drainTask: Task<Void, Never>?
    /// Bumped by `stopDraining`; an in-flight drain re-checks it between reads
    /// so logout can't be followed by reads on the old session's behalf.
    private var generation = 0
    /// Cadence of the periodic drain pass (visible + op-holding candidates).
    private let drainInterval: Duration
    /// Cap on reads spent per drain pass, so a big burst of marks smooths out
    /// over passes instead of spiking (each read is additionally TTL/budget
    /// guarded by the coordinator).
    private let maxPerPass: Int
    /// Minimum age before a hidden, op-less mark qualifies for the slow drain
    /// tier (see `drainPass`).
    private let hiddenMarkDrainAge: TimeInterval
    /// Minimum spacing between aged-tier attempts for the SAME mark, so one
    /// unreadable device can't monopolize the tier (other aged marks take the
    /// slot in between).
    private let agedRetryBackoff: TimeInterval

    public init(
        drainInterval: Duration = .seconds(5),
        maxPerPass: Int = 4,
        hiddenMarkDrainAge: TimeInterval = 30,
        agedRetryBackoff: TimeInterval = 60
    ) {
        self.drainInterval = drainInterval
        self.maxPerPass = maxPerPass
        self.hiddenMarkDrainAge = hiddenMarkDrainAge
        self.agedRetryBackoff = agedRetryBackoff
    }

    /// Remember that `deviceCode`'s row may be stale. Free — no read happens
    /// here; a visible device gets a prompt drain pass, everything else waits
    /// for the loop, the aged-mark tier, or a `refreshIfStale`.
    ///
    /// Re-marking always re-stamps `markedAt`: `markSatisfied` clears a mark
    /// only against a read issued at-or-after that stamp, so an event landing
    /// *during* an in-flight read can't have its mark spent by the pre-event
    /// snapshot that read returns.
    public func markStale(_ deviceCode: String, reason: String) {
        @Dependency(\.date) var date
        let now = date.now
        if var mark = stale[deviceCode] {
            mark.markedAt = now
            mark.reason = reason
            stale[deviceCode] = mark
        } else {
            stale[deviceCode] = Mark(firstMarkedAt: now, markedAt: now, lastAgedAttemptAt: nil, reason: reason)
        }
        logger.debug("marked \(deviceCode, privacy: .public) stale (\(reason, privacy: .public))")
        if visible.contains(deviceCode) {
            drainSoon()
        }
    }

    /// Forget marks for devices that left the fleet (called alongside
    /// `Reconciler.pruneDevices`): their reads can never succeed, so their
    /// marks would otherwise cycle through the aged tier forever.
    public func forget(_ deviceCodes: Set<String>) {
        for code in deviceCodes {
            stale[code] = nil
        }
    }

    /// An authoritative snapshot issued at `asOf` landed for this device
    /// (called by `Reconciler.ingest`, which every successful read funnels
    /// through). Spend the mark iff the read was issued at-or-after it — a
    /// snapshot from *before* the mark doesn't contain whatever the mark's
    /// event changed. Centralizing spending here means a `.high` confirm-read,
    /// the inspector's viewing loop, or a cold-load walk all satisfy marks for
    /// free, and the drain loop never re-pays for an already-fresh row.
    public func markSatisfied(_ deviceCode: String, asOf issuedAt: Date) {
        guard let mark = stale[deviceCode], mark.markedAt <= issuedAt else { return }
        stale[deviceCode] = nil
        logger.debug("mark spent for \(deviceCode, privacy: .public)")
    }

    /// Replace the visible set (the inspector's current selection); any stale
    /// mark that just became visible drains promptly.
    public func setVisible(_ deviceCodes: Set<String>) {
        visible = deviceCodes
        if deviceCodes.contains(where: { stale[$0] != nil }) {
            drainSoon()
        }
    }

    /// Spend the mark for one device now, if it has one — the on-demand entry
    /// for "the user is looking at this row". No mark → no read.
    public func refreshIfStale(_ deviceCode: String) async {
        guard stale[deviceCode] != nil else { return }
        await drain([deviceCode])
    }

    /// Start the periodic drain loop. Idempotent, and refuses a cancelled
    /// caller (the engine arms it from inside its consume task, mirroring
    /// `DeadlineScheduler.start`).
    public func startDraining() {
        guard !Task.isCancelled, drainTask == nil else { return }
        drainTask = Task { [weak self] in
            @Dependency(\.continuousClock) var clock
            while !Task.isCancelled {
                await self?.drainPass()
                try? await clock.sleep(for: self?.drainInterval ?? .seconds(5))
            }
        }
    }

    /// Stop the loop and forget every mark and the visible set (logout: marks
    /// are account-scoped, and nothing may read on the old session's behalf).
    public func stopDraining() {
        // Invalidate any in-flight drain: its next iteration checks the
        // generation and stops issuing reads on the old session's behalf. (A
        // single already-issued read can still land — the same bounded
        // exposure as any confirm-read in flight at logout.)
        generation += 1
        drainTask?.cancel()
        drainTask = nil
        stale.removeAll()
        visible.removeAll()
    }

    /// One drain pass: spend marks as low-priority reads for the candidates
    /// that matter now — visible first, then op-holding — FIFO within each
    /// group, capped per pass. Non-visible devices holding no operation drain
    /// on a deliberately slow third tier: at most ONE sufficiently aged mark
    /// per pass, so a hidden device's one-shot transition (a server-driven
    /// re-task with no follow-up event) still converges eventually without a
    /// burst of hidden events ever competing with the budget. Fresh hidden
    /// marks cost nothing.
    func drainPass() async {
        guard !stale.isEmpty else { return }

        let visibleCandidates = stale
            .filter { visible.contains($0.key) }
            .sorted { $0.value.markedAt < $1.value.markedAt }
            .map(\.key)

        // Devices with an open operation: their activity row is live UI
        // (progress, deadline) wherever it appears, so a stale mark there is
        // worth a budgeted read even off-screen.
        @Dependency(\.defaultDatabase) var database
        let opCodes: Set<String> = await {
            let open = (try? await database.read { db in
                try Operation
                    .where { $0.status.in(OperationStatus.liveCases) }
                    .select(\.entityCode)
                    .fetchAll(db)
            }) ?? []
            return Set(open)
        }()
        let opHolding = stale
            .filter { opCodes.contains($0.key) && !visible.contains($0.key) }
            .sorted { $0.value.markedAt < $1.value.markedAt }
            .map(\.key)

        var candidates = Array((visibleCandidates + opHolding).prefix(maxPerPass))

        // Slow tier: the single oldest hidden idle mark past the age gate
        // (first-marked, NOT last-marked — a busy device must still age in)
        // that hasn't been attempted within the retry backoff (an unreadable
        // device's mark yields the slot to the next-oldest between attempts).
        if candidates.count < maxPerPass {
            @Dependency(\.date) var date
            let now = date.now
            let aged = stale
                .filter { !visible.contains($0.key) && !opCodes.contains($0.key) }
                .filter { now.timeIntervalSince($0.value.firstMarkedAt) >= hiddenMarkDrainAge }
                .filter { entry in
                    entry.value.lastAgedAttemptAt.map { now.timeIntervalSince($0) >= agedRetryBackoff } ?? true
                }
                .min { $0.value.firstMarkedAt < $1.value.firstMarkedAt }
            if let aged {
                stale[aged.key]?.lastAgedAttemptAt = now
                candidates.append(aged.key)
            }
        }

        guard !candidates.isEmpty else { return }
        await drain(candidates)
    }

    /// Refresh each candidate through the coordinator. Marks are spent by
    /// `Reconciler.ingest` → `markSatisfied` when a read actually lands, so a
    /// suppressed/deferred/failed read keeps its mark for a later pass with no
    /// bookkeeping here.
    private func drain(_ deviceCodes: [String]) async {
        @Dependency(\.deviceRefresher) var deviceRefresher
        let entryGeneration = generation
        for code in deviceCodes {
            // A logout (stopDraining) between reads must not keep spending.
            guard generation == entryGeneration else { return }
            _ = await deviceRefresher.refresh(code, .low)
        }
    }

    /// An immediate off-cadence pass (a mark became visible); the actor
    /// serializes it against the loop's own passes, and the coordinator's
    /// TTL/coalescing absorbs any overlap.
    private func drainSoon() {
        Task { await self.drainPass() }
    }
}

/// Disambiguate from `Foundation.Operation`.
private typealias Operation = GameModels.Operation

// MARK: - Dependency

public struct DeviceStalenessClient: Sendable {
    /// Remember that a device's row may be stale (free; spent later).
    public var markStale: @Sendable (_ deviceCode: String, _ reason: String) async -> Void
    /// A successful authoritative snapshot issued at the given time landed —
    /// spend the mark if the read postdates it (called by `Reconciler.ingest`).
    public var markSatisfied: @Sendable (_ deviceCode: String, _ issuedAt: Date) async -> Void
    /// Forget marks for devices pruned from the fleet — their reads can never
    /// succeed (called by `Reconciler.pruneDevices`).
    public var forget: @Sendable (_ deviceCodes: Set<String>) async -> Void
    /// Replace the set of device codes some view is actively presenting.
    public var setVisible: @Sendable (_ deviceCodes: Set<String>) async -> Void
    /// Spend one device's mark now, if it has one.
    public var refreshIfStale: @Sendable (_ deviceCode: String) async -> Void
    /// Start/stop the periodic drain loop (session lifecycle; stop forgets
    /// every mark).
    public var startDraining: @Sendable () async -> Void
    public var stopDraining: @Sendable () async -> Void
}

extension DeviceStalenessClient: DependencyKey {
    /// One process-shared tracker, mirroring `DeviceRefreshClient`'s single
    /// coordinator (the drain loop and the marks must agree).
    public static let liveValue: DeviceStalenessClient = {
        let tracker = StalenessTracker()
        return DeviceStalenessClient(
            markStale: { await tracker.markStale($0, reason: $1) },
            markSatisfied: { await tracker.markSatisfied($0, asOf: $1) },
            forget: { await tracker.forget($0) },
            setVisible: { await tracker.setVisible($0) },
            refreshIfStale: { await tracker.refreshIfStale($0) },
            startDraining: { await tracker.startDraining() },
            stopDraining: { await tracker.stopDraining() }
        )
    }()
}

extension DeviceStalenessClient: TestDependencyKey {
    /// Inert by default: routing tests spy on `markStale` explicitly; features
    /// that never touch staleness shouldn't have to stub it.
    public static let testValue = DeviceStalenessClient(
        markStale: { _, _ in },
        markSatisfied: { _, _ in },
        forget: { _ in },
        setVisible: { _ in },
        refreshIfStale: { _ in },
        startDraining: {},
        stopDraining: {}
    )
}

extension DependencyValues {
    public var deviceStaleness: DeviceStalenessClient {
        get { self[DeviceStalenessClient.self] }
        set { self[DeviceStalenessClient.self] = newValue }
    }
}
