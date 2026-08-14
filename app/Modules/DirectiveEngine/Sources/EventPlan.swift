//
//  EventPlan.swift
//  Replicould — DirectiveEngine
//
//  What one location event costs: the option in force and its device and
//  resource bill, priced through the blueprint catalogue.
//

import Foundation
import GameModels

public enum EventPlan {
    /// The beacon planted at every fulfilled event so later requests reach us.
    public static let beaconDeviceType = "ftl_beacon"
    /// A `cargo_freighter`'s hold. An option above this needs more than one run.
    public static let freighterCargoCapacity = 500

    /// One way to satisfy an event, priced.
    public struct Option: Equatable, Sendable {
        public let name: String
        public let devices: [String: Int]
        public let resources: [String: Int]
        /// The build cost of every device in `devices`, summed.
        public let deviceUnits: Int
        /// Units of raw resource the event consumes.
        public let resourceUnits: Int

        public var exceedsOneFreighterLoad: Bool {
            resourceUnits > EventPlan.freighterCargoCapacity
        }
    }

    /// Whether an event can be worked without asking the operator.
    public enum Resolution: Equatable, Sendable {
        case decided(Option)
        case needsChoice([Option])
        /// The blob carries no readable option — never treat this as free.
        case undecodable
    }

    /// Resolve `event` against an optional recorded pick. A pick naming no
    /// offered option is ignored, so a stale choice re-asks rather than misfires.
    public static func resolve(
        _ event: LocationEvent, chosenOption: String?, bills: [String: ResourceCost]
    ) -> Resolution {
        guard let detail = LocationEventDetail(event.detail), !detail.options.isEmpty else {
            return .undecodable
        }
        let priced = detail.options.map { price($0, bills) }
        if priced.count == 1, let only = priced.first { return .decided(only) }
        if let name = chosenOption, let picked = priced.first(where: { $0.name == name }) {
            return .decided(picked)
        }
        return .needsChoice(priced)
    }

    private static func price(
        _ option: LocationEventDetail.Option, _ bills: [String: ResourceCost]
    ) -> Option {
        let devices = option.devices.reduce(into: [String: Int]()) { $0[$1.deviceType] = $1.required }
        let resources = option.resources.reduce(into: [String: Int]()) { $0[$1.resourceType] = $1.required }
        return Option(
            name: option.name,
            devices: devices,
            resources: resources,
            deviceUnits: devices.reduce(0) { $0 + (bills[$1.key]?.total ?? 0) * $1.value },
            resourceUnits: resources.values.reduce(0, +)
        )
    }
}
