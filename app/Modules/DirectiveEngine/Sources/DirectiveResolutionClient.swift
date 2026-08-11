//
//  DirectiveResolutionClient.swift
//  Replicould — DirectiveEngine
//
//  The player's side of "pause and surface". The engine never improvises or
//  auto-retries at the mission layer, so a stalled run waits for one of these
//  verbs: retry the step, skip the target, or cancel the run — plus pause/resume
//  for a run the player wants to hold.
//
//  Every verb is a transition on `Directive`, the row the executor owns, and
//  `skipTarget` needs the machine's `firstStep` — step vocabulary the feature
//  layer must never name.
//
//  Vended as `@Dependency(\.directiveResolution)`.
//

import Dependencies
import Foundation
import GameModels
import OSLog
import SQLiteData

private let logger = Logger(subsystem: "name.pennig.replicould", category: "DirectiveEngine")

/// The five stall-resolution verbs plus the finished-run sweep, each a closure
/// so a feature can be tested without a database.
public struct DirectiveResolutionClient: Sendable {
    /// Clear `directiveID`'s stall and hand the run back to the engine on the
    /// same step.
    public var retry: @Sendable (_ directiveID: String) async -> Void
    /// Abandon `directiveID`'s current target and restart the machine on the
    /// next one.
    public var skipTarget: @Sendable (_ directiveID: String) async -> Void
    /// End `directiveID`'s run for good.
    public var cancel: @Sendable (_ directiveID: String) async -> Void
    /// Take running directive `directiveID` out of the engine's reach.
    public var pause: @Sendable (_ directiveID: String) async -> Void
    /// Hand paused directive `directiveID` back to the engine.
    public var resume: @Sendable (_ directiveID: String) async -> Void
    /// Mark every finished run — `.completed` and `.cancelled` — cleared from
    /// the list, returning how many were newly marked. Rows and timelines stay.
    ///
    /// **Terminal statuses only, and that is a safety property, not a filter.**
    /// `.running`, `.needsAttention` and `.paused` all still OWN devices
    /// (`Brain.owningStatuses`), so hiding one would take a live carrier off
    /// the operator's only view of it.
    public var clearFinished: @Sendable () async -> Int

    /// Each closure implements the property of the same name — `retry`,
    /// `skipTarget`, `cancel`, `pause`, `resume`, `clearFinished` — documented
    /// above.
    public init(
        retry: @escaping @Sendable (String) async -> Void,
        skipTarget: @escaping @Sendable (String) async -> Void,
        cancel: @escaping @Sendable (String) async -> Void,
        pause: @escaping @Sendable (String) async -> Void,
        resume: @escaping @Sendable (String) async -> Void,
        clearFinished: @escaping @Sendable () async -> Int
    ) {
        self.retry = retry
        self.skipTarget = skipTarget
        self.cancel = cancel
        self.pause = pause
        self.resume = resume
        self.clearFinished = clearFinished
    }

    /// The statuses `clearFinished` deletes. Public so the UI can count exactly
    /// what the verb would remove instead of re-deciding it.
    public static let finishedStatuses: Set<DirectiveStatus> = [.completed, .cancelled]
}

