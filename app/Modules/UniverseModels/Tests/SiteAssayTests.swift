//
//  SiteAssayTests.swift
//  UniverseModels
//
//  The write policy for stored site totals. A site's original capacity is a
//  fixed fact, so an observation may only ever raise a stored total — that
//  invariant is what makes the "discovery counts are originals" inference
//  self-correcting rather than permanent.
//

import Foundation
import Testing
@testable import UniverseModels

@Suite struct SiteAssayTests {
    @Test func raisingSeedsFromEmpty() {
        let out = SiteAssay.raising([:], with: ["conductive": 331, "rares": 99])
        #expect(out == ["conductive": 331, "rares": 99])
    }

    @Test func raisingNeverLowersAStoredTotal() {
        let out = SiteAssay.raising(["conductive": 331], with: ["conductive": 120])
        #expect(out == ["conductive": 331])
    }

    @Test func raisingLiftsAStoredTotalWhenTheObservationIsLarger() {
        let out = SiteAssay.raising(["conductive": 120], with: ["conductive": 331])
        #expect(out == ["conductive": 331])
    }

    /// Per resource key, not per site: an observation naming a subset must
    /// leave the resources it doesn't mention untouched.
    @Test func raisingAppliesPerResourceKey() {
        let out = SiteAssay.raising(
            ["conductive": 331, "rares": 99],
            with: ["conductive": 400]
        )
        #expect(out == ["conductive": 400, "rares": 99])
    }

    /// A zero or negative observation carries no information about capacity.
    @Test func raisingIgnoresNonPositiveObservations() {
        let out = SiteAssay.raising(["conductive": 331], with: ["conductive": 0, "rares": -5])
        #expect(out == ["conductive": 331])
    }

    @Test func impliedTotalDividesRemainingByThePercentage() {
        let total = SiteAssay.impliedTotal(remaining: 132.4, percentRemaining: 40)
        #expect(total == 331)
    }

    /// At 0% the remaining amount is 0 and tells us nothing about capacity —
    /// and dividing by it would produce an infinity.
    @Test func impliedTotalIsNilAtZeroPercent() {
        #expect(SiteAssay.impliedTotal(remaining: 0, percentRemaining: 0) == nil)
        #expect(SiteAssay.impliedTotal(remaining: 10, percentRemaining: -1) == nil)
    }

    @Test func systemIsTheLeadingSegmentOfADesignation() {
        #expect(SiteAssay.system(of: "TAANSI-6-5-SAL-1") == "TAANSI")
        #expect(SiteAssay.system(of: "TAANSI") == "TAANSI")
        #expect(SiteAssay.system(of: "") == "")
    }
}
