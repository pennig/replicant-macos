//
//  DirectiveRetention.swift
//  Replicould — GameSync
//
//  Retention over the `directives` table — the unattended half of the clock
//  the Clear button also turns.

import Foundation
import GameModels
import OSLog
import SQLiteData

private let logger = Logger(subsystem: "name.pennig.replicould", category: "GameSync")

enum DirectiveRetention {
    /// Destroy terminal runs finished over `Directive.purgeWindow` ago and
    /// their timelines, returning how many rows went. Purge only: marking a run
    /// cleared from the list is the operator's verb, never this sweep's.
    @discardableResult
    static func sweep(_ database: any DatabaseWriter, now: Date) async -> Int {
        let cutoff = now.addingTimeInterval(-Directive.purgeWindow)
        do {
            let purged = try await database.write { db in
                try Directive.purgeFinished(before: cutoff, in: db)
            }
            if purged > 0 {
                logger.info("retention: purged \(purged) finished directive(s) older than \(Int(Directive.purgeWindow / 86_400))d")
            }
            return purged
        } catch {
            logger.error("directive retention sweep failed: \(error)")
            return 0
        }
    }
}
