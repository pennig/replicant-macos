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
import GameServices

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
                @Dependency(\.domainFreshness) var domainFreshness
                domainFreshness.invalidate(.locationEvents)
            },
            gapRepair: {
                @Dependency(\.domainFreshness) var domainFreshness
                domainFreshness.invalidate(.locationEvents)
            }
        )
}
