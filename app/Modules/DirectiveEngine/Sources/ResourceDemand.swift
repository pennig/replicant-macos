//
//  ResourceDemand.swift
//  Replicould — DirectiveEngine
//
//  What the fleet is being asked for: every open location event priced at its cheapest resolution option, devices translated through their blueprint bills, plus the standing print reserve. Pure — no I/O, no clock.
//

import GameModels

public struct ResourceDemand: Equatable, Sendable {
    /// One resolution option costed in resource units.
    public struct PricedOption: Equatable, Sendable {
        public let name: String
        public let cost: [String: Double]
        public var units: Double { cost.values.reduce(0, +) }

        public init(name: String, cost: [String: Double]) {
            self.name = name
            self.cost = cost
        }
    }

    /// Per-type demand: each open event's cheapest option, plus reserve floors.
    public let total: [String: Double]
    /// Every priceable option per event designation, cheapest first.
    public let pricedEvents: [String: [PricedOption]]

    public init(total: [String: Double], pricedEvents: [String: [PricedOption]]) {
        self.total = total
        self.pricedEvents = pricedEvents
    }

    /// Price `events` against `bills`, fold in `reserveFloors`. An option asking
    /// for a device with no blueprint cannot be fulfilled and is dropped, so
    /// demand under-counts rather than guessing.
    public static func compute(
        events: [LocationEvent],
        bills: [String: ResourceCost],
        components: [String: [String: Int]] = [:],
        reserveFloors: [String: Double]
    ) -> ResourceDemand {
        var total = reserveFloors
        var priced: [String: [PricedOption]] = [:]

        for event in events where event.isActive {
            guard let options = event.quest?.options, !options.isEmpty else { continue }
            let costed = options
                .compactMap { price($0, bills: bills, components: components) }
                .sorted { lhs, rhs in
                    lhs.units == rhs.units ? lhs.name < rhs.name : lhs.units < rhs.units
                }
            guard let cheapest = costed.first else { continue }
            priced[event.designation] = costed
            for (type, amount) in cheapest.cost { total[type, default: 0] += amount }
        }
        return ResourceDemand(total: total, pricedEvents: priced)
    }

    /// One option's unmet remainder, or nil when its tree needs a blueprint the
    /// account does not have.
    private static func price(
        _ option: LocationEventDetail.Option,
        bills: [String: ResourceCost],
        components: [String: [String: Int]]
    ) -> PricedOption? {
        var cost: [String: Double] = [:]
        for line in option.resources {
            let remaining = max(0, line.required - line.current)
            guard remaining > 0 else { continue }
            cost[line.resourceType.lowercased(), default: 0] += Double(remaining)
        }
        var outstanding: [String: Int] = [:]
        for line in option.devices {
            let remaining = max(0, line.required - line.current)
            guard remaining > 0 else { continue }
            outstanding[line.deviceType, default: 0] += remaining
        }
        let expansion = BlueprintClosure.expand(outstanding, bills: bills, components: components)
        guard expansion.unprintable.isEmpty else { return nil }
        for (type, amount) in expansion.resources.wireDictionary where amount > 0 {
            cost[type, default: 0] += Double(amount)
        }
        return PricedOption(name: option.name, cost: cost)
    }
}
