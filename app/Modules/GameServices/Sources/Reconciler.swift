//
//  Reconciler.swift
//  Replicould — GameServices (shared clients + command engine)
//
//  The correctness core (IMPLEMENTATION_PLAN §6): one guarded write path that
//  every ingestion source funnels through — stream-driven confirm reads and
//  optimistic command dispatch today, the poll coordinator later. It lives in
//  this shared layer (not in `GameSync`) so both `GameSync` and `CommandClient`
//  reach it without a dependency cycle; it is pure logic over the shared
//  `Device`/`Operation` tables and knows nothing about the stream.
//
//  Device snapshots: last-writer-wins by synthesized event-time
//  (`Device.updatedAt`, §4.1) — which is the read's *request-issue* time, so a
//  slow read that started earlier can't overwrite a newer one that landed first.
//  Local-only provenance (`firstSeenAt`) survives every upsert; a stale or
//  duplicate snapshot is a no-op.
//
//  Operations: completion events (e.g. `print.completed`) are treated as truth
//  for the action they close (§4.4) — they carry the result the dispatch
//  response withheld — so they complete the device's open operation directly.
//

import API
import Dependencies
import Foundation
import GameModels
import OSLog
import SQLiteData
import Utils

private let logger = Logger(subsystem: "name.pennig.replicould", category: "Reconciler")

/// What a device event asserts about the device's stowage.
///
/// Deliberately a three-state question (`.stowed` / `.deployed` / no opinion at
/// all, expressed as `nil` by the caller): only `device.stowed` and
/// `device.deployed` speak to stowage, and every other device event must leave
/// the column untouched rather than reading its own silence as "not stowed".
/// Both events name the other end of the link — `stowed_in_device_code` and
/// `deployed_from_device_code` respectively (docs event catalogue, checked
/// 2026-07-26) — which is what makes settling the column from the event alone
/// possible.
public enum StowChange: Equatable, Sendable {
    /// `device.stowed` — the device is now aboard this carrier.
    case stowed(inDeviceCode: String)
    /// `device.deployed` — the device is now standing on its own.
    case deployed
}

public struct Reconciler: Sendable {
    public init() {}

    /// Upsert an authoritative device snapshot under the event-time guard. Drops
    /// the write if what we already have is newer; preserves the stored
    /// `firstSeenAt`.
    public func ingest(_ device: Device) async {
        await ingest([device])
    }

    /// Reconcile a whole walk in ONE transaction. Every `devices` observation is
    /// re-fetched on the writer connection after each commit, so a transaction
    /// per device makes a fleet walk pay for all of them once per device.
    ///
    /// All-or-nothing: a DB failure rolls the walk back and satisfies no
    /// staleness mark, rather than leaving the fleet half-reconciled.
    public func ingest(_ devices: [Device]) async {
        guard !devices.isEmpty else { return }
        @Dependency(\.defaultDatabase) var database
        @Dependency(\.uuid) var uuid
        // A DB failure here is a correctness-core failure — report it
        // (visibly in DEBUG/tests), never swallow it (V3.6-T3).
        let applied = await withErrorReporting {
            try await database.write { (db: Database) -> Void in
                for device in devices { try Self.apply(device, in: db, uuid: { uuid() }) }
            }
        } != nil

        // Spend any staleness mark these snapshots satisfy (V3.5): every
        // successful read funnels through here, so a `.high` confirm, the
        // inspector's viewing loop, or a cold-load walk all clear marks — the
        // drain loop never re-pays for an already-fresh row. The issue-time
        // comparison inside `markSatisfied` keeps a pre-mark snapshot from
        // spending a newer mark. (A dropped-stale write still satisfies: the
        // stored row is even fresher than this snapshot.)
        guard applied else { return }
        @Dependency(\.deviceStaleness) var deviceStaleness
        for device in devices {
            await deviceStaleness.markSatisfied(device.deviceCode, device.updatedAt)
        }
    }

