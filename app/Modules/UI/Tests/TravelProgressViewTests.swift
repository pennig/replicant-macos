//
//  TravelProgressViewTests.swift
//  Replicould — UI
//
//  The segmented travel bar's geometry is pure arithmetic: lay legs out along a
//  normalized 0...1 axis weighted by duration, fill each leg from a single
//  sweeping progress value, and caption the active leg. These tests pin that
//  math (including the zero-weight and boundary cases) plus the shared
//  `OperationProgressView` fraction/ETA helpers the bar reuses — none of it
//  needs a rendered view.
//

import Foundation
import Testing
@testable import UI

@Suite struct TravelProgressViewTests {

    private typealias Segment = TravelBar.Segment

    private func segment(_ id: Int, _ weight: Double, type: String? = nil, from: String? = nil, to: String? = nil) -> Segment {
        Segment(id: id, weight: weight, type: type, from: from, to: to)
    }

    // MARK: Band layout

    @Test func bandsSpanTheWholeAxisProportionally() {
        // Weights 3 : 1 → spans [0, 0.75) and [0.75, 1].
        let bands = TravelBar.bands(for: [segment(1, 3), segment(2, 1)])
        #expect(bands.count == 2)
        #expect(bands[0].start == 0)
        #expect(bands[0].end == 0.75)
        #expect(bands[1].start == 0.75)
        #expect(bands[1].end == 1)
    }

    @Test func bandsPreserveSegmentIdentityAndOrder() {
        let bands = TravelBar.bands(for: [segment(7, 1), segment(4, 1)])
        #expect(bands.map(\.id) == [7, 4])
    }

    @Test func singleSegmentFillsTheWholeAxis() {
        let bands = TravelBar.bands(for: [segment(1, 1233)])
        #expect(bands.count == 1)
        #expect(bands[0].start == 0)
        #expect(bands[0].end == 1)
    }

    @Test func zeroWeightSegmentsFallBackToEqualShares() {
        // No usable durations → three equal thirds rather than a divide-by-zero.
        let bands = TravelBar.bands(for: [segment(1, 0), segment(2, 0), segment(3, 0)])
        #expect(bands.count == 3)
        #expect(abs(bands[0].end - 1.0 / 3.0) < 1e-9)
        #expect(abs(bands[1].end - 2.0 / 3.0) < 1e-9)
        #expect(abs(bands[2].end - 1.0) < 1e-9)
    }

    @Test func emptyRouteYieldsNoBands() {
        #expect(TravelBar.bands(for: []).isEmpty)
    }

    // MARK: Fill

    @Test func fillIsFullForBandsFullyBehindProgress() {
        let bands = TravelBar.bands(for: [segment(1, 1), segment(2, 1)])
        // Progress at 0.75 → first band (ends 0.5) full, second (0.5...1) half.
        #expect(bands[0].fill(at: 0.75) == 1)
        #expect(abs(bands[1].fill(at: 0.75) - 0.5) < 1e-9)
    }

    @Test func fillIsEmptyForBandsAheadOfProgress() {
        let bands = TravelBar.bands(for: [segment(1, 1), segment(2, 1)])
        #expect(bands[1].fill(at: 0.25) == 0)
    }

    @Test func fillClampsAtBothEnds() {
        let bands = TravelBar.bands(for: [segment(1, 1)])
        #expect(bands[0].fill(at: -0.5) == 0)
        #expect(bands[0].fill(at: 2) == 1)
    }

    // MARK: Active caption

    @Test func activeCaptionDescribesTheLegUnderWay() {
        let bands = TravelBar.bands(for: [
            segment(1, 1, type: "surge", from: "SOL-5-L4", to: "ATIANFU-1-L4"),
            segment(2, 1, type: "cruise", from: "ATIANFU-1-L4", to: "ATIANFU-BELT-1"),
        ])
        // Still in the first leg.
        #expect(TravelBar.activeCaption(bands, progress: 0.25) == "Surge · SOL-5-L4 → ATIANFU-1-L4")
        // Into the second leg.
        #expect(TravelBar.activeCaption(bands, progress: 0.75) == "Cruise · ATIANFU-1-L4 → ATIANFU-BELT-1")
    }

    @Test func activeCaptionFallsBackToLastLegWhenComplete() {
        let bands = TravelBar.bands(for: [
            segment(1, 1, type: "surge", to: "A"),
            segment(2, 1, type: "cruise", to: "B"),
        ])
        // progress ≥ 1 is past every band's end → the last leg.
        #expect(TravelBar.activeCaption(bands, progress: 1) == "Cruise · B")
    }

    @Test func activeCaptionOmitsMissingPieces() {
        let bands = TravelBar.bands(for: [segment(1, 1, to: "ATIANFU-1-L4")])
        // Type absent, no `from` → just the destination.
        #expect(TravelBar.activeCaption(bands, progress: 0) == "ATIANFU-1-L4")
    }

    @Test func activeCaptionIsNilWithNoDescribableLeg() {
        let bands = TravelBar.bands(for: [segment(1, 1)])
        #expect(TravelBar.activeCaption(bands, progress: 0) == nil)
        #expect(TravelBar.activeCaption([], progress: 0) == nil)
    }

    // MARK: Shared progress helpers (reused from OperationProgressView)

    @Test func fractionIsElapsedShareClampedToUnitInterval() {
        let start = Date(timeIntervalSince1970: 0)
        let end = Date(timeIntervalSince1970: 100)
        #expect(ProgressMath.fraction(now: Date(timeIntervalSince1970: 25), start: start, end: end) == 0.25)
        #expect(ProgressMath.fraction(now: Date(timeIntervalSince1970: -10), start: start, end: end) == 0)
        #expect(ProgressMath.fraction(now: Date(timeIntervalSince1970: 200), start: start, end: end) == 1)
    }

    @Test func fractionIsFullForNonPositiveSpan() {
        let instant = Date(timeIntervalSince1970: 100)
        #expect(ProgressMath.fraction(now: instant, start: instant, end: instant) == 1)
    }

    @Test func etaTextFormatsRemainingTime() {
        let now = Date(timeIntervalSince1970: 0)
        #expect(ProgressMath.etaText(now: now, end: Date(timeIntervalSince1970: 45)) == "ETA 45s")
        #expect(ProgressMath.etaText(now: now, end: Date(timeIntervalSince1970: 125)) == "ETA 2m 5s")
        #expect(ProgressMath.etaText(now: now, end: now) == "Arriving…")
    }
}
