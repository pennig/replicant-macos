//
//  DirectiveLogRetention.swift
//  Replicould — GameSync
//
//  Retention over the `directiveLogEntries` table, which nothing pruned
//  while `WorldSnapshot.read` re-fetches a directive's whole log every tick.
//

import Foundation
import GameModels
import OSLog
import SQLiteData

private let logger = Logger(subsystem: "name.pennig.replicould", category: "GameSync")

enum DirectiveLogRetention {
    /// How long a finished run's timeline stays browsable. A month, matching
    /// the directive rows' own purge window — a cleared run is kept for its
    /// diagnostics, and the timeline is the diagnostics.
    static let window: TimeInterval = 30 * 24 * 60 * 60

    /// Delete stale log entries older than `window`, returning how many went.
    ///
    /// An entry owned by a still-open directive is never pruned however old.
    @discardableResult
    static func sweep(_ database: any DatabaseWriter, now: Date) async -> Int {
        let cutoff = now.addingTimeInterval(-window)
        do {
            let deleted = try await database.write { db in
                let openIDs = Set(
                    try Directive
                        .where { $0.status.in(DirectiveStatus.openCases) }
                        .fetchAll(db)
                        .map(\.id)
                )
                let doomed = try DirectiveLogEntry
                    .where { $0.occurredAt < cutoff }
                    .fetchAll(db)
                    .filter { entry in
                        guard let owner = entry.directiveID else { return true }
                        return !openIDs.contains(owner)
                    }
                    .map(\.id)
                guard !doomed.isEmpty else { return 0 }
                try DirectiveLogEntry.where { $0.id.in(doomed) }.delete().execute(db)
                return doomed.count
            }
            if deleted > 0 {
                logger.info("retention: pruned \(deleted) directive log entr(ies) older than \(Int(Self.window / 86_400))d")
            }
            return deleted
        } catch {
            logger.error("directive log retention sweep failed: \(error)")
            return 0
        }
    }
}