    /// One device's share of a walk, inside the caller's transaction. `uuid` is
    /// a closure so a device with no activity never resolves the dependency —
    /// tests register it only when they expect an operation to be adopted.
    private static func apply(_ device: Device, in db: Database, uuid: () -> UUID) throws {
        let existing = try Device
            .where { $0.deviceCode.eq(device.deviceCode) }
            .fetchOne(db)

        // Guard: never overwrite a row with a read that was *issued* earlier
        // than the one already stored (out-of-order / duplicate arrivals) —
        // its data is same-or-older, so applying it would regress the row.
        if let existing, device.updatedAt < existing.updatedAt {
            logger.debug("ingest \(device.deviceCode, privacy: .public): dropped stale (incoming \(device.updatedAt.ISO8601Format(), privacy: .public) < stored \(existing.updatedAt.ISO8601Format(), privacy: .public))")
            return
        }

        var toWrite = device
        if let existing { toWrite.firstSeenAt = existing.firstSeenAt }
        try Device.upsert { toWrite }.execute(db)
        logger.debug("ingest \(device.deviceCode, privacy: .public): applied status=\(device.status, privacy: .public) loc=\(device.location ?? "-", privacy: .public)")

        // Reconcile the device's open operation against the in-progress
        // activity its snapshot describes. Ops are normally created only by
        // optimistic dispatch, so the reconcile path has to (a) adopt one when
        // the device holds none of its own — a cold-load / relaunch that first
        // meets a device already printing or travelling — and (b) promote a
        // queued op to active once the snapshot shows it has actually started
        // (a dispatched print sits `enqueued` with no deadline until then, so
        // the progress bar can't draw). Both also refresh a slipped deadline.
        if let activity = device.derivedActivity {
            let openOp = try Operation.where {
                $0.entityCode.eq(device.deviceCode) &&
                $0.status.in(OperationStatus.openCases)
            }
            .fetchOne(db)

            switch openOp {
            case nil:
                // Adopt a fresh active op from the snapshot.
                let op = Operation(
                    id: uuid().uuidString,
                    entityCode: device.deviceCode,
                    kind: activity.kind.rawValue,
                    status: .active,
                    source: OperationSource.poll,
                    startedAt: activity.startedAt ?? device.updatedAt,
                    completesAt: activity.completesAt,
                    lastConfirmedAt: device.updatedAt,
                    detail: .object([:])
                )
                try Operation.insert { op }.execute(db)
                logger.info("ingest \(device.deviceCode, privacy: .public): adopted \(activity.kind.rawValue, privacy: .public) op from in-progress snapshot")

            case let op? where op.status != .optimistic
                && op.kind == activity.kind.rawValue
                && activity.completesAt != nil
                && (op.status != .active || op.completesAt != activity.completesAt):
                // The op exists but the snapshot is ahead of it: a queued op
                // that has now started, or a moved deadline. Promote/refresh in
                // place (same id, so the progress bar keeps its identity). An
                // `optimistic` op is left for dispatch to confirm.
                var updated = op
                updated.status = .active
                updated.completesAt = activity.completesAt
                if let startedAt = activity.startedAt { updated.startedAt = startedAt }
                updated.source = OperationSource.poll
                updated.lastConfirmedAt = device.updatedAt
                try Operation.upsert { updated }.execute(db)
                logger.info("ingest \(device.deviceCode, privacy: .public): promoted \(op.kind, privacy: .public) op \(op.id, privacy: .public) to active from in-progress snapshot")

            case let op? where op.status != .optimistic && op.kind != activity.kind.rawValue:
                // The device has moved on to a *different* activity than the
                // open op tracks — the old action finished (we never saw a
                // settled status or completion event, because the device went
                // straight from one timed action into the next) and a new one
                // began. This happens when the transition is server-driven (a
                // recalled survey controller resuming a scan, an AMI directive
                // re-tasking a drone) rather than via local dispatch, which
                // would have superseded the prior op itself. Complete the stale
                // op and adopt the current activity, so the inspector stops
                // showing the finished task and the deadline scheduler tracks
                // the right one instead of re-arming the wrong op to its ETA.
                // An `optimistic` op is left for dispatch to confirm.
                var stale = op
                stale.status = .completed
                stale.source = OperationSource.poll
                stale.lastConfirmedAt = device.updatedAt
                // Complete first so the open-uniqueness index has room for the
                // adopted active op in the same transaction.
                try Operation.upsert { stale }.execute(db)

                let adopted = Operation(
                    id: uuid().uuidString,
                    entityCode: device.deviceCode,
                    kind: activity.kind.rawValue,
                    status: .active,
                    source: OperationSource.poll,
                    startedAt: activity.startedAt ?? device.updatedAt,
                    completesAt: activity.completesAt,
                    lastConfirmedAt: device.updatedAt,
                    detail: .object([:])
                )
                try Operation.insert { adopted }.execute(db)
                logger.info("ingest \(device.deviceCode, privacy: .public): completed stale \(op.kind, privacy: .public) op \(op.id, privacy: .public) and adopted \(activity.kind.rawValue, privacy: .public) from in-progress snapshot")

            default:
                break
            }
        } else if device.isSettled {
            // The device has settled (idle/stowed/inactive): it finished
            // whatever timed action it was running. Close its open
            // deadline-bearing op directly instead of waiting for the deadline
            // timer — this is what completes travel, since arrival events are
            // unreliable as a "done" signal (per-leg arrivals fire on every
            // leg, and a simple single-leg trip may emit *only* a per-leg
            // arrival, never a whole-route `travel.arrived`). It also
            // catches arrivals the server reports before its own ETA estimate.
            // Continuous mining has no deadline (`completesAt == nil`) and is
            // left to its own stop signals; search tracks its site and never
            // settles. Mirrors the DeadlineScheduler's `isSettled → complete`.
            if var op = try Operation.where({
                $0.entityCode.eq(device.deviceCode)
                    && $0.status.eq(OperationStatus.active)
            }).fetchOne(db),
               op.completesAt != nil {
                op.status = .completed
                op.source = OperationSource.poll
                op.lastConfirmedAt = device.updatedAt
                try Operation.upsert { op }.execute(db)
                logger.info("ingest \(device.deviceCode, privacy: .public): device settled (\(device.status, privacy: .public)) — completed \(op.kind, privacy: .public) op \(op.id, privacy: .public)")
            }
        }
    }

