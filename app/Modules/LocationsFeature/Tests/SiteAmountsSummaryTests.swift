//
//  SiteAmountsSummaryTests.swift
//  LocationsFeature
//
//  Covers `SiteAmountsRow`'s collapsed-summary composition, extracted to
//  `SiteAmountsSummary` precisely so it can be tested without a SwiftUI host.
//

import Testing
import UniverseModels
@testable import LocationsFeature

@Suite struct SiteAmountsSummaryTests {
    /// An assayed site collapses to its total remaining units, `~`-prefixed.
    @Test func summaryShowsAssayedUnits() {
        let amounts = SiteAmounts.amounts(
            remainingPct: ["conductive": 40],
            totals: ["conductive": 331]
        )
        #expect(SiteAmountsSummary.summary(status: nil, amounts: amounts) == "~132 units")
    }

    /// A roster-sourced salvage site has names but no percentage at all (the
    /// `salvageAmounts` fallback passes `percentRemaining: nil`) — the summary
    /// lists the names and fabricates no figure.
    @Test func summaryListsNamesWhenNoPercentageIsKnown() {
        let amounts = ["conductive", "rares"].map {
            ResourceAmount(resource: $0, percentRemaining: nil)
        }
        #expect(SiteAmountsSummary.summary(status: nil, amounts: amounts) == "conductive, rares")
    }

    /// Percentages are known but nothing has been assayed: still no units
    /// figure (nothing to sum), so the summary falls back to names.
    @Test func summaryFallsBackToNamesWhenNothingIsAssayed() {
        let amounts = SiteAmounts.amounts(
            remainingPct: ["conductive": 40, "rares": 12],
            totals: nil
        )
        #expect(SiteAmountsSummary.summary(status: nil, amounts: amounts) == "conductive, rares")
    }

    /// A depleted site's status composes ahead of the name fallback.
    @Test func depletedStatusComposesWithNameFallback() {
        let amounts = ["conductive", "rares"].map {
            ResourceAmount(resource: $0, percentRemaining: nil)
        }
        #expect(
            SiteAmountsSummary.summary(status: "Depleted", amounts: amounts)
                == "Depleted · conductive, rares"
        )
    }

    /// A depleted site's status composes ahead of an assayed units figure too
    /// (a fully-assayed site can be depleted without every resource reading
    /// exactly zero, e.g. a still-live secondary resource).
    @Test func depletedStatusComposesWithAssayedUnits() {
        let amounts = SiteAmounts.amounts(
            remainingPct: ["conductive": 0],
            totals: ["conductive": 331]
        )
        #expect(
            SiteAmountsSummary.summary(status: "Depleted", amounts: amounts)
                == "Depleted · ~0 units"
        )
    }

    /// Nothing to show at all: no status, no amounts.
    @Test func summaryIsNilWhenThereIsNothingToShow() {
        #expect(SiteAmountsSummary.summary(status: nil, amounts: []) == nil)
    }
}
