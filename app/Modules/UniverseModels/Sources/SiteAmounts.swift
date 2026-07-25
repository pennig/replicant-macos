//
//  SiteAmounts.swift
//  UniverseModels
//
//  Joins a site's live percentages with its stored original totals to produce
//  absolute amounts. One formula — `units = total × pct/100` — is used by every
//  display surface, so there is no "which source was fresher" branch: the
//  percentage always comes from the catalog row being rendered and the total is
//  a fixed constant from `SiteAssay`.
//
//  Deliberately free of SwiftUI so it can be unit-tested (pure logic hung off a
//  SwiftUI View traps under `swift test` — see the swiftui-view-statics-trap
//  memory note).
//

import Foundation

/// One resource at a site: how much of it is left, in percent and — when the
/// site has been assayed — in absolute units.
public struct ResourceAmount: Identifiable, Equatable, Sendable {
    public var resource: String
    /// 0…100, straight from `resources_remaining_pct`.
    public var percentRemaining: Double
    /// Original unit count. Nil when no assay covers this resource.
    public var total: Double?
    public var id: String { resource }

    /// Absolute units still present. Nil when the total is unknown — an honest
    /// "we don't know", never a zero standing in for missing data.
    public var remaining: Double? {
        total.map { $0 * percentRemaining / 100 }
    }

    public init(resource: String, percentRemaining: Double, total: Double? = nil) {
        self.resource = resource
        self.percentRemaining = percentRemaining
        self.total = total
    }
}

public enum SiteAmounts {
    /// Join a site's percentages with assay totals.
    ///
    /// The **live catalog drives the output**: one entry per key in
    /// `remainingPct`, sorted by resource name for deterministic rendering. A
    /// resource the assay remembers but the site no longer reports is dropped —
    /// the site is the authority on what exists.
    public static func amounts(
        remainingPct: [String: Double], totals: [String: Double]?
    ) -> [ResourceAmount] {
        remainingPct.keys.sorted().map { resource in
            ResourceAmount(
                resource: resource,
                percentRemaining: remainingPct[resource] ?? 0,
                total: totals?[resource]
            )
        }
    }

    /// Sum of the *known* remaining units. Unassayed resources are omitted, so
    /// the result is a floor — callers mark it approximate. Nil when nothing is
    /// assayed at all, which is unknown rather than zero.
    public static func totalRemaining(_ amounts: [ResourceAmount]) -> Double? {
        let known = amounts.compactMap(\.remaining)
        return known.isEmpty ? nil : known.reduce(0, +)
    }
}