    /// Apply the event's location/stow (V3.5 row 2) under a 1s-tolerance
    /// last-writer-wins guard against `device.updatedAt`, stamping
    /// `updatedAt = date.now` (memory: arrival-single-transaction.md).
    @discardableResult
    public func applyEventFields(
        deviceCode: String,
        location: String?,
        stow: StowChange? = nil,
        eventTime: Date?
    ) async -> Bool {
        guard let eventTime else { return false }
        @Dependency(\.defaultDatabase) var database
        @Dependency(\.date) var date
        return await withErrorReporting {
            try await database.write { db -> Bool in
            guard var device = try Device
                .where({ $0.deviceCode.eq(deviceCode) })
                .fetchOne(db)
            else { return false }
            guard eventTime.addingTimeInterval(1) >= device.updatedAt else { return false }
            if device.location != location {
                device.location = location
                // The event carries no display name for the new location; the
                // UI falls back to the mono designation until the next read.
                device.locationName = nil
            }
            // Only the two stowage events say anything here; every other event
            // leaves the column exactly as it was rather than asserting "not
            // stowed" by omission.
            switch stow {
            case let .stowed(carrier): device.stowedInDeviceCode = carrier
            case .deployed: device.stowedInDeviceCode = nil
            case nil: break
            }
            device.updatedAt = date.now
            try Device.upsert { device }.execute(db)
            logger.debug("applyEventFields \(deviceCode, privacy: .public): location=\(location ?? "-", privacy: .public) stow=\(String(describing: stow), privacy: .public) @ \(eventTime.ISO8601Format(), privacy: .public)")
            return true
            }
        } ?? false
    }

    /// One transaction: close the open op the event completes (if any) AND
    /// apply the envelope's location/stow. Returns whether an op was closed.
    @discardableResult
    public func applyDeviceEvent(
        deviceCode: String,
        event: GameEventEnvelope,
        location: String?,
        stow: StowChange?,
        eventTime: Date
    ) async -> Bool {
        @Dependency(\.defaultDatabase) var database
        @Dependency(\.date) var date
        let plan = completionPlan(for: event)
        return await withErrorReporting {
            try await database.write { db -> Bool in
                var closed = false
                if let plan, var op = try Operation.where({
                    $0.entityCode.eq(deviceCode) && $0.status.in(OperationStatus.liveCases)
                }).fetchOne(db),
                   Self.completionMayClose(
                       op, on: deviceCode, eventTime: eventTime,
                       result: plan.result, allowedKinds: plan.allowedKinds
                   ) {
                    if let result = plan.result {
                        var dict: [String: JSONValue] = {
                            if case .object(let existing) = op.detail { return existing }
                            return [:]
                        }()
                        dict["result"] = .object(result)
                        op.detail = .object(dict)
                    }
                    op.status = .completed
                    op.source = .event
                    op.lastConfirmedAt = eventTime
                    try Operation.upsert { op }.execute(db)
                    closed = true
                    logger.info("applyDeviceEvent: completed op \(op.id, privacy: .public) (\(op.kind, privacy: .public)) on \(deviceCode, privacy: .public)")
                }

                guard var device = try Device.where({ $0.deviceCode.eq(deviceCode) }).fetchOne(db)
                else { return closed }
                if !closed {
                    guard eventTime.addingTimeInterval(1) >= device.updatedAt else { return closed }
                }
                if device.location != location {
                    device.location = location
                    device.locationName = nil
                }
                switch stow {
                case let .stowed(carrier): device.stowedInDeviceCode = carrier
                case .deployed: device.stowedInDeviceCode = nil
                case nil: break
                }
                device.updatedAt = date.now
                try Device.upsert { device }.execute(db)
                return closed
            }
        } ?? false
    }

