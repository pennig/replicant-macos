//
//  Reconciler.swift
//  Replicould — GameSync
//
//  The correctness core (IMPLEMENTATION_PLAN §6): one guarded write path that
//  every ingestion source (relay-driven confirm reads now; optimistic dispatch
//  and the poll coordinator later) funnels through. Last-writer-wins by
//  synthesized event-time (`Device.updatedAt`, §4.1), and local-only provenance
//  (`firstSeenAt`) survives every upsert. A stale or duplicate snapshot is a
//  no-op.
//

import ComposableArchitecture
import DependencyClients
import Foundation
import SQLiteData

struct Reconciler: Sendable {
    /// Upsert an authoritative device snapshot under the event-time guard.
    /// Drops the write if what we already have is newer; preserves the stored
    /// `firstSeenAt`.
    func ingest(_ device: Device) async {
        @Dependency(\.defaultDatabase) var database
        try? await database.write { db in
            let existing = try Device
                .where { $0.deviceCode.eq(device.deviceCode) }
                .fetchOne(db)

            // Guard: never overwrite a row from a source whose event-time is
            // older than what's stored (out-of-order / duplicate arrivals).
            if let existing, device.updatedAt < existing.updatedAt { return }

            var toWrite = device
            if let existing { toWrite.firstSeenAt = existing.firstSeenAt }
            try Device.upsert { toWrite }.execute(db)
        }
    }
}
