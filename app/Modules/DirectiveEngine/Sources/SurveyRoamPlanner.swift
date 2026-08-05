//
//  SurveyRoamPlanner.swift
//  Replicould — DirectiveEngine
//
//  Where a continuous Survey Run goes next: the cheapest hop inside an
//  expanding band of unsurveyed systems around a fixed centre.
//
//  Pure by contract — no I/O, no clock, no randomness — so it tests as plain
//  function calls over fixtures. It must NOT be a static on a SwiftUI `View`:
//  pure logic in that position traps with signal 5 under `swift test` (see the
//  swiftui-view-statics-trap-in-tests note).
//

import Foundation
import UniverseModels

public enum SurveyRoamPlanner {
    /// The band thickness in light-years — the one dial between travel and
    /// density. Widening it approaches greedy nearest-neighbour, which travels
    /// least and leaves permanent holes behind the frontier; narrowing it
    /// approaches strict radial order, which leaves none at several times the
    /// travel.
    public static let shellWidthLY: Double = 5

    /// The next system a continuous run should survey, or nil when nothing is
    /// left: the star in `stars` nearest `vessel` among those lying within
    /// `shellWidth` of the innermost unsurveyed system's distance from `centre`,
    /// skipping everything in `attempted`.
    ///
    /// Two distances, measured from two different points and required to stay
    /// that way: membership of the band is measured from `centre` (that is what
    /// bounds the holes), and the pick within the band is measured from `vessel`
    /// (that is what keeps the hop cheap). Collapsing them onto one point gives
    /// either greedy nearest-neighbour or strict radial order — the two things
    /// the band exists to sit between.
    ///
    /// The band SLIDES: its outer edge is `inner + shellWidth`, anchored on the
    /// innermost remaining candidate rather than on a fixed grid of annuli, so
    /// it has no boundary case and its guarantee is exactly true — nothing is
    /// ever left behind that is more than `shellWidth` closer to the centre than
    /// the system just picked.
    ///
    /// `attempted` must carry every system this run has already aimed at, not
    /// just the ones it finished. Two failures follow from omitting it, and both
    /// occur in practice: `StarSystem.isFullyScanned` requires
    /// `planetsTotal > 0`, so a planetless system can never be marked complete
    /// and would pin `inner` at its own radius forever; and the user's Skip
    /// would be undone, because the next extend would re-pick the system just
    /// skipped. `Directive.targets` is exactly that set.
    public static func nextTarget(
        centre: Position,
        from vessel: Position,
        stars: [Star],
        attempted: Set<String>,
        shellWidth: Double = shellWidthLY
    ) -> String? {
        // Pass 1: how far out the innermost unsurveyed system sits. The band is
        // anchored on it, so it has to be known before membership can be judged.
        var innerSquared = Double.infinity
        for star in stars where isCandidate(star, attempted) {
            innerSquared = min(innerSquared, squaredDistance(star, centre))
        }
        guard innerSquared.isFinite else { return nil }

        // The only `sqrt` in the function: the band's edge is a SUM of
        // distances, which squared distances cannot express.
        let shellTop = innerSquared.squareRoot() + shellWidth
        let shellTopSquared = shellTop * shellTop

        // Pass 2: inside the band, the cheapest hop from where the vessel is.
        var best: (distanceSquared: Double, designation: String)?
        for star in stars where isCandidate(star, attempted) {
            guard squaredDistance(star, centre) <= shellTopSquared else { continue }
            let candidate = (
                distanceSquared: squaredDistance(star, vessel),
                designation: star.designation
            )
            if let best, !isBetter(candidate, than: best) { continue }
            best = candidate
        }
        return best?.designation
    }

    /// Whether `star` is still worth surveying and is not already in
    /// `attempted`.
    private static func isCandidate(_ star: Star, _ attempted: Set<String>) -> Bool {
        star.fullyScannedAt == nil && !attempted.contains(star.designation)
    }

    /// The SQUARED distance from `star` to `point` — the form both passes
    /// compare in, so neither pays a `sqrt` per candidate.
    private static func squaredDistance(_ star: Star, _ point: Position) -> Double {
        let dx = star.positionX - point.x
        let dy = star.positionY - point.y
        let dz = star.positionZ - point.z
        return dx * dx + dy * dy + dz * dz
    }

    /// Whether `lhs` outranks `rhs`: nearer wins, and equal distance breaks on
    /// designation so the order is total and the plan is reproducible across
    /// evaluations.
    private static func isBetter(
        _ lhs: (distanceSquared: Double, designation: String),
        than rhs: (distanceSquared: Double, designation: String)
    ) -> Bool {
        lhs.distanceSquared == rhs.distanceSquared
            ? lhs.designation < rhs.designation
            : lhs.distanceSquared < rhs.distanceSquared
    }
}
