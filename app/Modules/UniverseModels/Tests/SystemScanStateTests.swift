//
//  SystemScanStateTests.swift
//  UniverseModelsTests
//
//  The one definition of "this system is completely surveyed". Its bias is
//  deliberate and load-bearing: unknown counts are never "scanned", because
//  re-surveying a done system costs one wasted trip while skipping an unscanned
//  one silently loses the point of the survey.
//

import Foundation
import Testing

@testable import UniverseModels

@Suite("System scan state")
struct SystemScanStateTests {
    private func system(
        planetsScanned: Int? = nil, planetsTotal: Int? = nil,
        moonsScanned: Int? = nil, moonsTotal: Int? = nil
    ) -> StarSystem {
        StarSystem(
            designation: "SOL",
            planetsScanned: planetsScanned, planetsTotal: planetsTotal,
            moonsScanned: moonsScanned, moonsTotal: moonsTotal
        )
    }

    @Test func everyPlanetScannedAndNoMoonsReportedIsFull() {
        #expect(system(planetsScanned: 6, planetsTotal: 6).isFullyScanned)
    }

    @Test func everyPlanetAndEveryMoonScannedIsFull() {
        #expect(
            system(planetsScanned: 6, planetsTotal: 6, moonsScanned: 14, moonsTotal: 14)
                .isFullyScanned
        )
    }

    @Test func planetsShortIsNotFull() {
        #expect(!system(planetsScanned: 5, planetsTotal: 6).isFullyScanned)
    }

    /// The case a `recon`-column shortcut gets wrong: `recon == .scanned` is
    /// computed from planets alone, so a system with every planet but not every
    /// moon reads as scanned there while still being real survey work.
    @Test func moonsShortIsNotFull() {
        #expect(
            !system(planetsScanned: 6, planetsTotal: 6, moonsScanned: 11, moonsTotal: 14)
                .isFullyScanned
        )
    }

    @Test func unknownMoonsScannedAgainstAKnownTotalIsNotFull() {
        #expect(
            !system(planetsScanned: 6, planetsTotal: 6, moonsScanned: nil, moonsTotal: 14)
                .isFullyScanned
        )
    }

    @Test func unknownCountsAreNeverFull() {
        #expect(!system().isFullyScanned)
        #expect(!system(planetsScanned: nil, planetsTotal: 6).isFullyScanned)
    }

    @Test func zeroPlanetTotalIsNeverFull() {
        #expect(!system(planetsScanned: 0, planetsTotal: 0).isFullyScanned)
    }

    /// A moon total of zero is "no moons to scan", not an unmet requirement.
    @Test func zeroMoonTotalDoesNotBlockFullness() {
        #expect(
            system(planetsScanned: 6, planetsTotal: 6, moonsScanned: 0, moonsTotal: 0)
                .isFullyScanned
        )
    }
}
