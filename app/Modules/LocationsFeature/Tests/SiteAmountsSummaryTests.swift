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

    /// A roster-sourced salvage site has names but no percentage at all
    /// (`SiteAmounts.amounts(for:)` leaves `percentRemaining` nil) and no assay
    /// either — the summary lists the names and fabricates no figure.
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

    // MARK: - Assayed but not hydrated

    /// The common case: the assay is in but the body has never been fetched, so
    /// there are totals and no percentages. The summary reports the discovered
    /// figure — worded apart from the live one — instead of degrading to names.
    @Test func summaryShowsDiscoveredTotalWhenNoPercentageIsKnown() {
        let site = SalvageSite(
            designation: "TAANSI-6-SAL-1", resourcesAvailable: ["conductive", "rares"]
        )
        let amounts = SiteAmounts.amounts(for: site, totals: ["conductive": 331, "rares": 99])
        #expect(SiteAmountsSummary.summary(status: nil, amounts: amounts) == "~430 discovered")
    }

    /// A partial assay still yields a floor, same as the live figure does.
    @Test func discoveredTotalCountsOnlyTheAssayedResources() {
        let site = SalvageSite(
            designation: "TAANSI-6-SAL-1", resourcesAvailable: ["conductive", "rares"]
        )
        let amounts = SiteAmounts.amounts(for: site, totals: ["conductive": 331])
        #expect(SiteAmountsSummary.summary(status: nil, amounts: amounts) == "~331 discovered")
    }

    /// The live figure outranks the discovered one, so hydrating a site never
    /// shows both claims at once.
    @Test func liveUnitsWinOverTheDiscoveredFigure() {
        let site = SalvageSite(
            designation: "TAANSI-6-SAL-1",
            resourcesAvailable: ["conductive"], remainingPct: ["conductive": 40]
        )
        let amounts = SiteAmounts.amounts(for: site, totals: ["conductive": 331])
        #expect(SiteAmountsSummary.summary(status: nil, amounts: amounts) == "~132 units")
    }

    @Test func depletedStatusComposesWithTheDiscoveredFigure() {
        let site = SalvageSite(
            designation: "TAANSI-6-SAL-1", resourcesAvailable: ["conductive"], depleted: true
        )
        let amounts = SiteAmounts.amounts(for: site, totals: ["conductive": 331])
        #expect(
            SiteAmountsSummary.summary(status: "Depleted", amounts: amounts)
                == "Depleted · ~331 discovered"
        )
    }
}
