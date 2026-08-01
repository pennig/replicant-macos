//
//  SalvageTargetPlanner.swift
//  Replicould — DirectiveEngine
//
//  Where a Salvage Run goes next. Ranked so the FTL-mesh frontier expands
//  outward under its own steam: prefer a system already on the mesh, then one
//  that a single relay would bring onto it, then the richest, then the nearest.
//
//  Measured against the live 53-site catalogue on 2026-07-30: planting relays
//  only at salvage systems, richest-first, reaches 10 of 13 systems and 15,650
//  of 20,471 units with 9 relays and no side-trips — TOSLIT's relay brings
//  ARCTURUSAN into range, which brings ABSOLUTN, and so on. Three systems
//  (POLARISUM, ASTELLIO, SOHIMU — 4,821 units) need a relay at a NON-salvage
//  waypoint first and are deliberately never offered here; that errand is Relay
//  Run's, not this planner's.
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

    public struct Target: Equatable, Sendable {
        public let system: String
        /// Total assayed units across every salvage body in the system. A floor,
        /// not a total: an unassayed site contributes nothing rather than
        /// pretending to be zero.
        public let units: Double
        /// Whether the run must plant a relay on arrival. False when the system
        /// is already meshed — the emplace step is skipped entirely.
        public let needsRelay: Bool

        public init(system: String, units: Double, needsRelay: Bool) {
            self.system = system
            self.units = units
            self.needsRelay = needsRelay
        }
    }

    /// The systems currently on the mesh: those holding a relay that is actually
    /// relaying.
    ///
    /// Derived from device rows rather than from the `ftlLinks` table on purpose.
    /// A relay that is up but not yet linked to anything produces NO link rows,
    /// so a link-derived set would omit the system this run just meshed — the
    /// one case that matters most here. Device rows also update the moment the
    /// activation confirm-read lands.
    /// The `features` check is deliberately broader than `ftl_relay`: a
    /// `system_hub` contains an integrated relay and genuinely does mesh its
    /// system, so matching on the capability rather than the device type is
    /// correct HERE — unlike the dispatch-site queries in `SalvageRun`, which
    /// must not `deploy` a hub.
    ///
    /// `statusBase`, not `status`: the backend appends a parenthetical parameter
    /// to some statuses, and a raw comparison would read a meshed system as
    /// unmeshed — sending the run to spend a 370-unit relay on a system that
    /// already has one. `BobnetFeature` uses `statusBase` for the identical
    /// predicate.
    public static func meshSystems(in devices: [Device]) -> Set<String> {
        Set(
            devices
                .filter { $0.features.contains("relay") && $0.statusBase == "relaying" }
                .compactMap(\.location)
                .map { SiteAssay.system(of: $0) }
        )
    }

    /// The next system to work, or nil when nothing is reachable.
    ///
    /// `attempted` must carry every system this run has already aimed at, not
    /// just the ones it finished — `Directive.targets` is exactly that set, kept
    /// append-only for this reason. Omitting it breaks two ways that both occur
    /// in practice: the operator's Skip becomes a no-op, and a system that cannot
    /// report itself finished pins the planner on it forever.
    public static func nextTarget(
        assays: [SiteAssay],
        stars: [String: Star],
        meshSystems: Set<String>,
        attempted: Set<String>,
        vessel: Position?,
        relayRange: Double = relayRangeLY
    ) -> Target? {
        // Fold the per-site assays into per-system totals once. `siteType` is
        // filtered rather than assumed: the table is shared with mining assays
        // by design ("mining assays need no schema change when they land" —
        // `SiteAssay`), and the first one to land would otherwise send a salvage
        // run to a system holding no salvage at all. `depleted` assays are
        // excluded too: a drained site's `totals` only ever go UP (merge-only-
        // raises), so units can never fall back to zero on their own — the
        // `depleted` flag is the only signal that removes a spent site from
        // ranking, and without it a fully-drained system could still win on
        // units alone.
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
        let meshedRank: Int
        let units: Double
        let distance: Double
        let designation: String

        func beats(_ other: RankKey) -> Bool {
            if meshedRank != other.meshedRank { return meshedRank < other.meshedRank }
            if units != other.units { return units > other.units }
            if distance != other.distance { return distance < other.distance }
            return designation < other.designation
        }
    }
}
