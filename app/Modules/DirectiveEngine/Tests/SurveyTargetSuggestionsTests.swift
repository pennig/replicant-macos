//
//  SurveyTargetSuggestionsTests.swift
//  DirectiveEngineTests
//
//  The launcher's nearest-unexplored suggestions. Pure function over fixtures,
//  the same shape as SurveyRun's stall matrix.
//

import Foundation
import Testing
import UniverseModels

@testable import DirectiveEngine

@Suite("Survey target suggestions")
struct SurveyTargetSuggestionsTests {
    /// A census row `x` light-years out along the X axis.
    private func star(_ designation: String, x: Double, fullyScannedAt: Date? = nil) -> Star {
        Star(
            designation: designation, spectralType: "G", color: "yellow",
            positionX: x, positionY: 0, positionZ: 0, estimatedPlanets: 3,
            explored: false, hasLife: nil, entryPoint: nil,
            createdAt: Date(timeIntervalSince1970: 0),
            firstVisitedAt: nil, fullyScannedAt: fullyScannedAt
        )
    }

    private let origin = Position(x: 0, y: 0, z: 0)

    private func nearest(
        _ stars: [Star], excluding queued: Set<String> = [], anchor: String = "HOME"
    ) -> [String] {
        SurveyTargetSuggestions.nearest(
            to: origin, anchorDesignation: anchor, stars: stars, excluding: queued
        ).map(\.designation)
    }

    @Test func returnsTheFiveNearestInAscendingDistanceOrder() {
        let stars = [
            star("FAR", x: 60), star("NEAR", x: 10), star("MID", x: 30),
            star("FARTHER", x: 70), star("NEARER", x: 5), star("MIDDLE", x: 40),
        ]
        #expect(nearest(stars) == ["NEARER", "NEAR", "MID", "MIDDLE", "FAR"])
    }

    @Test func returnsFewerThanFiveWhenCandidatesAreScarce() {
        #expect(nearest([star("A", x: 1), star("B", x: 2)]) == ["A", "B"])
    }

    @Test func excludesTheAnchorsOwnSystem() {
        let stars = [star("HOME", x: 0), star("A", x: 4)]
        #expect(nearest(stars, anchor: "HOME") == ["A"])
    }

    @Test func excludesAlreadyQueuedTargets() {
        let stars = [star("A", x: 1), star("B", x: 2), star("C", x: 3)]
        #expect(nearest(stars, excluding: ["B"]) == ["A", "C"])
    }

    /// The whole point of Part A: a stamped system is done and must not be
    /// offered. A partially scanned one carries no stamp and stays suggestable —
    /// it is genuine survey work.
    @Test func excludesFullyScannedSystems() {
        let stars = [
            star("DONE", x: 1, fullyScannedAt: Date(timeIntervalSince1970: 5)),
            star("PARTIAL", x: 2),
        ]
        #expect(nearest(stars) == ["PARTIAL"])
    }

    /// A stable list is the whole design, so equal distances must not reorder
    /// between calls.
    @Test func breaksDistanceTiesOnDesignation() {
        let stars = [star("ZULU", x: 10), star("ALPHA", x: 10), star("MIKE", x: 10)]
        #expect(nearest(stars) == ["ALPHA", "MIKE", "ZULU"])
    }

    @Test func measuresDistanceInThreeDimensions() {
        let star = Star(
            designation: "PYTH", spectralType: "G", color: "yellow",
            positionX: 3, positionY: 4, positionZ: 0, estimatedPlanets: 1,
            explored: false, hasLife: nil, entryPoint: nil,
            createdAt: Date(timeIntervalSince1970: 0)
        )
        let result = SurveyTargetSuggestions.nearest(
            to: origin, anchorDesignation: "HOME", stars: [star], excluding: []
        )
        #expect(result.first?.distanceLY == 5)
    }

    @Test func honoursAnExplicitLimit() {
        let stars = (1...10).map { star("S\($0)", x: Double($0)) }
        let result = SurveyTargetSuggestions.nearest(
            to: origin, anchorDesignation: "HOME", stars: stars, excluding: [], limit: 3
        )
        #expect(result.map(\.designation) == ["S1", "S2", "S3"])
    }
}
