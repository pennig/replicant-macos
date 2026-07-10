//
//  Achievement.swift
//  Replicould — GameModels (shared domain data)
//
//  A single achievement as shown in the Account screen's Achievements tab. Unlike
//  most domain models this is *not* persisted to SQLite — achievements are a
//  modal-only view fetched fresh each time the sheet opens, so the value type
//  lives here (the domain home) but carries no `@Table`/migration.
//
//  Each entry is the merge of two endpoints: the global catalog
//  (`GET /v1/achievements`, `AchievementSummarySchema` — every achievement plus a
//  galaxy-wide `player_count`) annotated with the authenticated player's earned
//  set (`GET /v1/accounts/achievements`, `AchievementSchema` — the ones this
//  account has unlocked, with the date it did). So one list shows both locked and
//  earned achievements, grouped by category.
//

import API
import Foundation

/// One achievement — locked or earned — for the Achievements tab.
public struct Achievement: Identifiable, Equatable, Sendable {
    /// The stable key (`hundred_light_years`) — the natural identity.
    public var key: String
    public var title: String
    public var summary: String
    /// The grouping category (`travel`, `exploration`, `infrastructure`, …).
    public var category: String
    public var xpReward: Int
    /// Whether the signed-in account has earned this achievement.
    public var isEarned: Bool
    /// When this account earned it; nil while locked (or when the date couldn't be
    /// parsed — `isEarned` is still the source of truth for locked/earned).
    public var achievedAt: Date?
    /// How many players galaxy-wide have earned it (from the global catalog); nil
    /// when only the player's earned set is known.
    public var playerCount: Int?

    public var id: String { key }

    public init(
        key: String,
        title: String,
        summary: String,
        category: String,
        xpReward: Int,
        isEarned: Bool,
        achievedAt: Date? = nil,
        playerCount: Int? = nil
    ) {
        self.key = key
        self.title = title
        self.summary = summary
        self.category = category
        self.xpReward = xpReward
        self.isEarned = isEarned
        self.achievedAt = achievedAt
        self.playerCount = playerCount
    }
}

// MARK: - Mapping

extension Achievement {
    /// Parses the player-endpoint's `achieved_at` string (ISO-8601 with offset,
    /// e.g. `2026-07-06T01:34:21-05:00`). No `format` is declared on that field, so
    /// it arrives as a plain string and we parse it here. The formatter is built
    /// per call — `ISO8601DateFormatter` isn't `Sendable`, so it can't be a shared
    /// static, and this only runs when the achievements sheet opens.
    private static func parseEarnedDate(_ string: String?) -> Date? {
        guard let string else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    /// Map an *earned* achievement (the player endpoint). `isEarned` is true;
    /// `playerCount` is unknown from this endpoint.
    public init(earned schema: Components.Schemas.AppSchemasAchievementsAchievementSchema) {
        self.init(
            key: schema.achievementKey ?? "",
            title: schema.title ?? "",
            summary: schema.description ?? "",
            category: schema.category ?? "",
            xpReward: schema.xpReward ?? 0,
            isEarned: true,
            achievedAt: Achievement.parseEarnedDate(schema.achievedAt),
            playerCount: nil
        )
    }

    /// Map a *catalog* achievement (the global endpoint). Locked by default —
    /// merged with the player's earned set to flip `isEarned`.
    public init(catalog schema: Components.Schemas.AppSchemasAchievementsPublicAchievementSummarySchema) {
        self.init(
            key: schema.achievementKey ?? "",
            title: schema.title ?? "",
            summary: schema.description ?? "",
            category: schema.category ?? "",
            xpReward: schema.xpReward ?? 0,
            isEarned: false,
            achievedAt: nil,
            playerCount: schema.playerCount
        )
    }
}

// MARK: - Merge

extension Achievement {
    /// Merge the player's earned set into the global catalog, so the result lists
    /// every achievement (locked + earned) with galaxy-wide player counts, and the
    /// earned ones carry their unlock date. Any earned achievement missing from the
    /// catalog (shouldn't happen, but be defensive) is appended so nothing the
    /// player earned is ever dropped.
    public static func merged(earned: [Achievement], catalog: [Achievement]) -> [Achievement] {
        let earnedByKey = Dictionary(earned.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        var result: [Achievement] = catalog.map { entry in
            seen.insert(entry.key)
            guard let earnedMatch = earnedByKey[entry.key] else { return entry }
            var merged = entry
            merged.isEarned = true
            merged.achievedAt = earnedMatch.achievedAt
            return merged
        }
        for entry in earned where !seen.contains(entry.key) {
            result.append(entry)
        }
        return result
    }
}

// MARK: - Preview fixtures

extension Achievement {
    /// Sample list used by Xcode previews and the `AccountClient` preview value —
    /// a mix of earned and locked across a few categories. Tests define their own.
    public static let previewCatalog: [Achievement] = [
        Achievement(key: "hundred_light_years", title: "Deep Space Drifter", summary: "Accumulate 100 light years of interstellar travel.", category: "travel", xpReward: 500, isEarned: true, achievedAt: .now, playerCount: 42),
        Achievement(key: "visited_ten_systems", title: "Well Travelled", summary: "Visit ten different star systems.", category: "travel", xpReward: 500, isEarned: true, achievedAt: .now, playerCount: 88),
        Achievement(key: "star_cartographer", title: "Star Cartographer", summary: "Discover fifty new star systems.", category: "exploration", xpReward: 3000, isEarned: false, achievedAt: nil, playerCount: 7),
        Achievement(key: "first_beacon", title: "Signal Fire", summary: "Deploy your first FTL beacon.", category: "infrastructure", xpReward: 300, isEarned: true, achievedAt: .now, playerCount: 120),
        Achievement(key: "dyson_discovered", title: "Dyson Project Detected", summary: "Intercepted a spacefaring civilisation's plan to construct a Dyson swarm.", category: "location_events", xpReward: 200, isEarned: false, achievedAt: nil, playerCount: 6),
    ]
}
