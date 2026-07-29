//
//  SurveyRoamPlanner.swift
//  Replicould — DirectiveEngine
//
//  Where a continuous Survey Run goes next: the cheapest hop inside an
//  expanding band of unsurveyed systems around a fixed centre.
//
//  Why not simply the nearest unsurveyed system? Because that is greedy
//  nearest-neighbour, and measured over the real census it never recovers from
//  its first skip. From ATIANFU it passed a system 3.9 ly out, found a cheaper
//  hop, and in 120 systems and 483 ly of travel never came back — leaving gaps
//  22 ly deep behind the frontier. Banding costs ~35% more travel and holds the
//  worst gap to one band width, which is affordable because travel is not the
//  bottleneck: the server's own travel ETAs run 1–3 minutes against a survey
//  cycle of tens of minutes.
//
//  Pure by contract — no I/O, no clock, no randomness — so it tests as plain
//  function calls over fixtures. It must NOT be a static on a SwiftUI `View`:
//  pure logic in that position traps with signal 5 under `swift test` (see the
//  swiftui-view-statics-trap-in-tests note).
//

import Foundation
import UniverseModels

public enum SurveyRoamPlanner {
    /// The band thickness — the one dial between travel and density. Wider
    /// approaches greedy nearest-neighbour (cheapest, leaves permanent holes
    /// 22 ly deep); narrower approaches strict radial order (no holes, 3x the
    /// travel). Measured at 5 ly: +35% travel over greedy, buying a filled
    /// radius of 16.4 ly against greedy's 3.9.
    public static let shellWidthLY: Double = 5

    /// The next system a continuous run should survey, or nil when nothing is
    /// left.
    ///
    /// Two distances, deliberately measured from two different points:
    /// membership of the band is measured from `centre` (that is what bounds the
    /// holes), and the pick within the band is measured from `vessel` (that is
    /// what keeps the hop cheap). Collapsing them onto one point gives either
    /// greedy nearest-neighbour or strict radial order — the two things the band
    /// exists to sit between.
    ///
    /// The band SLIDES: its outer edge is `inner + shellWidth`, anchored on the
    /// innermost remaining candidate rather than on a fixed grid of annuli. A
    /// grid was measured within ~8% on travel at the same hole bound, and lost
    /// on specification — a candidate landing exactly on a grid line opens a
    /// double-width band, whereas a sliding band has no boundary case and makes
    /// the guarantee exactly true: nothing is ever left behind that is more than
    /// `shellWidth` closer to the centre than the system just picked.
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
        // anchored on it, so it has to be known before membership can be judged
        // — which is also why a bounding-box pre-filter cannot help here.
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

    /// Still worth surveying, and not something this run has already tried.
    private static func isCandidate(_ star: Star, _ attempted: Set<String>) -> Bool {
        star.fullyScannedAt == nil && !attempted.contains(star.designation)
    }

    private static func squaredDistance(_ star: Star, _ point: Position) -> Double {
        let dx = star.positionX - point.x
        let dy = star.positionY - point.y
        let dz = star.positionZ - point.z
        return dx * dx + dy * dy + dz * dz
    }

    /// Nearer wins; equal distance breaks on designation so the order is total
    /// and the plan is reproducible across evaluations.
    private static func isBetter(
        _ lhs: (distanceSquared: Double, designation: String),
        than rhs: (distanceSquared: Double, designation: String)
    ) -> Bool {
        lhs.distanceSquared == rhs.distanceSquared
            ? lhs.designation < rhs.designation
            : lhs.distanceSquared < rhs.distanceSquared
    }
}
