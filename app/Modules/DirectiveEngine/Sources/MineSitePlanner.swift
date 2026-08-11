//
//  MineSitePlanner.swift
//  Replicould — DirectiveEngine
//
//  Ranks candidate belts for a new permanent mine: class, then a rares/conductive
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
    }

    /// Rares ≥ moderate scores 2, conductive ≥ moderate scores 1 — weighted by
    /// how rare each is across charted belts, per the design spec.
    public static func scarceBonus(richness: [String: String]) -> Int {
        var bonus = 0
        if atLeastModerate(richness["rares"]) { bonus += 2 }
        if atLeastModerate(richness["conductive"]) { bonus += 1 }
        return bonus
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
    public static func site(view: WorldView, occupiedBelts: Set<String>) -> Candidate? {
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
                    scarceBonus: scarceBonus(richness: belt.richness),
                    distanceLY: originPosition.distance(to: position)
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
