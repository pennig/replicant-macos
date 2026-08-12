//
//  TheatreSiteRanking.swift
//  Replicould — DirectiveEngine
//
//  Brain proposes, operator establishes: ranks candidate systems for a new
//  theatre. Pure and read-only over `WorldView` — no database, no clock, no
//  acting capability. Called from the why-view and the Theatres tab.
//

import Foundation
import GameModels
import UniverseModels

/// Ranks every known system as a candidate site for a new theatre.
public enum TheatreSiteRanking {
    /// How far a theatre's practical reach extends — both a candidate's own
    /// local value catchment and the radius an existing theatre already
    /// services. Matches `Brain.reclaimRangeLY`.
    static let reachLY: Double = Brain.reclaimRangeLY
    /// Beyond this, extra distance from the nearest theatre earns nothing more.
    static let redundancyCeilingLY: Double = 2 * reachLY
    /// One relay hop — the proximity that counts as authority by adjacency.
    static let adjacencyLY: Double = SalvageTargetPlanner.relayRangeLY
    static let beltWeight: Double = 5
    /// Flat credit for an unsurveyed system's belts — never zero, so a
    /// frontier system is not buried under one confirmed to hold none.
    static let unsurveyedBeltCredit: Double = 1
    static let authorityBonus: Double = 50
    static let redundancyWeight: Double = 1

    public struct Candidate: Equatable, Sendable, Identifiable {
        public var id: String { system }
        public let system: String
        public let score: Double
        public let unservicedValue: Double
        public let distanceToNearestTheatre: Double
        public let hasAuthority: Bool
        public let isSurveyed: Bool
        /// One line per clause that moved the score, for the why-view.
        public let reasons: [String]
        /// The nearest theatre's own depot, when one exists — the one
        /// designation `reasons` embeds mid-sentence, for a caller that must
        /// render it monospace via `BrainWhySpan`.
        public let nearestTheatreDepot: String?
    }

    /// Ranks every system in `view.starPositions` other than an existing
    /// operational theatre, highest score first, designation breaking ties —
    /// a total order so two ticks over one world propose the same list.
    public static func rank(view: WorldView, limit: Int = 5) -> [Candidate] {
        let operationalTheatres = view.theatres.filter(\.isOperational)
        let theatreSystems = Set(operationalTheatres.map(\.system))

        let candidates = view.starPositions.keys
            .filter { !theatreSystems.contains($0) }
            .compactMap { candidate(for: $0, view: view, operationalTheatres: operationalTheatres) }

        return Array(
            candidates
                .sorted { $0.score == $1.score ? $0.system < $1.system : $0.score > $1.score }
                .prefix(limit)
        )
    }

    private static func candidate(
        for system: String, view: WorldView, operationalTheatres: [Theatre]
    ) -> Candidate? {
        guard let position = view.starPositions[system] else { return nil }
        var reasons: [String] = []
        var score = 0.0

        let unserviced = unservicedValue(
            around: system, position: position, view: view, operationalTheatres: operationalTheatres
        )
        score += unserviced
        if unserviced > 0 {
            reasons.append(
                "\(formattedUnits(unserviced)) units of salvage and stockpile sit within "
                    + "\(Int(reachLY)) ly and are not already reached by an operational theatre."
            )
        }

        let isSurveyed = view.surveyedSystems.contains(system)
        let belts = isSurveyed ? beltValue(at: system, view: view) : unsurveyedBeltCredit
        score += belts * beltWeight
        if belts > 0 {
            reasons.append(
                isSurveyed
                    ? "Surveyed — its belts are confirmed and contribute measurable value here."
                    : "Unsurveyed — its belts are unknown rather than absent, so they are "
                        + "scored at a conservative discount instead of zero."
            )
        }

        let hasAuthority = hasAuthority(at: system, position: position, view: view)
        if hasAuthority {
            score += authorityBonus
            reasons.append(
                "Holds or neighbours one of the account's replicants, so command authority "
                    + "is already in place."
            )
        }

        let nearestTheatre = view.theatre(nearest: system)
        let nearestPosition = nearestTheatre.flatMap { view.starPositions[$0.system] }
        let distanceToNearestTheatre = nearestPosition.map(position.distance(to:)) ?? .infinity
        score += min(distanceToNearestTheatre, redundancyCeilingLY) * redundancyWeight
        if let theatre = nearestTheatre {
            let roundedDistance = Int(distanceToNearestTheatre.rounded())
            reasons.append(
                distanceToNearestTheatre < reachLY
                    ? "Only \(roundedDistance) ly from theatre \(theatre.depot) — would be redundant with it."
                    : "\(roundedDistance) ly from the nearest theatre (\(theatre.depot)), clear of its existing reach."
            )
        } else {
            reasons.append("No operational theatre exists yet, so there is nothing to be redundant with.")
        }

        return Candidate(
            system: system, score: score, unservicedValue: unserviced,
            distanceToNearestTheatre: distanceToNearestTheatre,
            hasAuthority: hasAuthority, isSurveyed: isSurveyed, reasons: reasons,
            nearestTheatreDepot: nearestTheatre?.depot
        )
    }

    /// Salvage and stockpile within `reachLY` of `system`, excluding whatever
    /// an operational theatre already reaches at the same radius — value it
    /// can already service is worth nothing here.
    private static func unservicedValue(
        around system: String, position: Position, view: WorldView, operationalTheatres: [Theatre]
    ) -> Double {
        let valueSystems = Set(view.salvageUnits.keys).union(view.stockpileUnits.keys)
        return valueSystems.reduce(into: 0.0) { total, valueSystem in
            guard let valuePosition = view.starPositions[valueSystem],
                  position.distance(to: valuePosition) <= reachLY
            else { return }
            let alreadyServiced = operationalTheatres.contains { theatre in
                guard let theatrePosition = view.starPositions[theatre.system] else { return false }
                return theatrePosition.distance(to: valuePosition) <= reachLY
            }
            guard !alreadyServiced else { return }
            total += (view.salvageUnits[valueSystem] ?? 0) + Double(view.stockpileUnits[valueSystem] ?? 0)
        }
    }

    /// Rich=3, moderate=2, sparse=1 — one more than `BeltClass.rawValue`.
    private static func beltValue(at system: String, view: WorldView) -> Double {
        (view.beltsBySystem[system] ?? []).reduce(0.0) { $0 + Double($1.beltClass.rawValue + 1) }
    }

    /// True when `system` itself holds a replicant, or sits within one relay
    /// hop of a system that does.
    private static func hasAuthority(at system: String, position: Position, view: WorldView) -> Bool {
        if view.replicantSystems.contains(system) { return true }
        return view.replicantSystems.contains { replicantSystem in
            guard let replicantPosition = view.starPositions[replicantSystem] else { return false }
            return position.distance(to: replicantPosition) <= adjacencyLY
        }
    }

    private static func formattedUnits(_ value: Double) -> String {
        let rounded = value.rounded()
        let whole = rounded.isFinite && rounded.magnitude < Double(Int.max) ? Int(rounded) : Int.max
        return whole.formatted(.number.locale(Locale(identifier: "en_US")))
    }
}
