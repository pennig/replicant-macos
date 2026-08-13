//
//  MineSitePlanner.swift
//  Replicould — DirectiveEngine
//
//  Ranks candidate belts for a new permanent mine: class, then a demand-weighted
//  scarcity bonus, then distance from the nearest theatre, then designation.
//

import Foundation
import GameModels
import UniverseModels

public enum MineSitePlanner {
    /// One rankable belt, with the rank terms exposed for the why-view.
    public struct Candidate: Equatable, Sendable {
        public let belt: String
        public let system: String
        public let beltClass: BeltClass
        public let scarceBonus: Int
        public let distanceLY: Double
        /// The reading the bonus was scored under, for the why-view.
        public let headroom: ResourceHeadroom
    }

    /// The belt's score under `weights`: each weighted type present at ≥
    /// moderate adds its points. Unweighted types add nothing.
    public static func scarceBonus(
        richness: [String: String],
        weights: [String: Int] = ResourceHeadroom.staticWeights
    ) -> Int {
        weights.reduce(0) { total, entry in
            atLeastModerate(richness[entry.key]) ? total + entry.value : total
        }
    }

    private static func atLeastModerate(_ qualifier: String?) -> Bool {
        switch qualifier {
        case "moderate", "high", "rich": true
        default: false
        }
    }

    /// The best belt for a new mine, or nil when nothing passes the hard
    /// filters: meshed, unoccupied, classifiable, placeable. Ranked OUTWARD
    /// from each candidate's own nearest theatre — there is no row to read.
    public static func site(
        view: WorldView,
        occupiedBelts: Set<String>,
        headroom: ResourceHeadroom = .staticFallback
    ) -> Candidate? {
        var candidates: [Candidate] = []
        for (system, belts) in view.beltsBySystem {
            guard view.meshSystems.contains(system),
                  let position = view.starPositions[system],
                  let theatre = view.theatre(nearest: system),
                  let originPosition = view.starPositions[theatre.system]
            else { continue }
            for belt in belts where !occupiedBelts.contains(belt.designation) {
                candidates.append(Candidate(
                    belt: belt.designation,
                    system: system,
                    beltClass: belt.beltClass,
                    scarceBonus: scarceBonus(richness: belt.richness, weights: headroom.weights),
                    distanceLY: originPosition.distance(to: position),
                    headroom: headroom
                ))
            }
        }
        return candidates.min { lhs, rhs in
            if lhs.beltClass != rhs.beltClass { return lhs.beltClass > rhs.beltClass }
            if lhs.scarceBonus != rhs.scarceBonus { return lhs.scarceBonus > rhs.scarceBonus }
            if lhs.distanceLY != rhs.distanceLY { return lhs.distanceLY < rhs.distanceLY }
            return lhs.belt < rhs.belt
        }
    }
}
