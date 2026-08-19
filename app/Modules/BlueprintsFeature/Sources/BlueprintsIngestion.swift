//
//  BlueprintsIngestion.swift
//  Replicould — Blueprints feature
//
//  The catalog's real-time channel: an unlock re-reads it instead of waiting
//  for the hourly sweep.
//

import Dependencies
import Foundation
import GameModels
import GameServices
import SQLiteData

public enum BlueprintsIngestion {
    /// One request for the full unlocked catalog. The hourly sweep in
    /// `DeadlineScheduler` reads the same endpoint; this is the same read on
    /// the event that changes the answer.
    public static let domainRegistration = DomainRegistration(
        debounce: .seconds(5),
        ttl: 60,
        refresh: {
            @Dependency(\.defaultDatabase) var database
            @Dependency(\.blueprintsClient) var blueprintsClient
            guard let blueprints = try? await blueprintsClient.fetchAll() else { return false }
            do {
                try await database.write { db in
                    try Blueprint.upsert { blueprints }.execute(db)
                }
            } catch {
                return false
            }
            return true
        }
    )

    /// `blueprint.unlocked` decides things, not just what the catalog screen
    /// lists: `EventPlan.resolve` filters an event's options by what the
    /// account can print, so a catalog that lags an unlock can rank one option
    /// buildable and hand the run a choice the operator never made. The
    /// payload carries no capacities, so the route re-reads rather than folds.
    public static let eventRoute: EventRoute =
        EventRoute(
            id: "blueprints.unlocked",
            match: .event("blueprint.unlocked"),
            apply: { _ in
                @Dependency(\.domainFreshness) var domainFreshness
                domainFreshness.invalidate(.blueprints)
            },
            gapRepair: {
                @Dependency(\.domainFreshness) var domainFreshness
                domainFreshness.invalidate(.blueprints)
            }
        )
}
