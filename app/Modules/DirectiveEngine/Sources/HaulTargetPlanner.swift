//
//  HaulTargetPlanner.swift
//  Replicould — DirectiveEngine
//
//  Which stockpile each haul controller drains next. Ranked by size, filtered
//  by the one constraint `ferry` itself imposes — that both ends sit on the FTL
//  mesh — so the planner and the server can never disagree about what is
//  reachable.
//
//  Pure by contract — no I/O, no clock, no randomness. Must NOT be a static on a
//  SwiftUI `View`: pure logic in that position traps with signal 5 under
//  `swift test`.
//

import Foundation
import GameModels
import UniverseModels

public enum HaulTargetPlanner {

    /// One controller's marching orders: drain `location` into the delivery
    /// point using `directive`.
    public struct Assignment: Equatable, Sendable {
        /// The AMI transport controller these orders are issued to.
        public let controllerCode: String
        /// The stockpile designation it should drain.
        public let location: String
        /// `"ferry"` across systems, `"shuttle"` within one. Carried rather than
        /// re-derived so the machine's dispatch and its in-force comparison
        /// cannot drift apart.
        public let directive: String

        public init(controllerCode: String, location: String, directive: String) {
            self.controllerCode = controllerCode
            self.location = location
            self.directive = directive
        }
    }

    /// The interstellar supply line. Requires both systems on the FTL mesh.
    public static let ferry = "ferry"
    /// The in-system supply line, for a pile that shares the delivery system. A
    /// `ferry` whose two ends share a system is malformed, so that case must
    /// come here instead.
    public static let shuttle = "shuttle"

    /// Travel seconds per light-year, for the round-trip ranking. UNCALIBRATED —
    /// see the residual in the spec.
    public static let secondsPerLy: Double = 30

    /// One distinct pile per controller, richest-per-round-trip first, filtered to
    /// `delivery`'s mesh component. Recompute `footprints` fresh each cycle, never
    /// cache — and leave surplus controllers unassigned rather than sharing a pile.
    public static func assignments(
        controllers: [Device],
        footprints: [String: Int],
        components: [String: String],
        positions: [String: Position],
        delivery: String,
        secondsPerLy: Double = HaulTargetPlanner.secondsPerLy
    ) -> [Assignment] {
        let deliverySystem = SiteAssay.system(of: delivery)
        let deliveryComponent = components[deliverySystem]

        func roundTripRank(_ location: String, units: Int) -> Double {
            let system = SiteAssay.system(of: location)
            guard system != deliverySystem else { return .infinity }
            guard let from = positions[system], let to = positions[deliverySystem] else {
                // Unplaceable: degrade to raw units rather than dropping a real
                // pile because the census has a hole.
                return Double(units)
            }
            let seconds = 2 * from.distance(to: to) * secondsPerLy
            return seconds > 0 ? Double(units) / seconds : .infinity
        }

        let candidates = footprints
            .filter { location, units in
                guard units > 0, location != delivery else { return false }
                let system = SiteAssay.system(of: location)
                // Same system is always `shuttle` (nothing crosses a star);
                // cross-system `ferry` needs both ends in the SAME component.
                if system == deliverySystem { return true }
                return components[system] != nil && components[system] == deliveryComponent
            }
            // Richest-per-round-trip first, designation as tie-break — a TOTAL
            // order, or two equally-ranked piles could thrash `set_directive`.
            .sorted { lhs, rhs in
                let (l, r) = (roundTripRank(lhs.key, units: lhs.value), roundTripRank(rhs.key, units: rhs.value))
                return l != r ? l > r : lhs.key < rhs.key
            }

        // Controllers sorted so the same controller keeps the same rank across
        // evaluations — otherwise a dictionary's iteration order alone could
        // reshuffle assignments and thrash the fleet.
        let ordered = controllers.sorted { $0.deviceCode < $1.deviceCode }

        return zip(ordered, candidates).map { controller, candidate in
            let system = SiteAssay.system(of: candidate.key)
            return Assignment(
                controllerCode: controller.deviceCode,
                location: candidate.key,
                directive: system == deliverySystem ? shuttle : ferry
            )
        }
    }
}
