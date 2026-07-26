//
//  DirectiveExecutor.swift
//  Replicould — DirectiveEngine
//
//  Applying one `MissionAction` to the database. Split out from the engine so
//  the state transitions — the part a bug would corrupt rows with — are a plain
//  function over (directive, action) rather than something tangled in task
//  lifecycle.
//
//  Every transition also appends the `DirectiveLogEntry` rows that make the step
//  visible in the detail pane's timeline (V3.9 blocker 5: the audit trail IS the
//  browsing UI). Each action commits exactly once, so a mission can never be
//  observed half-advanced.
//

import Dependencies
import Foundation
import GameModels
import GameServices
import OSLog
import SQLiteData

private let logger = Logger(subsystem: "name.pennig.replicould", category: "DirectiveEngine")

enum DirectiveExecutor {
    /// Apply one action. Returns whether the directive is still runnable — a
    /// stall or a completion retires its executor.
    @discardableResult
    static func apply(
        _ action: MissionAction,
        to directive: Directive,
        machine: any MissionStepMachine
    ) async -> Bool {
        @Dependency(\.date) var date
        @Dependency(\.uuid) var uuid

        switch action {
        case .wait:
            // Something server-side is still in progress. Deliberately writes
            // nothing: a wait that logged would bury the timeline in noise.
            return true

        case let .dispatch(kind, deviceCode, params, nextStep):
            @Dependency(\.commandGovernor) var commandGovernor
            switch await commandGovernor.dispatch(kind, deviceCode, params) {
            case let .deferred(reason):
                // Not a failure: the governor will let it through on a later
                // tick, so the step is late rather than lost. No state change.
                logger.debug("directive \(directive.id, privacy: .public): \(kind.rawValue, privacy: .public) deferred (\(reason.rawValue, privacy: .public))")
                return true

            case let .dispatched(outcome):
                switch outcome {
                case let .accepted(operationID):
                    var updated = directive
                    updated.step = nextStep
                    updated.stepStartedAt = date.now
                    updated.updatedAt = date.now
                    await commit(updated, [
                        entry(directive, .stepStarted, "Step: \(nextStep)",
                              step: nextStep, operationID: nil,
                              id: uuid().uuidString, at: date.now),
                        entry(directive, .commandDispatched, "Dispatched \(kind.rawValue) to \(deviceCode)",
                              step: nextStep, operationID: operationID,
                              id: uuid().uuidString, at: date.now),
                    ])
                    return true

                case let .rejected(message), let .failed(message):
                    await stall(directive, reason: .commandRejected, detail: message)
                    return false
                }
            }

        case let .stall(reason):
            await stall(directive, reason: reason, detail: nil)
            return false

        case .advanceTarget:
            var updated = directive
            updated.targetIndex += 1
            updated.step = machine.firstStep
            updated.stepStartedAt = date.now
            updated.updatedAt = date.now
            let summary = updated.currentTarget.map { "Target: \($0)" } ?? "Queue exhausted"
            await commit(updated, [
                entry(directive, .stepStarted, summary,
                      step: machine.firstStep, operationID: nil,
                      id: uuid().uuidString, at: date.now),
            ])
            return true

        case .done:
            var updated = directive
            updated.status = .completed
            updated.attentionReason = nil
            updated.updatedAt = date.now
            await commit(updated, [
                entry(directive, .directiveCompleted, "\(directive.kind.title) completed",
                      step: nil, operationID: nil,
                      id: uuid().uuidString, at: date.now),
            ])
            logger.info("directive \(directive.id, privacy: .public) completed")
            return false
        }
    }

    /// Pause and surface (design spec §8) — a typed reason, never a retry at
    /// the mission layer.
    private static func stall(
        _ directive: Directive,
        reason: DirectiveAttentionReason,
        detail: String?
    ) async {
        @Dependency(\.date) var date
        @Dependency(\.uuid) var uuid
        var updated = directive
        updated.status = .needsAttention
        updated.attentionReason = reason
        updated.updatedAt = date.now
        let summary = detail.map { "\(reason.rawValue): \($0)" } ?? reason.rawValue
        await commit(updated, [
            entry(directive, .stalled, summary,
                  step: directive.step, operationID: nil,
                  id: uuid().uuidString, at: date.now),
        ])
        logger.notice("directive \(directive.id, privacy: .public) stalled: \(summary, privacy: .public)")
    }

    private static func entry(
        _ directive: Directive,
        _ kind: DirectiveLogKind,
        _ summary: String,
        step: String?,
        operationID: String?,
        id: String,
        at occurredAt: Date
    ) -> DirectiveLogEntry {
        DirectiveLogEntry(
            id: id, directiveID: directive.id, deviceCode: nil, kind: kind,
            summary: summary, step: step, operationID: operationID,
            eventID: nil, occurredAt: occurredAt
        )
    }

    /// The single write site: the row and its timeline entries land in one
    /// transaction, so a mission is never observed half-advanced.
    ///
    /// Reported rather than thrown — an executor must not take the engine down
    /// over a transient write failure; the next tick re-evaluates from whatever
    /// the row still says.
    private static func commit(_ directive: Directive, _ entries: [DirectiveLogEntry]) async {
        @Dependency(\.defaultDatabase) var database
        do {
            try await database.write { db in
                try Directive.upsert { directive }.execute(db)
                for entry in entries {
                    try DirectiveLogEntry.insert { entry }.execute(db)
                }
            }
        } catch {
            logger.error("directive \(directive.id, privacy: .public) write failed: \(error)")
        }
    }
}
