//
//  MissionLogBudget.swift
//  Replicould — DirectiveEngine
//
//  Loop bounds read off a directive's own log.
//

import Foundation
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

    /// How often the CURRENT run of the `dispatch`/`confirm` loop sent `kind`,
    /// counted off the entry's own `commandKind`. A loop whose legs are
    /// immediate commands has no tracked op to count instead.
    public static func dispatchRounds(
        _ world: WorldSnapshot, dispatch: String, confirm: String, kind: OperationKind
    ) -> Int {
        var count = 0
        for entry in world.log.reversed() {
            if entry.kind == .resolved { break }
            if entry.kind == .stepStarted {
                guard let step = entry.step, step == dispatch || step == confirm else { break }
                continue
            }
            guard entry.kind == .commandDispatched, entry.step == confirm else { continue }
            if let commandKind = entry.commandKind {
                guard commandKind == kind.rawValue else { continue }
            } else {
                // Legacy row written before the columns existed; Stage 2 deletes this.
                let words = entry.summary.split(separator: " ")
                guard words.count >= 2, words[0] == "Dispatched", words[1] == kind.rawValue
                else { continue }
            }
            count += 1
        }
        return count
    }

    /// What the newest command entry in a dispatch/confirm loop run says. The
    /// two cases are two different demands: judge it, or dispatch afresh.
    public enum LastDispatch: Equatable, Sendable {
        case dispatched(kind: String, deviceCode: String)
        /// Nothing sent since this run of the loop began — the state a resolved
        /// stall re-enters on, where only the dispatch step can make progress.
        case nothingSent
    }

    /// The newest command this `dispatch`/`confirm` loop sent, read off the
    /// entry's own `commandKind`/`targetDeviceCode` columns.
    public static func lastDispatch(
        _ world: WorldSnapshot, dispatch: String, confirm: String
    ) -> LastDispatch {
        for entry in world.log.reversed() {
            if entry.kind == .resolved { return .nothingSent }
            if entry.kind == .stepStarted {
                guard let step = entry.step, step == dispatch || step == confirm else {
                    return .nothingSent
                }
                continue
            }
            guard entry.kind == .commandDispatched, entry.step == confirm else { continue }
            if let kind = entry.commandKind, let deviceCode = entry.targetDeviceCode {
                return .dispatched(kind: kind, deviceCode: deviceCode)
            }
            // Legacy row written before the columns existed; Stage 2 deletes this.
            let words = entry.summary.split(separator: " ")
            guard words.count >= 4, words[0] == "Dispatched", words[2] == "to" else {
                return .nothingSent
            }
            return .dispatched(kind: String(words[1]), deviceCode: String(words[3]))
        }
        return .nothingSent
    }
}
