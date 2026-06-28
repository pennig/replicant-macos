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
//  (`Device.updatedAt`, §4.1); local-only provenance (`firstSeenAt`) survives
//  every upsert; a stale or duplicate snapshot is a no-op.
//
//  Operations: completion events (e.g. `print_complete`) are treated as truth
//  for the action they close (§4.4) — they carry the result the dispatch
//  response withheld — so they complete the device's open operation directly.
//

import API
import ComposableArchitecture
import Foundation
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
        try? await database.write { db in
            let existing = try Device
                .where { $0.deviceCode.eq(device.deviceCode) }
                .fetchOne(db)

            // Guard: never overwrite a row from a source whose event-time is
            // older than what's stored (out-of-order / duplicate arrivals).
            if let existing, device.updatedAt < existing.updatedAt {
                logger.debug("ingest \(device.deviceCode, privacy: .public): dropped stale (incoming \(device.updatedAt.ISO8601Format(), privacy: .public) < stored \(existing.updatedAt.ISO8601Format(), privacy: .public))")
                return
            }

            var toWrite = device
            if let existing { toWrite.firstSeenAt = existing.firstSeenAt }
            try Device.upsert { toWrite }.execute(db)
            logger.debug("ingest \(device.deviceCode, privacy: .public): applied status=\(device.status, privacy: .public) loc=\(device.location ?? "-", privacy: .public)")
        }
    }

    /// Apply a relay game-event's effect on the `Operation` table. Completion
    /// event types close the device's open operation and fold their result into
    /// its `detail`; everything else is left to the device confirm-read path.
    public func applyOperationEvent(_ event: UnifiedEvent) async {
        guard event.type == "event",
              let deviceCode = event.deviceCode,
              let eventType = event.eventType
        else { return }

        // Event types that close the device's open operation. The event is truth
        // for the action it completes (§4.4); the deadline timer is only the
        // backstop for when one of these is lost.
        guard Self.completionEventTypes.contains(eventType) else { return }
        await completeOpenOperation(on: deviceCode, source: .event, eventTime: event.date, result: event.payload)
    }

    /// Relay `event_type`s that complete an operation, keyed in one place so an
    /// evolving payload taxonomy is a localized edit.
    static let completionEventTypes: Set<String> = [
        "print_complete",          // enqueued print finished (carries new_device_code)
        "device_cruise_arrived",   // travel finished
    ]

    /// Mark the single open operation on a device completed, recording any event
    /// result (e.g. a print's `new_device_code`) under `detail.result`.
    public func completeOpenOperation(
        on deviceCode: String,
        source: OperationSource,
        eventTime: Date?,
        result: [String: JSONValue]?
    ) async {
        @Dependency(\.defaultDatabase) var database
        @Dependency(\.date) var date
        let stamp = eventTime ?? date.now
        try? await database.write { db in
            guard var op = try Operation.where({
                $0.entityCode.eq(deviceCode)
                    && ($0.status.eq(OperationStatus.enqueued.rawValue)
                        || $0.status.eq(OperationStatus.active.rawValue))
            }).fetchOne(db)
            else { return }

            if let result {
                var dict: [String: JSONValue] = {
                    if case .object(let existing) = op.detail { return existing }
                    return [:]
                }()
                dict["result"] = .object(result)
                op.detail = .object(dict)
            }
            op.status = OperationStatus.completed.rawValue
            op.source = source.rawValue
            op.lastConfirmedAt = stamp
            try Operation.upsert { op }.execute(db)
            logger.info("completed op \(op.id, privacy: .public) (\(op.kind, privacy: .public)) on \(deviceCode, privacy: .public) via \(source.rawValue, privacy: .public)")
        }
    }
}
