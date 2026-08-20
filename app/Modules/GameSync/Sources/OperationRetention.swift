//
//  OperationRetention.swift
//  Replicould — GameSync
//
//  Retention over the `operations` table.
//
//  Nothing pruned it before. Ops are created optimistically on dispatch and
//  adopted from device snapshots, closed by the reconciler or the deadline
//  scheduler, and then kept forever — so the table only ever grew, and the
//  Operations Log rendered every row it had ever seen.
//
//  That was survivable while ops tracked real work. It stopped being survivable
//  when a bad deadline source produced 218 dead `unknown` rows in a single day
//  (surge plates reporting a stale `final_arrives_at`, fixed in
//  `Device.travelDeadline`), leaving the log 68% noise. The deadline bug is
//  fixed; this is the backstop that keeps the next one from being permanent.
//

import Foundation
import GameModels
import OSLog
import SQLiteData

private let logger = Logger(subsystem: "name.pennig.replicould", category: "GameSync")

/// Disambiguate from `Foundation.Operation`.
private typealias Operation = GameModels.Operation

enum OperationRetention {
    /// How long a finished operation stays browsable. A week comfortably spans
    /// "what was my fleet doing recently?" — the question the Operations Log
    /// exists to answer — while bounding the table at a few hundred rows under
    /// normal churn.
    static let window: TimeInterval = 7 * 24 * 60 * 60

    /// Delete finished operations older than `window`, returning how many went.
    ///
    /// Two conditions, and BOTH are load-bearing:
    ///
    /// * **Terminal only.** An open op is never pruned however old. An ancient
    ///   `active` row means something genuinely went wrong and is worth seeing,
    ///   and deleting one would also punch a hole in the one-active-per-device
    ///   partial unique index that dispatch relies on.
    /// * **Older than the window**, measured from `startedAt` — the one
    ///   timestamp every op has, set once and never rewritten (`lastConfirmedAt`
    ///   moves under re-arms, so a re-armed op would never age out).
    ///
    /// Reported rather than thrown: retention is housekeeping, and failing it
    /// must never take down the sync engine that calls it.
    @discardableResult
    static func sweep(_ database: any DatabaseWriter, now: Date) async -> Int {
        let cutoff = now.addingTimeInterval(-window)
        do {
            let deleted = try await database.write { db in
                let doomed = try Operation
                    .where {
                        !$0.status.in(OperationStatus.openCases)
                            && $0.startedAt < Date.FastISO8601Representation(queryOutput: cutoff)
                    }
                    .fetchAll(db)
                    .map(\.id)
                guard !doomed.isEmpty else { return 0 }
                try Operation.where { $0.id.in(doomed) }.delete().execute(db)
                return doomed.count
            }
            if deleted > 0 {
                logger.info("retention: pruned \(deleted) finished operation(s) older than \(Int(Self.window / 86_400))d")
            }
            return deleted
        } catch {
            logger.error("retention sweep failed: \(error)")
            return 0
        }
    }
}
