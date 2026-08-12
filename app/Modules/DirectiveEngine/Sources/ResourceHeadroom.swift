//
//  ResourceHeadroom.swift
//  Replicould — DirectiveEngine
//
//  Which resource types the fleet is nearest to running short of: stock over
//  demand, least-covered first. Yields the two bonus slots `MineSitePlanner`
//  ranks belts with. Pure — no I/O, `now` is passed in.
//

import Foundation

public struct ResourceHeadroom: Equatable, Sendable {
    /// Resource type → bonus points, at most two entries (+2 and +1).
    public let weights: [String: Int]
    /// Stock ÷ demand per demanded type, for the why-view.
    public let coverage: [String: Double]
    /// Whether `weights` is the static table rather than a derived reading.
    public let isFallback: Bool

    public init(weights: [String: Int], coverage: [String: Double], isFallback: Bool) {
        self.weights = weights
        self.coverage = coverage
        self.isFallback = isFallback
    }

    /// The fixed weights used when stock is unknown or stale.
    public static let staticWeights: [String: Int] = ["rares": 2, "conductive": 1]

    /// How old a stock reading may be and still be ranked on.
    public static let stalenessBound: TimeInterval = 86_400

    /// Weights from `stock` over `demand`. Falls back whenever the reading is
    /// missing, stale, or there is no demand to divide by.
    public static func derive(
        stock: [String: Double], demand: [String: Double], freshness: Date?, now: Date
    ) -> ResourceHeadroom {
        let knownTypes = Set(BrainCeiling.resourceTypes)
        let demanded = demand.filter { $0.value > 0 && knownTypes.contains($0.key) }
        guard !stock.isEmpty, !demanded.isEmpty,
              let freshness, now.timeIntervalSince(freshness) <= stalenessBound
        else {
            return ResourceHeadroom(weights: staticWeights, coverage: [:], isFallback: true)
        }

        var coverage: [String: Double] = [:]
        for (type, required) in demanded { coverage[type] = (stock[type] ?? 0) / required }

        let ranked = coverage
            .sorted { lhs, rhs in
                lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value < rhs.value
            }
            .prefix(2)
        var weights: [String: Int] = [:]
        for (offset, entry) in ranked.enumerated() { weights[entry.key] = 2 - offset }
        return ResourceHeadroom(weights: weights, coverage: coverage, isFallback: false)
    }

    /// The reading to rank with when there is none: the shipped constants.
    public static let staticFallback = ResourceHeadroom(
        weights: staticWeights, coverage: [:], isFallback: true
    )
}
