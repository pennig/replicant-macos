//
//  SurveyTargetSuggestions.swift
//  Replicould — DirectiveEngine
//
//  What the New Survey Run launcher offers before you have typed anything: the
//  five nearest systems still worth surveying, measured from the vessel you
//  picked.
//
//  Pure by contract — no I/O, no clock, no randomness — so it tests as plain
//  function calls over fixtures, the same way `SurveyRun`'s stall matrix does.
//  It must NOT be a static on a SwiftUI `View`: pure logic in that position
//  traps with signal 5 under `swift test` (see the
//  swiftui-view-statics-trap-in-tests note).
//
//  "Still worth surveying" is `Star.fullyScannedAt == nil`, one nullable column
//  on rows the launcher already holds. That is only trustworthy because every
//  catalog write now stamps it (`SystemDetail.persist`); before that the column
//  was null on all 14,122 rows.
//

import Foundation
import UniverseModels

public enum SurveyTargetSuggestions {
    /// How many systems to offer. Five is the launcher's whole suggestion budget.
    public static let count = 5

    public struct Suggestion: Equatable, Sendable, Identifiable {
        public let designation: String
        /// Straight-line distance from the anchor, in light-years — the map's
        /// world unit.
        public let distanceLY: Double
        public var id: String { designation }

        public init(designation: String, distanceLY: Double) {
            self.designation = designation
            self.distanceLY = distanceLY
        }
    }

    /// The nearest systems to `anchor` that are neither already queued nor
    /// already fully surveyed, nearest first.
    ///
    /// Distances are always measured from the anchor and never re-based onto the
    /// growing queue, so adding a target removes it and pulls in the
    /// next-nearest rather than reshuffling the whole list.
    ///
    /// Selection is a single pass keeping the best `limit` by SQUARED distance:
    /// the census runs to 14,000+ rows, so a full sort (or a `sqrt` per
    /// candidate) would be paid on every keystroke that re-renders the picker.
    /// `sqrt` is applied only to the handful that survive.
    ///
    /// Ties break on designation. That is not cosmetic — a stable list is the
    /// point, and two equidistant stars must not swap places between renders.
    public static func nearest(
        to anchor: Position,
        anchorDesignation: String,
        stars: [Star],
        excluding queued: Set<String>,
        limit: Int = count
    ) -> [Suggestion] {
        guard limit > 0 else { return [] }

        // (squared distance, designation) — the sort key, cheapest form first.
        var best: [(distanceSquared: Double, designation: String)] = []
        best.reserveCapacity(limit + 1)

        for star in stars {
            let designation = star.designation
            guard designation != anchorDesignation,
                  star.fullyScannedAt == nil,
                  !queued.contains(designation)
            else { continue }

            let dx = star.positionX - anchor.x
            let dy = star.positionY - anchor.y
            let dz = star.positionZ - anchor.z
            let candidate = (
                distanceSquared: dx * dx + dy * dy + dz * dz, designation: designation
            )

            // Cheap reject: once the shortlist is full, anything worse than its
            // tail cannot make it. This is what keeps the pass linear.
            if best.count == limit, !isBetter(candidate, than: best[limit - 1]) { continue }

            let index = best.firstIndex { isBetter(candidate, than: $0) } ?? best.count
            best.insert(candidate, at: index)
            if best.count > limit { best.removeLast() }
        }

        return best.map {
            Suggestion(designation: $0.designation, distanceLY: $0.distanceSquared.squareRoot())
        }
    }

    /// Nearer wins; equal distance breaks on designation so the order is total
    /// and therefore stable.
    private static func isBetter(
        _ lhs: (distanceSquared: Double, designation: String),
        than rhs: (distanceSquared: Double, designation: String)
    ) -> Bool {
        lhs.distanceSquared == rhs.distanceSquared
            ? lhs.designation < rhs.designation
            : lhs.distanceSquared < rhs.distanceSquared
    }
}
