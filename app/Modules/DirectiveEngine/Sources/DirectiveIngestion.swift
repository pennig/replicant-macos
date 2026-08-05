//
//  DirectiveIngestion.swift
//  Replicould — DirectiveEngine
//
//  The `directive.*` ingestion policy, declared beside the engine that consumes
//  its output; the composition root only wires it up.
//
//  Its ONLY job is writing one `DirectiveLogEntry`. It never advances a mission:
//  the engine observes the row instead, which is what keeps
//  observe-reconciled-state intact.
//

import API
import Dependencies
import Foundation
import GameModels
import GameServices
import OSLog
import SQLiteData

private let logger = Logger(subsystem: "name.pennig.replicould", category: "DirectiveEngine")

/// The two event routes that feed the directive timeline, plus the single
/// writer both share.
public enum DirectiveIngestion {
    /// Tolerance when comparing an event's timestamp against a step's start —
    /// the same value and reasoning as `Reconciler.eventTimeSkewTolerance`:
    /// absorb client/server clock skew without letting an earlier action's
    /// completion leak forward.
    static let eventTimeSkewTolerance: TimeInterval = 5

    /// The `directive` category route: records one timeline entry per
    /// `directive.completed` event carrying a device code, and announces any
    /// other `directive.*` name rather than dropping it.
    public static var eventRoute: EventRoute {
        EventRoute(id: "directive", match: .category("directive")) { event in
            guard event.event == "directive.completed" else {
                // The router's generic unhandled-event notice cannot fire once
                // this route has matched, so an unrecognised name has to be
                // announced here or it goes by silently.
                let keys = event.payload?.keys.sorted().joined(separator: ", ") ?? "none"
                logger.notice("⚠️ unhandled directive event \(event.event, privacy: .public) — payload keys: [\(keys, privacy: .public)]")
                return
            }
            guard let deviceCode = event.deviceCode, !deviceCode.isEmpty else {
                logger.notice("directive.completed without a device code — skipped")
                return
            }

            @Dependency(\.defaultDatabase) var database
            @Dependency(\.date) var date
            @Dependency(\.uuid) var uuid

            let directiveName = event.payload?["directive"]?.stringValue ?? "directive"
            let system = event.star ?? event.location
            let summary = system.map { "\(BlueprintPresentation.displayName(directiveName)) completed at \($0)" }
                ?? "\(BlueprintPresentation.displayName(directiveName)) completed"
            await record(
                event, deviceCode: deviceCode, kind: .directiveCompleted, summary: summary
            )
        }
    }

    /// The `ami.launched` route: the ONE piece of AMI telemetry a mission needs
    /// to hear, kept off the `ami` category (otherwise a firehose of per-device
    /// activity digests — hundreds an hour) by matching the exact event name.
    ///
    /// `ami.launched` carries `devices_deployed`, the server saying plainly
    /// whether the launch did anything. A zero means the controller had nothing
    /// aboard to deploy, so the survey the mission is now waiting on can never
    /// start; recording it is what lets `SurveyRun` cut the wait short instead of
    /// cycling its backstop forever.
    public static var amiLaunchRoute: EventRoute {
        EventRoute(id: "ami-launch", match: .event("ami.launched")) { event in
            guard let deviceCode = event.deviceCode, !deviceCode.isEmpty else {
                logger.notice("ami.launched without a device code — skipped")
                return
            }
            // Only an EXPLICIT zero is evidence. A missing key proves nothing,
            // and inferring failure from its absence would stall healthy runs
            // the moment the payload grew a variant.
            guard let deployed = event.payload?["devices_deployed"]?.numberValue else { return }
            guard deployed == 0 else {
                logger.debug("ami.launched on \(deviceCode, privacy: .public) deployed \(Int(deployed)) device(s)")
                return
            }
            await record(
                event, deviceCode: deviceCode, kind: .launchDeployedNothing,
                summary: "Launch deployed no devices"
            )
        }
    }

    /// Write one `DirectiveLogEntry` of `kind` reading `summary`, attributed to
    /// `deviceCode` and timestamped from `event`. Shared by both routes so the
    /// two guards that are easy to get subtly wrong — replay idempotency and
    /// issue-time-relative ownership — have exactly one implementation.
    private static func record(
        _ event: GameEventEnvelope,
        deviceCode: String,
        kind: DirectiveLogKind,
        summary: String
    ) async {
        @Dependency(\.defaultDatabase) var database
        @Dependency(\.date) var date
        @Dependency(\.uuid) var uuid

        let eventID = event.id
        // A malformed/absent timestamp falls back to now: a live event with
        // no `created_at` is almost certainly current, and dropping it would
        // lose real history.
        let eventDate = event.date ?? date.now
        let entryID = uuid().uuidString

        do {
            try await database.write { db in
                // Idempotent: catch-up replay and reconnects re-deliver the
                // same event. The `directive_log_unique_event` partial index
                // is the backstop; this check keeps a re-delivery from
                // being an error path at all.
                let existing = try DirectiveLogEntry
                    .where { $0.eventID.eq(eventID) }
                    .fetchCount(db)
                guard existing == 0 else { return }

                // Attribute to a live mission only when it is driving this
                // controller AND the event is not older than the current step.
                // Issue-time relative, not wall-clock: an event delivered by
                // catch-up after the app was closed still lands, while a
                // replayed pre-step event does not close (or stall) a step it
                // never belonged to.
                let owner = try Directive
                    .where {
                        $0.controllerCode.eq(deviceCode)
                            && $0.status.eq(DirectiveStatus.running)
                    }
                    .fetchAll(db)
                    .first { directive in
                        eventDate >= directive.stepStartedAt
                            .addingTimeInterval(-eventTimeSkewTolerance)
                    }

                try DirectiveLogEntry.insert {
                    DirectiveLogEntry(
                        id: entryID,
                        directiveID: owner?.id,
                        deviceCode: deviceCode,
                        kind: kind,
                        summary: summary,
                        step: owner?.step,
                        operationID: nil,
                        eventID: eventID,
                        occurredAt: eventDate
                    )
                }
                .execute(db)
            }
            logger.info("\(event.event, privacy: .public) on \(deviceCode, privacy: .public) recorded")
        } catch {
            logger.error("\(event.event, privacy: .public) write failed: \(error)")
        }
    }
}
