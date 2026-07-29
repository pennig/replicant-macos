//
//  SurveyRoamPlannerTests.swift
//  DirectiveEngineTests
//
//  The continuous run's target selection. Pure function over fixtures, the same
//  shape as SurveyRun's stall matrix and the launcher's suggestions.
//
//  Every fixture lies on the X axis and every distance below is exactly
//  representable in binary floating point, so the band-edge cases assert real
//  boundary behaviour rather than an ULP coin flip.
//

import Foundation
import Testing
import UniverseModels

@testable import DirectiveEngine

@Suite("Survey roam planner")
struct SurveyRoamPlannerTests {
    /// A census row `x` light-years out along the X axis.
    private func star(_ designation: String, x: Double, scanned: Bool = false) -> Star {
        Star(
            designation: designation, spectralType: "G", color: "yellow",
            positionX: x, positionY: 0, positionZ: 0, estimatedPlanets: 3,
            explored: false, hasLife: nil, entryPoint: nil,
            createdAt: Date(timeIntervalSince1970: 0),
            firstVisitedAt: nil,
            fullyScannedAt: scanned ? Date(timeIntervalSince1970: 1) : nil
        )
    }

    private func pick(
        _ stars: [Star],
        vesselX: Double,
        centreX: Double = 0,
        attempted: Set<String> = []
    ) -> String? {
        SurveyRoamPlanner.nextTarget(
            centre: Position(x: centreX, y: 0, z: 0),
            from: Position(x: vesselX, y: 0, z: 0),
            stars: stars,
            attempted: attempted
        )
    }

    /// The test that distinguishes this design from greedy nearest-neighbour at
    /// all: a candidate sitting right next to the vessel is passed over because
    /// it is outside the band. Without this the planner could be a plain
    /// nearest-neighbour and every other test here would still pass.
    @Test func passesOverANearerCandidateOutsideTheBand() {
        let stars = [star("INNER", x: 1), star("EDGE", x: 5.5), star("FAR", x: 20)]
        // inner = 1, band = [0, 6]. FAR is 0 ly from the vessel but out of band.
        #expect(pick(stars, vesselX: 20) == "EDGE")
    }

    /// The band slides with the innermost remaining candidate rather than
    /// sitting on a fixed grid of annuli around the centre.
    @Test func slidesTheBandOntoTheInnermostCandidate() {
        let stars = [star("A", x: 10), star("B", x: 14), star("C", x: 20)]
        // inner = 10, band = [10, 15]. C is nearest the vessel but out of band.
        #expect(pick(stars, vesselX: 100) == "B")
    }

    @Test func includesACandidateExactlyOneBandWidthOut() {
        let stars = [star("INNER", x: 3), star("EDGE", x: 8)]
        // inner = 3, band top = 8 exactly. sqrt(9) == 3 and 8*8 == 64 are both
        // exact, so this is a true boundary assertion.
        #expect(pick(stars, vesselX: 1000) == "EDGE")
    }

    @Test func excludesACandidateJustBeyondTheBand() {
        let stars = [star("INNER", x: 3), star("EDGE", x: 8.001)]
        #expect(pick(stars, vesselX: 1000) == "INNER")
    }

    /// The centre is a geometric origin, not the vessel's position, so an
    /// unsurveyed centre is surveyed first — at zero travel.
    @Test func treatsTheCentreItselfAsACandidate() {
        let stars = [star("HOME", x: 0), star("A", x: 2)]
        #expect(pick(stars, vesselX: 0) == "HOME")
    }

    @Test func excludesFullyScannedSystems() {
        let stars = [star("DONE", x: 1, scanned: true), star("TODO", x: 2)]
        #expect(pick(stars, vesselX: 0) == "TODO")
    }

    /// The exclusion that stops an uncompletable system pinning the band and
    /// stops the user's Skip being undone on the next extend.
    @Test func excludesAlreadyAttemptedSystems() {
        let stars = [star("TRIED", x: 1), star("NEXT", x: 2)]
        #expect(pick(stars, vesselX: 0, attempted: ["TRIED"]) == "NEXT")
    }

    @Test func returnsNilWhenNothingIsLeftToSurvey() {
        let stars = [star("DONE", x: 1, scanned: true), star("TRIED", x: 2)]
        #expect(pick(stars, vesselX: 0, attempted: ["TRIED"]) == nil)
    }

    @Test func returnsNilForAnEmptyCensus() {
        #expect(pick([], vesselX: 0) == nil)
    }

    /// A total order is what makes the plan reproducible: two equidistant
    /// candidates must not swap between evaluations.
    @Test func breaksTiesOnDesignation() {
        let stars = [star("ZULU", x: 3), star("ALPHA", x: -3)]
        #expect(pick(stars, vesselX: 0) == "ALPHA")
    }

    @Test func measuresTheBandFromTheCentreNotTheVessel() {
        let stars = [star("NEARCENTRE", x: 2), star("NEARVESSEL", x: 40)]
        // Centre at 0: inner = 2, band = [0, 7]. The vessel sitting on top of
        // NEARVESSEL cannot pull it into the band.
        #expect(pick(stars, vesselX: 40, centreX: 0) == "NEARCENTRE")
    }
}
