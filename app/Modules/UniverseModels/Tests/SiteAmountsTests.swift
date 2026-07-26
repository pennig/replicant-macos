//
//  SiteAmountsTests.swift
//  UniverseModels
//
//  The one formula the whole feature displays: units = total × pct/100. The
//  live catalog drives the output — an assay can only supply denominators for
//  resources the site still reports.
//

import Foundation
import Testing
@testable import UniverseModels

@Suite struct SiteAmountsTests {
    @Test func amountsJoinPercentagesWithTotals() {
        let out = SiteAmounts.amounts(
            remainingPct: ["conductive": 40],
            totals: ["conductive": 331]
        )
        #expect(out.count == 1)
        #expect(out[0].resource == "conductive")
        #expect(out[0].percentRemaining == 40)
        #expect(out[0].total == 331)
        #expect(out[0].remaining == 132.4)
    }

    /// No assay yet: the percentage still renders, the amount is unknown.
    @Test func amountsWithoutAnAssayHaveNoRemaining() {
        let out = SiteAmounts.amounts(remainingPct: ["conductive": 40], totals: nil)
        #expect(out.count == 1)
        #expect(out[0].total == nil)
        #expect(out[0].remaining == nil)
    }

    /// A partial assay covers what it covers; the rest degrade to percentages.
    @Test func amountsSupportAPartialAssay() {
        let out = SiteAmounts.amounts(
            remainingPct: ["conductive": 40, "rares": 12],
            totals: ["conductive": 331]
        )
        #expect(out.map(\.resource) == ["conductive", "rares"])
        #expect(out[0].remaining == 132.4)
        #expect(out[1].remaining == nil)
    }

    /// The live catalog decides what exists. A resource the assay remembers but
    /// the site no longer reports is dropped, not resurrected.
    @Test func amountsDropResourcesTheSiteNoLongerReports() {
        let out = SiteAmounts.amounts(
            remainingPct: ["conductive": 40],
            totals: ["conductive": 331, "silicates": 248]
        )
        #expect(out.map(\.resource) == ["conductive"])
    }

    @Test func amountsAreSortedByResourceName() {
        let out = SiteAmounts.amounts(
            remainingPct: ["silicates": 10, "conductive": 20, "rares": 30],
            totals: nil
        )
        #expect(out.map(\.resource) == ["conductive", "rares", "silicates"])
    }

    @Test func amountsAreEmptyWhenTheSiteReportsNothing() {
        #expect(SiteAmounts.amounts(remainingPct: [:], totals: ["conductive": 331]).isEmpty)
    }

    @Test func aDepletedResourceRemainsZero() {
        let out = SiteAmounts.amounts(remainingPct: ["conductive": 0], totals: ["conductive": 331])
        #expect(out[0].remaining == 0)
    }

    @Test func totalRemainingSumsTheKnownAmounts() {
        let out = SiteAmounts.amounts(
            remainingPct: ["conductive": 40, "rares": 50],
            totals: ["conductive": 331, "rares": 100]
        )
        #expect(SiteAmounts.totalRemaining(out) == 182.4)
    }

    /// Unassayed resources are omitted from the sum, which is why the UI marks
    /// the figure approximate — but a sum of nothing is unknown, not zero.
    @Test func totalRemainingIsNilWhenNothingIsAssayed() {
        let out = SiteAmounts.amounts(remainingPct: ["conductive": 40], totals: nil)
        #expect(SiteAmounts.totalRemaining(out) == nil)
    }

    /// `percentRemaining` is itself optional — a roster-sourced salvage site
    /// (names only, no percentage at all) constructs one directly rather than
    /// through `amounts`. `remaining` must require *both* dimensions known,
    /// never treating a missing percentage as zero.
    @Test func remainingIsNilWhenThePercentageItselfIsUnknown() {
        let amount = ResourceAmount(resource: "conductive", percentRemaining: nil, total: 331)
        #expect(amount.remaining == nil)
    }

