//
//  LocationEventsIngestion.swift
//  Replicould — LocationEventsFeature
//
//  The quest log's event-ingestion policy, declared beside the screen that
//  observes the `LocationEvent` table. The composition root registers these
//  values at launch: the domain registration under `.locationEvents`, and the
//  route with `GameSync`.
//

import ComposableArchitecture
import Foundation
import GameModels
import GameServices
import SQLiteData

public enum LocationEventsIngestion {
    /// The `.locationEvents` domain's refresh policy: the authoritative shape
    /// (criteria, live progress, rewards) lives at `accounts/events`, re-read
    /// wholesale into the quest log the screen and its sidebar badge observe.
    public static let domainRegistration = DomainRegistration(refresh: {
        @Dependency(\.locationEventsClient) var locationEventsClient
        return (try? await locationEventsClient.refresh()) != nil
    })

    /// The galaxy publishes quests — calls for resources or devices sited at a
    /// location. Discovery and progress both surface as stream events, but the
    /// authoritative shape lives at `accounts/events`, so — like the inbox — a
    /// nudge triggers one authoritative re-read. The same re-read is this
    /// channel's tier-2 gap repair (a cold-start / reconnect catch-up), so
    /// `apply` (gated on the trigger) and `gapRepair` (unconditional) share
    /// one trigger.
    ///
    /// Each trigger re-reads the *whole* `accounts/events` list (cursor-paged
    /// from the top), so a burst of qualifying events — tier-1 replay + tier-2
    /// backfill at launch, or several quests landing together — would fire a
    /// stack of identical full re-reads. One re-read after the burst reads the
    /// same live state, so the domain's trailing debounce collapses the burst
    /// into a single refresh once events quiet.
    public static let eventRoute: EventRoute =
        EventRoute(
            id: "locationEvents",
            match: .all,
            apply: { event in
                // Quests surface as the `event.*` family (`event.discovered` /
                // `event.completed`); a fresh scan can also reveal one.
                guard event.category == "event" || event.event == "scan.completed"
                else { return }
                // …except completion, which `completedRoute` applies directly to
                // the one row that changed. Walking every page of the list to
                // learn that a quest we already hold has closed is a lot of reads
                // for one status flip.
                guard event.event != "event.completed" else { return }
                @Dependency(\.domainFreshness) var domainFreshness
                domainFreshness.invalidate(.locationEvents)
            },
            gapRepair: {
                @Dependency(\.domainFreshness) var domainFreshness
                domainFreshness.invalidate(.locationEvents)
            }
        )

    /// A quest closing. Unlike discovery — which arrives without the criteria and
    /// progress the screen needs, so it can only nudge the authoritative list —
    /// `event.completed` carries everything completion establishes: the
    /// designation, the rewards granted, and what was consumed to earn them. So
    /// it lands on the single row it names.
    ///
    /// This is a *display-only* fold. The XP among those rewards is delivered
    /// separately as `experience.gained` with `source: "location_event"` (and
    /// credited there, by `AccountIngestion`); resource stock isn't modelled
    /// outside this table at all. Nothing persisted beyond the quest row moves.
    ///
    /// Matching the exact event name rather than the family also means the Event
    /// Log stops reporting completion as unhandled — the `.all` matcher above
    /// never counted as a feature-specific route.
    public static let completedRoute: EventRoute =
        EventRoute(id: "locationEvents.completed", match: .event("event.completed")) { event in
            @Dependency(\.defaultDatabase) var database
            @Dependency(\.domainFreshness) var domainFreshness
            @Dependency(\.date) var date

            let payload = event.payload ?? [:]
            guard
                let designation = payload["designation"]?.stringValue,
                !designation.isEmpty
            else { return }

            let now = date.now
            let completedAt = event.date
            let applied = try? await database.write { db -> Bool in
                let existing = try LocationEvent
                    .where { $0.designation.eq(designation) }
                    .fetchOne(db)
                guard let existing else { return false }
                let completed = existing.completing(payload: payload, now: now, completedAt: completedAt)
                try LocationEvent.upsert { completed }.execute(db)
                return true
            }

            // A quest we never held locally — discovery missed, or it closed from
            // another client. The payload carries no title or description, so a
            // row built from it would render blank; fall back to the
            // authoritative list, which is exactly what this route usually saves.
            if applied != true {
                domainFreshness.invalidate(.locationEvents)
            }
        }
}
