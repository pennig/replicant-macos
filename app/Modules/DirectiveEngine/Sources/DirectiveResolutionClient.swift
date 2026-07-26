//
//  DirectiveResolutionClient.swift
//  Replicould — DirectiveEngine
//
//  The player's side of "pause and surface" (design spec §8). The engine never
//  improvises or auto-retries at the mission layer, so a stalled run waits for
//  one of these verbs: retry the step, skip the target, or cancel the run —
//  plus pause/resume for a run the player wants to hold.
//
//  Lives here rather than in the feature because every verb is a transition on
//  `Directive`, the row the executor owns, and because `skipTarget` needs the
//  machine's `firstStep` — step vocabulary the feature must never name.
//
//  Vended as `@Dependency(\.directiveResolution)`.
//

import Dependencies
import Foundation
import GameModels
import OSLog
import SQLiteData

private let logger = Logger(subsystem: "name.pennig.replicould", category: "DirectiveEngine")

public struct DirectiveResolutionClient: Sendable {
    /// Clear a stall and hand the run back to the engine on the same step.
    public var retry: @Sendable (_ directiveID: String) async -> Void
    /// Abandon the current target and restart the machine on the next one.
    public var skipTarget: @Sendable (_ directiveID: String) async -> Void
    /// End the run for good.
    public var cancel: @Sendable (_ directiveID: String) async -> Void
    /// Take a running directive out of the engine's reach.
    public var pause: @Sendable (_ directiveID: String) async -> Void
    /// Hand a paused directive back to the engine.
    public var resume: @Sendable (_ directiveID: String) async -> Void

    public init(
        retry: @escaping @Sendable (String) async -> Void,
        skipTarget: @escaping @Sendable (String) async -> Void,
        cancel: @escaping @Sendable (String) async -> Void,
        pause: @escaping @Sendable (String) async -> Void,
        resume: @escaping @Sendable (String) async -> Void
    ) {
        self.retry = retry
        self.skipTarget = skipTarget
        self.cancel = cancel
        self.pause = pause
        self.resume = resume
    }
}

extension DirectiveResolutionClient: DependencyKey {
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
            // Deliberately does NOT clear the controller's AMI directive: that
            // is a server command with its own failure modes, and cancelling
            // releases ownership (`.cancelled` is outside the owning statuses),
            // so the built-in row's Clear button becomes available for the user
            // to do it deliberately.
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
        }
    )

    /// One transaction: the row change and its timeline entry land together or
    /// neither does. A verb applied from a status it doesn't apply to is a
    /// logged no-op — the UI shouldn't offer it, but a stale click must not
    /// corrupt the row.
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
        resume: unimplemented("DirectiveResolutionClient.resume")
    )

    public static let previewValue = DirectiveResolutionClient(
        retry: { _ in }, skipTarget: { _ in }, cancel: { _ in },
        pause: { _ in }, resume: { _ in }
    )
}

extension DependencyValues {
    public var directiveResolution: DirectiveResolutionClient {
        get { self[DirectiveResolutionClient.self] }
        set { self[DirectiveResolutionClient.self] = newValue }
    }
}