    /// Reconcile the local fleet against an authoritative full device list:
    /// delete any local device whose code is absent from `presentCodes`, along
    /// with its operation rows. Only the full account walk (cold-load / explicit
    /// refresh in `DevicesFeature`) knows the *complete* set the account owns, so
    /// this is the one place a device can leave the fleet — a traded-away or
    /// destroyed device stops being returned by `GET /v1/devices` and is pruned
    /// here. Per-device confirm-reads never carry that "gone" signal, so they must
    /// not call this.
    public func pruneDevices(presentCodes: some Sequence<String>) async {
        @Dependency(\.defaultDatabase) var database
        let kept = Set(presentCodes)
        let pruned = await withErrorReporting {
            try await database.write { db -> [String] in
            let staleCodes = try Device
                .select(\.deviceCode)
                .fetchAll(db)
                .filter { !kept.contains($0) }
            guard !staleCodes.isEmpty else { return [] }
            try Operation.where { $0.entityCode.in(staleCodes) }.delete().execute(db)
            try Device.where { $0.deviceCode.in(staleCodes) }.delete().execute(db)
            logger.info("prune: removed \(staleCodes.count) device(s) absent from full list: \(staleCodes.joined(separator: ", "), privacy: .public)")
            return staleCodes
            }
        } ?? []
        // A pruned device's read can never succeed — drop any staleness mark it
        // holds, or it would cycle through the drain's aged tier forever.
        if !pruned.isEmpty {
            @Dependency(\.deviceStaleness) var deviceStaleness
            await deviceStaleness.forget(Set(pruned))
        }
    }

    /// Apply a stream game-event's effect on the `Operation` table. Completion
    /// event types close the device's open operation and fold their result into
    /// its `detail`; everything else is left to the device confirm-read path.
    ///
    /// Returns whether the event actually closed an open operation, so the caller
    /// can escalate its follow-up device read (a completed activity block should
    /// be re-read authoritatively, not left to a skippable low-priority refresh).
    @discardableResult
    public func applyOperationEvent(_ event: GameEventEnvelope) async -> Bool {
        guard let deviceCode = event.deviceCode, let plan = completionPlan(for: event)
        else { return false }
        return await completeOpenOperation(
            on: deviceCode,
            source: .event,
            eventTime: event.date,
            result: plan.result,
            allowedKinds: plan.allowedKinds
        )
    }

    /// The classification `applyOperationEvent`/`applyDeviceEvent` both close
    /// an op through: which kinds `event` closes, and its result. Nil outside
    /// `completionEvents`, or for a message/bobnet event.
    private func completionPlan(
        for event: GameEventEnvelope
    ) -> (result: [String: JSONValue]?, allowedKinds: Set<String>)? {
        guard
            event.category != "message",
            event.category != "bobnet",
            event.deviceCode != nil,
            let allowedKinds = Self.completionEvents[event.event]
        else { return nil }
        return (event.payload, allowedKinds)
    }

