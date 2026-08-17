//
//  LauncherTheatre.swift
//  Replicould — Directives feature
//
//  The theatre an operator launch stamps on its row. One read, four launchers.
//

import DirectiveEngine
import Foundation
import GameModels
import OSLog
import SQLiteData

private let logger = Logger(subsystem: "name.pennig.replicould", category: "Directives")

/// Resolves the theatre a launcher stamps. Nil is the row going out unstamped
/// with an unscoped tag, and the two ways of reaching it — a failed read and an
/// honestly theatre-less device — are logged apart.
enum LauncherTheatre {
    /// `goal`'s scoped tag on `deviceCode` outranks its location; without one,
    /// location decides. The brain's own launches resolve the same way.
    static func resolve(
        for deviceCode: String,
        goal: FleetTag.Goal,
        database: any DatabaseWriter,
        now: Date
    ) async -> Theatre? {
        do {
            return try await database.read { db -> Theatre? in
                let view = try WorldView.read(from: db, now: now)
                guard let device = view.devices[deviceCode],
                      let theatre = view.owningTheatre(of: device, goal: goal)
                else {
                    logger.notice(
                        """
                        \(goal.rawValue, privacy: .public) launch on \
                        \(deviceCode, privacy: .public): no theatre resolves — unscoped tag
                        """
                    )
                    return nil
                }
                return theatre
            }
        } catch {
            logger.error(
                """
                \(goal.rawValue, privacy: .public) launch on \(deviceCode, privacy: .public): \
                theatre read failed: \(error.localizedDescription, privacy: .public) — unscoped tag
                """
            )
            return nil
        }
    }
}