    /// The inverse of the existing "no assay" case: percentage known, total
    /// unknown. Both gaps collapse to the same honest nil.
    @Test func remainingIsNilWhenOnlyTheTotalIsUnknown() {
        let amount = ResourceAmount(resource: "conductive", percentRemaining: 40, total: nil)
        #expect(amount.remaining == nil)
    }

    // MARK: - amounts(for site:) — the assayed-but-unhydrated case

    /// A hydrated site reads live: the site's own percentages drive the output.
    @Test func siteAmountsUseThePercentagesWhenTheSiteHasThem() {
        let site = SalvageSite(
            designation: "TAANSI-6-SAL-1",
            resourcesAvailable: ["conductive"], remainingPct: ["conductive": 40]
        )
        let out = SiteAmounts.amounts(for: site, totals: ["conductive": 331])
        #expect(out.map(\.resource) == ["conductive"])
        #expect(out[0].percentRemaining == 40)
        #expect(out[0].remaining == 132.4)
    }

    /// The common case, and the one this exists for: the site is known and
    /// assayed but has never been hydrated (star-level fetch, scan event, or
    /// discovery event), so there are names and totals but no percentage. The
    /// total must survive to the row as a *discovered* figure — dropping it is
    /// what left the inspector showing bare names.
    @Test func siteAmountsReportTotalsWhenThereAreNoPercentages() {
        let site = SalvageSite(
            designation: "TAANSI-6-SAL-1",
            resourcesAvailable: ["conductive", "silicates"]
        )
        let out = SiteAmounts.amounts(for: site, totals: ["conductive": 331, "silicates": 248])
        #expect(out.map(\.resource) == ["conductive", "silicates"])
        #expect(out.map(\.total) == [331, 248])
        // Nothing is invented: with no percentage there is no live remainder.
        #expect(out.allSatisfy { $0.percentRemaining == nil && $0.remaining == nil })
    }

    /// Unknown stays nil. No percentage AND no assay is a bare name, never a
    /// zero standing in for missing data.
    @Test func siteAmountsWithNeitherPercentageNorAssayAreAllUnknown() {
        let site = SalvageSite(designation: "TAANSI-6-SAL-1", resourcesAvailable: ["conductive"])
        let out = SiteAmounts.amounts(for: site, totals: nil)
        #expect(out.count == 1)
        #expect(out[0].percentRemaining == nil)
        #expect(out[0].total == nil)
    }

    @Test func siteAmountsAreSortedByResourceName() {
        let site = SalvageSite(
            designation: "TAANSI-6-SAL-1",
            resourcesAvailable: ["silicates", "conductive", "rares"]
        )
        #expect(
            SiteAmounts.amounts(for: site, totals: nil).map(\.resource)
                == ["conductive", "rares", "silicates"]
        )
    }

    // MARK: - totalDiscovered

    @Test func totalDiscoveredSumsTotalsWithNoLivePercentage() {
        let site = SalvageSite(
            designation: "TAANSI-6-SAL-1", resourcesAvailable: ["conductive", "silicates"]
        )
        let out = SiteAmounts.amounts(for: site, totals: ["conductive": 331, "silicates": 248])
        #expect(SiteAmounts.totalDiscovered(out) == 579)
        // A discovered figure is not a live one, so the live sum stays unknown.
        #expect(SiteAmounts.totalRemaining(out) == nil)
    }

    /// Once percentages arrive, `totalRemaining` speaks for those resources and
    /// `totalDiscovered` must stop double-counting them.
    @Test func totalDiscoveredExcludesResourcesThatHaveAPercentage() {
        let out = SiteAmounts.amounts(
            remainingPct: ["conductive": 40], totals: ["conductive": 331]
        )
        #expect(SiteAmounts.totalDiscovered(out) == nil)
        #expect(SiteAmounts.totalRemaining(out) == 132.4)
    }

    @Test func totalDiscoveredIsNilWithoutAnAssay() {
        let site = SalvageSite(designation: "TAANSI-6-SAL-1", resourcesAvailable: ["conductive"])
        #expect(SiteAmounts.totalDiscovered(SiteAmounts.amounts(for: site, totals: nil)) == nil)
    }
}
