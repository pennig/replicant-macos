//
//  DirectiveTargetsSection.swift
//  Replicould — Directives feature
//
//  What the detail pane shows where a bounded run shows its queue. A roam never
//  checks its queue off, a Haul Run has no queue at all, and a Restock Run's
//  targets are demand — so the section's identity follows the run's shape.
//

import DirectiveEngine
import Foundation
import GameModels

/// The mission detail pane's queue-shaped section, resolved per run kind. Kept
/// out of `DirectiveDetailView`: pure logic nested in a `View` traps under
/// `swift test` (see the "SwiftUI View statics trap in tests" memory note).
enum DirectiveTargetsSection: Equatable {
    /// One stop on a queue the operator picked.
    struct Stop: Equatable, Identifiable {
        let position: Int
        let designation: String
        let delivered: Bool
        var id: Int { position }
    }

    /// A roam's standing: where it is anchored, what it is working now, and the
    /// tail of what it has already finished.
    struct Coverage: Equatable {
        /// Non-nil only where the run's planner actually anchors on it.
        let centre: String?
        let current: String?
        let charted: Int
        /// Newest first, at most `trailLimit` long.
        let recent: [String]
        /// How many finished systems `recent` leaves out.
        let earlier: Int
    }

    /// One controller of a tagged fleet and the pile it is draining.
    struct Assignment: Equatable, Identifiable {
        let controllerCode: String
        let collecting: String?
        var id: String { controllerCode }
    }

    case queue([Stop])
    case coverage(Coverage)
    /// Nil `delivering` is a row with no theatre stamped, which delivers nowhere.
    case assignments(delivering: String?, [Assignment])
    case demand([String])
    case empty

    /// How many finished systems a roam lists before the rest collapse to a count.
    static let trailLimit = 5

    /// The section header, or nil when there is nothing to head.
    var title: String? {
        switch self {
        case .queue: "Targets"
        case .coverage: "Coverage"
        case .assignments: "Assignments"
        case .demand: "Demand"
        case .empty: nil
        }
    }

    /// The section `directive` warrants, read against `devices` for the fleet
    /// kinds. Mirrors the branch `DirectiveRow.subtitle` already makes, so the
    /// list and the detail pane cannot disagree about a run's shape.
    static func section(for directive: Directive, devices: [Device]) -> Self {
        switch directive.kind {
        case .haulRun:
            let assignments = assignments(for: directive, devices: devices)
            return assignments.isEmpty
                ? .empty
                : .assignments(delivering: directive.theatreDepot, assignments)
        case .restockRun:
            // `targetIndex` never advances here, so a delivery mark would sit
            // unchecked against demand that is genuinely being met.
            return directive.targets.isEmpty ? .empty : .demand(directive.targets)
        case .fetchRun:
            // A pickup and a destination, in that order. `targetIndex` never
            // advances, so the pickup is marked from the queue's shape instead.
            guard directive.targets.count == 2 else { return .empty }
            return .queue([
                Stop(position: 0, designation: directive.targets[0], delivered: true),
                Stop(position: 1, designation: directive.targets[1], delivered: false),
            ])
        case .surveyRun, .salvageRun, .relayRun, .mineFleetPrint, .mineRun, .eventRun,
             .eventCourierPrint:
            break
        }
        if directive.roamCentre != nil { return .coverage(coverage(directive)) }
        guard !directive.targets.isEmpty else { return .empty }
        return .queue(directive.targets.enumerated().map { index, designation in
            Stop(
                position: index,
                designation: designation,
                delivered: directive.hasDelivered(targetAt: index)
            )
        })
    }

    /// `directive`'s roam standing. Counts through `hasDelivered(targetAt:)`
    /// rather than `targetIndex`, so a finished roam counts its last system.
    private static func coverage(_ directive: Directive) -> Coverage {
        let charted = directive.targets.indices.count { directive.hasDelivered(targetAt: $0) }
        let finished = directive.targets.prefix(charted).reversed()
        // A stopped run works nothing, and its cursor still names a system.
        let working = ![.completed, .cancelled].contains(directive.status)
        return Coverage(
            centre: anchorsOnCentre(directive.kind) ? directive.roamCentre : nil,
            current: working ? directive.currentTarget : nil,
            charted: charted,
            recent: Array(finished.prefix(trailLimit)),
            earlier: max(0, charted - trailLimit)
        )
    }

    /// Whether `kind`'s planner reads the roam centre. `SurveyRoamPlanner`
    /// anchors its band on it; `SalvageTargetPlanner` takes no centre at all and
    /// ranks by mesh membership, units, then distance from the vessel.
    private static func anchorsOnCentre(_ kind: DirectiveKind) -> Bool {
        kind == .surveyRun
    }

    /// Each controller of `directive`'s fleet and the pile it drains, resolved
    /// through `HaulRun`'s own queries so the readout matches what the run acts on.
    private static func assignments(for directive: Directive, devices: [Device]) -> [Assignment] {
        let fleet: [Device]
        if HaulRun.pinnedSource(of: directive) != nil {
            // A pinned row drives its OWN device, and its per-belt tag is worn
            // by nothing — the tag query would find no ferry at all.
            fleet = devices.filter { $0.deviceCode == directive.deviceCode }
        } else {
            fleet = HaulRun.controllers(
                in: devices, tag: directive.fleetTag.flatMap(FleetTag.init(parsing:)) ?? HaulRun.defaultFleetTag
            )
        }
        guard let delivery = directive.theatreDepot else {
            return fleet.map { Assignment(controllerCode: $0.deviceCode, collecting: nil) }
        }
        return fleet.map {
            Assignment(controllerCode: $0.deviceCode, collecting: HaulRun.drainedPile(of: $0, delivery: delivery))
        }
    }
}
