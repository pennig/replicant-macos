//
//  Reconciler.swift
//  Replicould — shared dependency clients
//
//  The correctness core (IMPLEMENTATION_PLAN §6): one guarded write path that
//  every ingestion source funnels through — relay-driven confirm reads and
//  optimistic command dispatch today, the poll coordinator later. It lives in
//  this shared layer (not in `GameSync`) so both `GameSync` and `CommandClient`
//  reach it without a dependency cycle; it is pure logic over the shared
//  `Device`/`Operation` tables and knows nothing about the relay.
//
//  Device snapshots: last-writer-wins by synthesized event-time
//  (`Device.updatedAt`, §4.1) — which is the read's *request-issue* time, so a
//  slow read that started earlier can't overwrite a newer one that landed first.
//  Local-only provenance (`firstSeenAt`) survives every upsert; a stale or
//  duplicate snapshot is a no-op.
//
//  Operations: completion events (e.g. `print_complete`) are treated as truth
//  for the action they close (§4.4) — they carry the result the dispatch
//  response withheld — so they complete the device's open operation directly.
//

import API
import ComposableArchitecture
import Foundation
import GameModels
import OSLog
import SQLiteData
import Utils

private let logger = Logger(subsystem: "name.pennig.replicould", category: "Reconciler")

public struct Reconciler: Sendable {
    public init() {}

    /// Upsert an authoritative device snapshot under the event-time guard. Drops
    /// the write if what we already have is newer; preserves the stored
    /// `firstSeenAt`.
    public func ingest(_ device: Device) async {
        @Dependency(\.defaultDatabase) var database
        @Dependency(\.uuid) var uuid
        try? await database.write { db in
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
                // unreliable as a "done" signal (per-leg `device_cruise_arrived`
                // fires on every leg, and a simple single-leg trip emits *only*
                // that, never a whole-route `device_travel_arrived`). It also
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
    }

    /// Reconcile the local fleet against an authoritative full device list:
    /// delete any local device whose code is absent from `presentCodes`, along
    /// with its operation rows. Only the full account walk (cold-load / explicit
    /// refresh in `DevicesFeature`) knows the *complete* set the account owns, so
    /// this is the one place a device can leave the fleet — a traded-away or
    /// destroyed device stops being returned by `GET /v1/devices` and is pruned
    /// here. Per-device relay reads never carry that "gone" signal, so they must
    /// not call this.
    public func pruneDevices(presentCodes: some Sequence<String>) async {
        @Dependency(\.defaultDatabase) var database
        let kept = Set(presentCodes)
        try? await database.write { db in
            let staleCodes = try Device
                .select(\.deviceCode)
                .fetchAll(db)
                .filter { !kept.contains($0) }
            guard !staleCodes.isEmpty else { return }
            try Operation.where { $0.entityCode.in(staleCodes) }.delete().execute(db)
            try Device.where { $0.deviceCode.in(staleCodes) }.delete().execute(db)
            logger.info("prune: removed \(staleCodes.count) device(s) absent from full list: \(staleCodes.joined(separator: ", "), privacy: .public)")
        }
    }

    /// Apply a relay game-event's effect on the `Operation` table. Completion
    /// event types close the device's open operation and fold their result into
    /// its `detail`; everything else is left to the device confirm-read path.
    ///
    /// Returns whether the event actually closed an open operation, so the caller
    /// can escalate its follow-up device read (a completed activity block should
    /// be re-read authoritatively, not left to a skippable low-priority refresh).
    @discardableResult
    public func applyOperationEvent(_ event: UnifiedEvent) async -> Bool {
        guard
            event.type == "event",
            let deviceCode = event.deviceCode,
            let eventType = event.eventType
        else { return false }

        // Event types that close the device's open operation. The event is truth
        // for the action it completes (§4.4); the deadline timer is only the
        // backstop for when one of these is lost.
        guard Self.completionEventTypes.contains(eventType) else { return false }
        return await completeOpenOperation(on: deviceCode, source: .event, eventTime: event.date, result: event.payload)
    }

    /// Relay `event_type`s that complete an operation, keyed in one place so an
    /// evolving payload taxonomy is a localized edit.
    ///
    /// Travel is completed primarily by the settled-device path (see `ingest`),
    /// not by an arrival event: the per-leg events (`device_cruise_arrived`,
    /// `device_surge_hop_arrived`) fire on *every* leg, and a simple single-leg
    /// trip emits only `device_cruise_arrived` — never a whole-route arrival — so
    /// no single arrival type means "the trip is done." `device_travel_arrived`
    /// (emitted at the final destination of a multi-leg/interstellar route) is
    /// kept here only as a snappy fast-path that closes the op without waiting for
    /// the confirm-read; the per-leg events fall through to drive that read.
    static let completionEventTypes: Set<String> = [
        "print_complete",          // enqueued print finished (carries new_device_code)
        "device_travel_arrived",   // whole route finished (multi-leg/interstellar fast-path)
        "site_resource_depleted",  // mining site exhausted → drone returns to idle
        "scan_complete",           // survey search located a site → drone now tracks it
    ]

    /// Mark the single open operation on a device completed, recording any event
    /// result (e.g. a print's `new_device_code`) under `detail.result`.
    ///
    /// Returns whether an open operation was found and closed.
    @discardableResult
    public func completeOpenOperation(
        on deviceCode: String,
        source: OperationSource,
        eventTime: Date?,
        result: [String: JSONValue]?
    ) async -> Bool {
        @Dependency(\.defaultDatabase) var database
        @Dependency(\.date) var date
        let stamp = eventTime ?? date.now
        return (try? await database.write { db -> Bool in
            guard var op = try Operation.where({
                $0.entityCode.eq(deviceCode)
                    && $0.status.in(OperationStatus.liveCases)
            }).fetchOne(db)
            else { return false }

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
        }) ?? false
    }
}
