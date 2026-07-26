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
    /// 0…100, straight from `resources_remaining_pct`. Nil when the site
    /// carries only a resource name and no percentage at all (the `salvage[]`
    /// roster block) — an honest "we don't know", never a zero standing in for
    /// missing data.
    public var percentRemaining: Double?
    /// Original unit count. Nil when no assay covers this resource.
    public var total: Double?
    public var id: String { resource }

    /// Absolute units still present. Nil unless both the percentage and the
    /// total are known — an honest "we don't know", never a zero standing in
    /// for missing data.
    public var remaining: Double? {
        guard let total, let percentRemaining else { return nil }
        return total * percentRemaining / 100
    }

    public init(resource: String, percentRemaining: Double?, total: Double? = nil) {
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

    /// Amounts for a salvage site, tolerant of the two shapes salvage arrives in.
    ///
    /// A site sourced from `resource_sites[]` carries percentages, so it reads
    /// live. A site sourced from the `salvage[]` roster block, a `scan.completed`
    /// body, or a `salvage.discovered` event carries only resource *names* — the
    /// percentage is genuinely unknown there. Rather than dropping the assay on
    /// the floor, each name still reports its original total, which the UI shows
    /// as a **discovered** figure rather than a live one. Nothing is invented:
    /// `percentRemaining` stays nil, so `remaining` stays nil.
    public static func amounts(for site: SalvageSite, totals: [String: Double]?) -> [ResourceAmount] {
        guard site.remainingPct.isEmpty else {
            return amounts(remainingPct: site.remainingPct, totals: totals)
        }
        return site.resourcesAvailable.sorted().map {
            ResourceAmount(resource: $0, percentRemaining: nil, total: totals?[$0])
        }
    }

    /// Sum of the *known* remaining units. Unassayed resources are omitted, so
    /// the result is a floor — callers mark it approximate. Nil when nothing is
    /// assayed at all, which is unknown rather than zero.
    public static func totalRemaining(_ amounts: [ResourceAmount]) -> Double? {
        let known = amounts.compactMap(\.remaining)
        return known.isEmpty ? nil : known.reduce(0, +)
    }

    /// Sum of the original totals for resources whose live percentage is *not*
    /// known — what was discovered at the site, not what is left on it now. The
    /// honest thing to report for an assayed-but-unhydrated site, where
    /// `totalRemaining` is necessarily nil. Nil when no such resource is
    /// assayed; resources that do carry a percentage are excluded, because
    /// `totalRemaining` already speaks for them.
    public static func totalDiscovered(_ amounts: [ResourceAmount]) -> Double? {
        let known = amounts.filter { $0.percentRemaining == nil }.compactMap(\.total)
        return known.isEmpty ? nil : known.reduce(0, +)
    }
}