    /// Dotted event names that complete an operation → the operation kinds each
    /// may close, keyed in one place so an evolving taxonomy is a localized edit.
    ///
    /// Travel is completed primarily by the settled-device path (see `ingest`),
    /// not by an arrival event: per-leg arrivals fire on *every* leg and a simple
    /// single-leg trip may emit only a per-leg arrival, so no single arrival name
    /// means "the trip is done." `travel.arrived` (the whole-route arrival) is
    /// kept here only as a snappy fast-path that closes the op without waiting for
    /// the confirm-read; per-leg arrivals fall through to mark the device stale,
    /// and the op-holding drain tier (or the deadline backstop) drives the read
    /// whose settled-device snapshot completes the trip.
    static let completionEvents: [String: Set<String>] = [
        // enqueued print finished (carries the new device code)
        "print.completed": [OperationKind.print.rawValue],
        // whole route finished (multi-leg/interstellar fast-path); a recall is
        // the same cruise shape, homeward
        "travel.arrived": [OperationKind.travel.rawValue, OperationKind.simple("recall").rawValue],
        // mining site exhausted → drone returns to idle
        "site.depleted": [OperationKind.mine.rawValue],
        // survey scan finished — belt search located a site (drone now tracks
        // it) or a body scan completed; both surface the same `scan` block
        "scan.completed": [OperationKind.search.rawValue, OperationKind.surveyScan.rawValue],
    ]

    /// Tolerance when comparing an event's timestamp against an op's
    /// `startedAt` — absorbs client/server clock skew without letting a
    /// genuinely earlier action's completion leak forward.
    static let eventTimeSkewTolerance: TimeInterval = 5

    /// Mark the single open operation on a device completed, recording any event
    /// result (e.g. a print's `new_device_code`) under `detail.result`.
    ///
    /// Which completions may close which op is `completionMayClose`. None of its
    /// guards constrains the poll path (`allowedKinds`, `eventTime` and `result`
    /// all nil), which is therefore the backstop for a declined event.
    ///
    /// Returns whether an open operation was found and closed.
    @discardableResult
    public func completeOpenOperation(
        on deviceCode: String,
        source: OperationSource,
        eventTime: Date?,
        result: [String: JSONValue]?,
        allowedKinds: Set<String>? = nil
    ) async -> Bool {
        @Dependency(\.defaultDatabase) var database
        @Dependency(\.date) var date
        let stamp = eventTime ?? date.now
        return await withErrorReporting {
            try await database.write { db -> Bool in
            guard var op = try Operation.where({
                $0.entityCode.eq(deviceCode)
                    && $0.status.in(OperationStatus.liveCases)
            }).fetchOne(db)
            else { return false }

            guard Self.completionMayClose(
                op, on: deviceCode, eventTime: eventTime,
                result: result, allowedKinds: allowedKinds
            ) else { return false }

            if let result {
                var dict: [String: JSONValue] = {
                    if case .object(let existing) = op.detail { return existing }
                    return [:]
                }()
                dict["result"] = .object(result)
                op.detail = .object(dict)
            }
            op.status = .completed
            op.source = source
            op.lastConfirmedAt = stamp
            try Operation.upsert { op }.execute(db)
            logger.info("completed op \(op.id, privacy: .public) (\(op.kind, privacy: .public)) on \(deviceCode, privacy: .public) via \(source.rawValue, privacy: .public)")
            return true
            }
        } ?? false
    }

    /// Whether this completion may close `op` — one copy for both closing paths.
    /// `applyDeviceEvent` holds the other close, and `GameSync` routes almost
    /// every event through it, so guarding this one alone guards nothing.
    static func completionMayClose(
        _ op: GameModels.Operation,
        on deviceCode: String,
        eventTime: Date?,
        result: [String: JSONValue]?,
        allowedKinds: Set<String>?
    ) -> Bool {
        // A `site.depleted` can never close a travel op.
        if let allowedKinds, !allowedKinds.contains(op.kind) {
            logger.notice("ignored completion on \(deviceCode, privacy: .public): open op is \(op.kind, privacy: .public), event closes \(allowedKinds.sorted().joined(separator: "/"), privacy: .public) — stale/replayed event")
            return false
        }
        // A completion stamped before the op started belongs to an earlier action.
        if let eventTime, eventTime < op.startedAt.addingTimeInterval(-Self.eventTimeSkewTolerance) {
            logger.notice("ignored completion on \(deviceCode, privacy: .public): event time \(eventTime.ISO8601Format(), privacy: .public) predates op start \(op.startedAt.ISO8601Format(), privacy: .public) — stale/replayed event")
            return false
        }
        // A bench runs a queue deeper than the one op this table holds for it, so
        // a result of another type is another job of that queue finishing.
        if let wanted = op.detail["params"]?["device_type"]?.stringValue,
           let produced = result?["device_type"]?.stringValue,
           wanted != produced
        {
            logger.notice("ignored completion on \(deviceCode, privacy: .public): open op asked for \(wanted, privacy: .public), event produced \(produced, privacy: .public) — another job on this bench")
            return false
        }
        return true
    }
}
