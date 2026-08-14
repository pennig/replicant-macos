//
//  MissionLogBudget.swift
//  Replicould — DirectiveEngine
//
//  Loop bounds read off a directive's own log, plus the confirm ladder every mission's confirming step ends with.
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

    /// What the newest command entry in a dispatch/confirm loop run says. The
    /// three cases are three different demands: judge it, dispatch afresh, or
    /// refuse to read evidence that does not parse.
    public enum LastDispatch: Equatable, Sendable {
        case dispatched(kind: String, deviceCode: String)
        /// Nothing sent since this run of the loop began — the state a resolved
        /// stall re-enters on, where only the dispatch step can make progress.
        case nothingSent
        case unreadable
    }

    /// The newest command this `dispatch`/`confirm` loop sent, read off the line
    /// `DirectiveExecutor.dispatchSummary` writes — the only record of which
    /// verb went to which device.
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
            let words = entry.summary.split(separator: " ")
            guard words.count >= 4, words[0] == "Dispatched", words[2] == "to" else {
                return .unreadable
            }
            return .dispatched(kind: String(words[1]), deviceCode: String(words[3]))
        }
        return .nothingSent
    }
}

/// The ladder a confirming step ends with, shared by every mission that judges
/// a command against the rows it moved.
public enum MissionConfirm {
    /// Floor between confirm-reads of one row while a mission polls it.
    public static let readInterval: TimeInterval = 30

    /// Buy evidence for `rows`, or stall once `deadline` has passed. The deadline
    /// is read FIRST: a failing read never advances `updatedAt`, so the other
    /// order loops forever at one high-priority read per tick.
    public static func ladder(
        _ rows: [Device], _ directive: Directive, _ world: WorldSnapshot,
        deadline: TimeInterval, thenStall: DirectiveAttentionReason
    ) -> MissionAction {
        let codes = rows.map(\.deviceCode)
        if world.now.timeIntervalSince(directive.stepStartedAt) > deadline {
            return .refreshDevices(deviceCodes: codes, thenStall: thenStall)
        }
        guard rows.contains(where: { $0.updatedAt < directive.stepStartedAt }) else { return .wait }
        let lastLook = rows.map(\.updatedAt).min() ?? .distantPast
        if world.now.timeIntervalSince(lastLook) > readInterval {
            return .refreshDevices(deviceCodes: codes, thenStall: nil)
        }
        return .wait
    }
}
