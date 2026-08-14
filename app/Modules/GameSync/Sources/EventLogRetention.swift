//
//  EventLogRetention.swift
//  Replicould — GameSync
//
//  Retention over the `eventLogs` ledger, which nothing pruned while every
//  dispatched event appends one row carrying its whole payload verbatim.
//

import Foundation
import GameModels
import OSLog
import SQLiteData

private let logger = Logger(subsystem: "name.pennig.replicould", category: "GameSync")

enum EventLogRetention {
    /// How long a captured event stays browsable, matching the Operations Log's
    /// own window. A week of raw SSE is far more than the taxonomy work the
    /// ledger exists for needs, and the Clear affordance still empties it early.
    static let window: TimeInterval = 7 * 24 * 60 * 60

    /// Delete captured events older than `window`, returning how many went.
    ///
    /// Deleted in one statement rather than fetched and deleted by id: the
    /// backlog on first sweep is tens of thousands of rows, and `receivedAt` is
    /// indexed, so there is no reason to carry them through Swift.
    ///
    /// Reported rather than thrown: retention is housekeeping, and failing it
    /// must never take down the sync engine that calls it.
    @discardableResult
    static func sweep(_ database: any DatabaseWriter, now: Date) async -> Int {
        let cutoff = now.addingTimeInterval(-window)
        do {
            let deleted = try await database.write { db -> Int in
                try EventLog.where { $0.receivedAt < cutoff }.delete().execute(db)
                return db.changesCount
            }
            if deleted > 0 {
                logger.info("retention: pruned \(deleted) event log entr(ies) older than \(Int(Self.window / 86_400))d")
            }
            return deleted
        } catch {
            logger.error("event log retention sweep failed: \(error)")
            return 0
        }
    }
}
