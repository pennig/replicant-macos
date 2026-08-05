//
//  SalvageTargetPlanner.swift
//  Replicould — DirectiveEngine
//
//  Where a Salvage Run goes next. Ranked so the FTL-mesh frontier expands
//  outward under its own steam: prefer a system already on the mesh, then one
//  that a single relay would bring onto it, then the richest, then the nearest.
//
//  Reachability is one hop only, so a system that needs a relay at a NON-salvage
//  waypoint before it comes into range is never offered here at all.
//
//  Pure by contract — no I/O, no clock, no randomness. Must NOT be a static on a
//  SwiftUI `View`: pure logic in that position traps with signal 5 under
//  `swift test`.
//

import Foundation
import GameModels
import UniverseModels

public enum SalvageTargetPlanner {
    /// A relay's maximum edge range. Not a coverage radius — a system is on the
    /// mesh only if it holds its OWN relay; this is how far apart two relays may
    /// be and still link.
    public static let relayRangeLY: Double = 7.5

    /// One candidate system: where to go, what is there, and whether working it
    /// costs a relay.
    public struct Target: Equatable, Sendable {
        /// The system designation the run should aim at next.
        public let system: String
        /// Total assayed units across every salvage body in the system. A floor,
        /// not a total: an unassayed site contributes nothing rather than
        /// pretending to be zero.
        public let units: Double
        /// Whether the system needs a relay planted on arrival: false when it is
        /// already meshed. Advisory — the run re-derives mesh membership from
        /// the device rows it holds when the vessel actually arrives, so a mesh
        /// that changed in flight is honoured rather than this snapshot.
        public let needsRelay: Bool

        public init(system: String, units: Double, needsRelay: Bool) {
            self.system = system
            self.units = units
            self.needsRelay = needsRelay
        }
    }

    /// The systems currently on the mesh: those where `devices` holds a relay
    /// that is actually relaying.
    ///
    /// Membership is derived from device rows, never from the `ftlLinks` table.
    /// A relay that is up but not yet linked to anything produces NO link rows,
    /// so a link-derived set would omit the system this run just meshed — the
    /// one case that matters most here.
    ///
    /// The `features` test is broader than `deviceType == "ftl_relay"` because a
    /// `system_hub` contains an integrated relay and genuinely does mesh its
    /// system. A dispatch query must NOT be written this way: `deploy` would
    /// then be issued at a hub.
    ///
    /// The status test goes through `statusBase`, never raw `status`: the
    /// backend appends a parenthetical parameter to some statuses, and a raw
    /// comparison reads a meshed system as unmeshed — sending the run to spend a
    /// relay on a system that already has one.
    public static func meshSystems(in devices: [Device]) -> Set<String> {
        Set(
            devices
                .filter { $0.features.contains("relay") && $0.statusBase == "relaying" }
                .compactMap(\.location)
                .map { SiteAssay.system(of: $0) }
        )
    }

    /// The next system to work, or nil when nothing is reachable: the best
    /// salvage system in `assays`, positioned through `stars`, that is either in
    /// `meshSystems` or within `relayRange` light-years of a system that is,
    /// excluding everything in `attempted` and breaking ties by distance from
    /// `vessel`.
    ///
    /// `attempted` must carry every system this run has already aimed at, not
    /// just the ones it finished — `Directive.targets` is exactly that set, kept
    /// append-only for this reason. Omitting it breaks two ways that both occur
    /// in practice: the operator's Skip becomes a no-op, and a system that cannot
    /// report itself finished pins the planner on it forever.
    ///
    /// A nil `vessel` ranks every candidate at distance zero, so tied candidates
    /// fall straight through to the designation tiebreak.
    public static func nextTarget(
        assays: [SiteAssay],
        stars: [String: Star],
        meshSystems: Set<String>,
        attempted: Set<String>,
        vessel: Position?,
        relayRange: Double = relayRangeLY
    ) -> Target? {
        // Fold the per-site assays into per-system totals once. `siteType` is
        // filtered rather than assumed: the table is shared with mining assays,
        // and one of those would otherwise send a salvage run to a system
        // holding no salvage at all. `depleted` assays are excluded too: a
        // drained site's `totals` only ever go UP (merge-only-raises), so units
        // can never fall back to zero on their own — the `depleted` flag is the
        // only signal that removes a spent site from ranking, and without it a
        // fully-drained system could still win on units alone.
        var units: [String: Double] = [:]
        for assay in assays
        where assay.siteType == "salvage" && !assay.depleted && !attempted.contains(assay.system) {
            units[assay.system, default: 0] += assay.totals.values.reduce(0, +)
        }

        // The relay positions that define the current frontier.
        let relayPositions = meshSystems.compactMap { stars[$0]?.position }

        var best: Target?
        var bestKey: RankKey?
        for (system, systemUnits) in units {
            guard let star = stars[system] else { continue }
            let position = star.position
            let meshed = meshSystems.contains(system)
            // One hop means: a relay planted HERE would link to an existing one.
            let reachable = meshed || relayPositions.contains { $0.distance(to: position) <= relayRange }
            guard reachable else { continue }

            let key = RankKey(
                meshedRank: meshed ? 0 : 1,
                units: systemUnits,
                distance: vessel.map { $0.distance(to: position) } ?? 0,
                designation: system
            )
            if let bestKey, !key.beats(bestKey) { continue }
            bestKey = key
            best = Target(system: system, units: systemUnits, needsRelay: !meshed)
        }
        return best
    }

    /// The ranking, in one place so the ordering is total and reproducible:
    /// meshed first, then most units, then nearest, then designation. The final
    /// key exists so two equal candidates always resolve the same way across
    /// evaluations — without it a run could oscillate between them.
    private struct RankKey {
        /// 0 for an already-meshed system, 1 for one a relay must be planted at.
        let meshedRank: Int
        let units: Double
        let distance: Double
        let designation: String

        /// Whether `self` outranks `other` under that ordering.
        func beats(_ other: RankKey) -> Bool {
            if meshedRank != other.meshedRank { return meshedRank < other.meshedRank }
            if units != other.units { return units > other.units }
            if distance != other.distance { return distance < other.distance }
            return designation < other.designation
        }
    }
}
