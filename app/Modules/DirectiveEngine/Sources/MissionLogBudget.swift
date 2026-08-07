//
//  MissionLogBudget.swift
//  Replicould — DirectiveEngine
//
//  Attempt counters read off a directive's own log, for loops whose clock
//  `DirectiveExecutor.move` re-stamps on every step transition.
//

import GameModels

/// The loop bounds a mission cannot take from `stepStartedAt`.
public enum MissionLogBudget {
    /// How often `world`'s log shows the CURRENT unbroken run of the
    /// `dispatch`/`confirm` loop entering `dispatch`. Read off the log because
    /// `stepStartedAt` re-stamps on every hop, bounding one attempt not the loop.
    public static func dispatchRounds(
        _ world: WorldSnapshot, dispatch: String, confirm: String
    ) -> Int {
        var count = 0
        for entry in world.log.reversed() {
            if entry.kind == .resolved { break }
            guard entry.kind == .stepStarted else { continue }
            // Any other step ends this run of the loop, so each visit gets its
            // own budget.
            guard let step = entry.step, step == dispatch || step == confirm else { break }
            if step == dispatch { count += 1 }
        }
        return count
    }
}
