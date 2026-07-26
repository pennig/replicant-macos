//
//  SiteAmountsSummary.swift
//  LocationsFeature
//
//  Composes `SiteAmountsRow`'s collapsed summary text — an optional status
//  ("Depleted") combined with either the total units still present or a plain
//  list of resource names. Presentation-specific (the wording and punctuation
//  belong to this row, not to the domain join in `SiteAmounts`), but
//  deliberately free of SwiftUI so it can be unit-tested: pure logic hung off
//  a SwiftUI View traps under `swift test` (see the
//  swiftui-view-statics-trap memory note).
//

import Foundation
import UniverseModels

/// The collapsed figure shown beside a site's name, in descending order of
/// what's known: the total units still present (summed across resources) when
/// the site is both hydrated and assayed; else the total *discovered* when the
/// assay is in but the live percentages aren't; else the resource names, which
/// is what the row showed before assays existed.
enum SiteAmountsSummary {
    /// - Parameters:
    ///   - status: Rendered before the rest, e.g. "Depleted". Nil/empty is
    ///     omitted.
    ///   - amounts: The site's resources, as produced by `SiteAmounts.amounts`
    ///     (or, for a roster-sourced salvage site, names with an unknown
    ///     percentage).
    /// - Returns: Nil when there is nothing to show at all.
    static func summary(status: String?, amounts: [ResourceAmount]) -> String? {
        var parts: [String] = []
        if let status, !status.isEmpty { parts.append(status) }
        if let units = SiteAmounts.totalRemaining(amounts) {
            parts.append("~\(format(units)) units")
        } else if let discovered = SiteAmounts.totalDiscovered(amounts) {
            // Assayed but not hydrated: we know what was found, not what's
            // left. Worded apart from the live figure so the two never read as
            // the same claim.
            parts.append("~\(format(discovered)) discovered")
        } else if !amounts.isEmpty {
            parts.append(amounts.map(\.resource).joined(separator: ", "))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func format(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0)))
    }
}
