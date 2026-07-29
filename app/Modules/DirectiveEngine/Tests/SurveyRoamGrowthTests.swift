//
//  SurveyRoamGrowthTests.swift
//  DirectiveEngineTests
//
//  The property the roam planner exists for, rather than any single decision it
//  makes: surveying always stays within one band width of complete.
//
//  Stated precisely — at every moment, (the radius of the farthest system
//  surveyed) minus (the radius of the nearest system NOT surveyed) is at most
//  one band width. That is the bound greedy nearest-neighbour violates by 4x on
//  real data, and it is the entire justification for spending +35% travel.
//
//  Note what is deliberately NOT asserted: that the filled radius rises
//  monotonically. It does, but only trivially — the filled radius is a minimum
//  over the unsurveyed set, and removing elements from a set can only raise its
//  minimum. Asserting it would pass for any planner whatsoever, including one
//  that picks at random.
//

import Foundation
import Testing
import UniverseModels

@testable import DirectiveEngine

@Suite("Survey roam growth")
struct SurveyRoamGrowthTests {
    private func star(_ designation: String, x: Double, y: Double, z: Double) -> Star {
        Star(
            designation: designation, spectralType: "G", color: "yellow",
            positionX: x, positionY: y, positionZ: z, estimatedPlanets: 3,
            explored: false, hasLife: nil, entryPoint: nil,
            createdAt: Date(timeIntervalSince1970: 0),
            firstVisitedAt: nil, fullyScannedAt: nil
        )
    }

    /// A deterministic pseudo-random star field in a cube of side 60 centred on
    /// the origin. A fixed LCG rather than `SystemRandomNumberGenerator`: a
    /// property test that fails must fail identically on the next run, or the
    /// failure cannot be investigated.
    private func fixtureCensus(count: Int) -> [Star] {
        var seed: UInt64 = 0x2545_F491_4F6C_DD1D
        func nextUnit() -> Double {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(seed >> 11) / Double(1 << 53)
        }
        return (0..<count).map { index in
            star(
                "S\(index)",
                x: nextUnit() * 60 - 30,
                y: nextUnit() * 60 - 30,
                z: nextUnit() * 60 - 30
            )
        }
    }

    private let centre = Position(x: 0, y: 0, z: 0)

    /// Run `steps` survey cycles and return the worst gap that ever opened
    /// behind the frontier.
    ///
    /// `pick` is the strategy under test, so the banded planner and a greedy
    /// control run through byte-identical simulation machinery — otherwise a
    /// difference in outcome could come from the harness rather than the
    /// strategy.
    private func worstHole(
        stars initial: [Star],
        steps: Int,
        pick: (_ vessel: Position, _ stars: [Star], _ attempted: Set<String>) -> String?
    ) -> Double {
        var stars = initial
        var attempted: Set<String> = []
        var vessel = centre
        var frontier = 0.0
        var worst = 0.0

        for _ in 0..<steps {
            guard let target = pick(vessel, stars, attempted),
                  let index = stars.firstIndex(where: { $0.designation == target })
            else { break }

            // Surveying it stamps the census row AND records the attempt, which
            // is exactly what the production path does (`SystemDetail.persist`
            // stamps `fullyScannedAt`; the engine appends to `targets`).
            stars[index].fullyScannedAt = Date(timeIntervalSince1970: 1)
            attempted.insert(target)
            vessel = stars[index].position
            frontier = max(frontier, stars[index].position.distance(to: centre))

            let filled = stars
                .filter { $0.fullyScannedAt == nil }
                .map { $0.position.distance(to: centre) }
                .min()
            guard let filled else { break }
            worst = max(worst, frontier - filled)
        }
        return worst
    }

    private func bandedPick(
        _ vessel: Position, _ stars: [Star], _ attempted: Set<String>
    ) -> String? {
        SurveyRoamPlanner.nextTarget(
            centre: centre, from: vessel, stars: stars, attempted: attempted
        )
    }

    /// Greedy nearest-neighbour: the same simulation with the band removed.
    private func greedyPick(
        _ vessel: Position, _ stars: [Star], _ attempted: Set<String>
    ) -> String? {
        stars
            .filter { $0.fullyScannedAt == nil && !attempted.contains($0.designation) }
            .min {
                let a = $0.position.distance(to: vessel), b = $1.position.distance(to: vessel)
                return a == b ? $0.designation < $1.designation : a < b
            }?
            .designation
    }

    @Test func neverLeavesAGapDeeperThanOneBandWidth() {
        let hole = worstHole(stars: fixtureCensus(count: 300), steps: 120, pick: bandedPick)
        // A hair of slack for the sqrt round-trip in the band-edge comparison.
        #expect(hole <= SurveyRoamPlanner.shellWidthLY + 1e-9)
    }

    /// The control. Without it `neverLeavesAGapDeeperThanOneBandWidth` could
    /// pass on a planner that never moves, or on a fixture too sparse for any
    /// gap to open — neither of which would be measuring anything.
    @Test func greedyNearestNeighbourViolatesTheBoundOnTheSameFixture() {
        let hole = worstHole(stars: fixtureCensus(count: 300), steps: 120, pick: greedyPick)
        #expect(hole > SurveyRoamPlanner.shellWidthLY)
    }
}
