//
//  EventRanking.swift
//  Replicould — DirectiveEngine
//
//  Which location event the convoy works next: a lexicographic key over the
//  active ledger, in `GrowRanking`'s shape.
//

import Foundation
import GameModels
import UniverseModels

/// One rankable event, with the option in force and what reaching it costs.
public struct EventCandidate: Equatable, Sendable {
    public let designation: String
    public let location: String
    public let tier: Int
    public let option: EventPlan.Option
    /// Everything is already staged on site; the convoy only has to commit.
    public let alreadyMet: Bool
    /// Depot → event → depot at `EventRanking.secondsPerLy`. `.infinity` when
    /// the census cannot place either end.
    public let roundTripSeconds: Double
    public let rationale: String
}

public enum EventRanking {
    /// Shared with `HaulTargetPlanner.roundTripRank`; still uncalibrated.
    public static let secondsPerLy = 30.0

    /// Rank the events worth working, best first.
    public static func rank(
        events: [LocationEvent],
        chosenOptions: [String: String],
        bills: [String: ResourceCost],
        positions: [String: Position],
        depot: String,
        excluding: Set<String>
    ) -> [EventCandidate] {
        events
            .filter { $0.isActive && !excluding.contains($0.designation) }
            .compactMap { event -> EventCandidate? in
                guard case .decided(let option) = EventPlan.resolve(
                    event, chosenOption: chosenOptions[event.designation], bills: bills
                ) else { return nil }
                let trip = roundTrip(from: depot, to: event.location, positions: positions)
                return EventCandidate(
                    designation: event.designation,
                    location: event.location,
                    tier: event.tier,
                    option: option,
                    alreadyMet: event.objectivesMet,
                    roundTripSeconds: trip,
                    rationale: rationale(event, option, trip)
                )
            }
            .sorted(by: precedes)
    }

    /// The multi-option events waiting on an operator pick.
    public static func pendingChoices(
        events: [LocationEvent],
        chosenOptions: [String: String],
        bills: [String: ResourceCost]
    ) -> [(LocationEvent, [EventPlan.Option])] {
        events
            .filter(\.isActive)
            .compactMap { event in
                guard case .needsChoice(let offered) = EventPlan.resolve(
                    event, chosenOption: chosenOptions[event.designation], bills: bills
                ) else { return nil }
                return (event, offered)
            }
            .sorted { $0.0.designation < $1.0.designation }
    }

    /// met → tier desc → round trip asc → designation asc.
    private static func precedes(_ lhs: EventCandidate, _ rhs: EventCandidate) -> Bool {
        if lhs.alreadyMet != rhs.alreadyMet { return lhs.alreadyMet }
        if lhs.tier != rhs.tier { return lhs.tier > rhs.tier }
        if lhs.roundTripSeconds != rhs.roundTripSeconds {
            return lhs.roundTripSeconds < rhs.roundTripSeconds
        }
        return lhs.designation < rhs.designation
    }

    private static func roundTrip(
        from depot: String, to location: String, positions: [String: Position]
    ) -> Double {
        guard let origin = positions[SiteAssay.system(of: depot)],
              let target = positions[SiteAssay.system(of: location)]
        else { return .infinity }
        return 2 * origin.distance(to: target) * secondsPerLy
    }

    private static func rationale(
        _ event: LocationEvent, _ option: EventPlan.Option, _ trip: Double
    ) -> String {
        let bill = option.resourceUnits + option.deviceUnits
        let leg = trip.isFinite ? "\(Int(trip / 60)) min round trip" : "distance unknown"
        return "tier \(event.tier) at \(event.location) — \(bill) units, \(leg)"
    }
}
