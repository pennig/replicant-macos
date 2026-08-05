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

    /// One distinct pile per controller, richest first: each controller in
    /// `controllers` is paired with the next-best location in `footprints` it
    /// may legally drain into `delivery`, given the mesh membership in
    /// `meshSystems`.
    ///
    /// `footprints` is designation → total units, straight off
    /// `LocationFootprint.resources`. Recompute it from scratch every cycle and
    /// never cache it: the census moves under the run as the Salvage Run mines
    /// and the haulers drain, so a remembered ranking is wrong within minutes.
    ///
    /// Surplus controllers are returned NO assignment rather than being doubled
    /// up onto the richest pile — two controllers on one pile put their drones in
    /// contention for the same units, and an idle controller is the cheaper
    /// failure.
    public static func assignments(
        controllers: [Device],
        footprints: [String: Int],
        meshSystems: Set<String>,
        delivery: String
    ) -> [Assignment] {
        let deliverySystem = SiteAssay.system(of: delivery)

        let candidates = footprints
            .filter { location, units in
                guard units > 0, location != delivery else { return false }
                let system = SiteAssay.system(of: location)
                // Same system: `shuttle`, and the mesh is irrelevant because
                // nothing crosses a star. Different system: `ferry`, which needs
                // BOTH ends meshed — the delivery end included, since a mesh is
                // only useful if the destination is on it too.
                if system == deliverySystem { return true }
                return meshSystems.contains(system) && meshSystems.contains(deliverySystem)
            }
            // Richest first, then designation so the order is TOTAL. Without the
            // tiebreak two equally-rich piles could swap places between
            // evaluations and the run would re-issue `set_directive` forever.
            .sorted { lhs, rhs in
                lhs.value != rhs.value ? lhs.value > rhs.value : lhs.key < rhs.key
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