extension DirectiveResolutionClient: DependencyKey {
    /// The verbs as database transitions, each one transaction through `apply`.
    public static let liveValue = DirectiveResolutionClient(
        retry: { id in
            // Same step, fresh `stepStartedAt`. Re-stamping is what lets a
            // `surveyIncomplete` stall recover rather than instantly re-stall:
            // the completion guard is issue-time relative, so the stale
            // completion entry now predates the step and the machine drops back
            // to waiting for a real one.
            await apply(id, from: [.needsAttention], summary: { "Retried \($0.step)" }) { directive, now in
                directive.status = .running
                directive.attentionReason = nil
                directive.stepStartedAt = now
            }
        },
        skipTarget: { id in
            await apply(id, from: [.needsAttention, .paused], summary: {
                $0.currentTarget.map { target in "Skipped \(target)" } ?? "Skipped target"
            }) { directive, now in
                directive.targetIndex += 1
                // Restart the machine so the next target begins with a fresh
                // preflight rather than mid-procedure. A kind with no registered
                // machine keeps its step — it is inert either way.
                directive.step = MissionRegistry.firstStep(for: directive.kind) ?? directive.step
                directive.stepStartedAt = now
                directive.status = .running
                directive.attentionReason = nil
            }
        },
        cancel: { id in
            // Does NOT clear the controller's AMI directive. `.cancelled` is
            // outside the owning statuses, so cancelling releases ownership and
            // the built-in row's Clear button becomes available for the user to
            // do it deliberately.
            await apply(id, from: [.running, .needsAttention, .paused], summary: { _ in "Cancelled" }) { directive, _ in
                directive.status = .cancelled
                directive.attentionReason = nil
            }
        },
        pause: { id in
            await apply(id, from: [.running], summary: { _ in "Paused" }) { directive, _ in
                directive.status = .paused
            }
        },
        resume: { id in
            await apply(id, from: [.paused], summary: { _ in "Resumed" }) { directive, now in
                directive.status = .running
                directive.attentionReason = nil
                directive.stepStartedAt = now
            }
        },
        clearFinished: {
            @Dependency(\.defaultDatabase) var database
            @Dependency(\.date) var date
            let now = date.now
            do {
                return try await database.write { db in
                    let unmarked = Directive.where {
                        $0.status.in(Array(finishedStatuses)) && $0.deletedAt.is(nil)
                    }
                    let marked = try unmarked.fetchAll(db).count
                    guard marked > 0 else { return 0 }
                    // Deliberately not `updatedAt`: that column is the purge
                    // clock, and re-stamping it would restart the month.
                    try unmarked.update { $0.deletedAt = #bind(now) }.execute(db)
                    logger.info("marked \(marked) finished directive(s) cleared")
                    return marked
                }
            } catch {
                logger.error("clear finished failed: \(error)")
                return 0
            }
        }
    )

    /// Apply `mutate` to directive `directiveID` and append a `.resolved`
    /// timeline entry reading `summary`, in ONE transaction: the row change and
    /// its entry land together or neither does.
    ///
    /// A verb applied from a status outside `allowed` is a logged no-op — the UI
    /// shouldn't offer it, but a stale click must not corrupt the row.
    private static func apply(
        _ directiveID: String,
        from allowed: Set<DirectiveStatus>,
        summary: @escaping @Sendable (Directive) -> String,
        mutate: @escaping @Sendable (inout Directive, Date) -> Void
    ) async {
        @Dependency(\.defaultDatabase) var database
        @Dependency(\.date) var date
        @Dependency(\.uuid) var uuid
        let now = date.now
        let entryID = uuid().uuidString
        do {
            try await database.write { db in
                guard var directive = try Directive.where({ $0.id.eq(directiveID) }).fetchOne(db) else {
                    logger.notice("resolution on unknown directive \(directiveID, privacy: .public) — ignored")
                    return
                }
                guard allowed.contains(directive.status) else {
                    logger.notice("resolution refused on \(directiveID, privacy: .public): status is \(directive.status.rawValue, privacy: .public)")
                    return
                }
                let text = summary(directive)
                mutate(&directive, now)
                directive.updatedAt = now
                try Directive.upsert { directive }.execute(db)
                try DirectiveLogEntry.insert {
                    DirectiveLogEntry(
                        id: entryID, directiveID: directiveID, deviceCode: nil,
                        kind: .resolved, summary: text, step: directive.step,
                        operationID: nil, eventID: nil, occurredAt: now
                    )
                }
                .execute(db)
                logger.info("directive \(directiveID, privacy: .public): \(text, privacy: .public)")
            }
        } catch {
            logger.error("resolution write failed for \(directiveID, privacy: .public): \(error)")
        }
    }

    /// Loud by default: a test that resolves without stubbing must fail.
    public static let testValue = DirectiveResolutionClient(
        retry: unimplemented("DirectiveResolutionClient.retry"),
        skipTarget: unimplemented("DirectiveResolutionClient.skipTarget"),
        cancel: unimplemented("DirectiveResolutionClient.cancel"),
        pause: unimplemented("DirectiveResolutionClient.pause"),
        resume: unimplemented("DirectiveResolutionClient.resume"),
        clearFinished: unimplemented("DirectiveResolutionClient.clearFinished", placeholder: 0)
    )

    /// Every verb inert, so a preview can offer the buttons without a database.
    public static let previewValue = DirectiveResolutionClient(
        retry: { _ in }, skipTarget: { _ in }, cancel: { _ in },
        pause: { _ in }, resume: { _ in }, clearFinished: { 0 }
    )
}

extension DependencyValues {
    /// The stall-resolution verbs, the one type that writes the directive tables
    /// on the player's behalf.
    public var directiveResolution: DirectiveResolutionClient {
        get { self[DirectiveResolutionClient.self] }
        set { self[DirectiveResolutionClient.self] = newValue }
    }
}
