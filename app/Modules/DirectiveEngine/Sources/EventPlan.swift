//
//  EventPlan.swift
//  Replicould — DirectiveEngine
//
//  What one location event costs, priced through the blueprint catalogue.
//

import Foundation
import GameModels

public enum EventPlan {
    /// The beacon planted at every fulfilled event so later requests reach us.
    public static let beaconDeviceType = "ftl_beacon"
    /// A `cargo_freighter`'s hold. An option above this needs more than one run.
    public static let freighterCargoCapacity = LocationEventDetail.freighterCargoCapacity

    /// One way to satisfy an event, priced through its whole component tree.
    public struct Option: Equatable, Sendable {
        public let name: String
        public let devices: [String: Int]
        public let resources: [String: Int]
        /// The build cost of every device in `devices` AND everything they
        /// consume. A lower bound when `unprintable` is non-empty.
        public let deviceUnits: Int
        /// Units of raw resource the event consumes.
        public let resourceUnits: Int
        /// Device types in the tree with no blueprint. Non-empty ⇒ unbuildable.
        public let unprintable: Set<String>
        /// The prints this option needs, prerequisites first.
        public let jobs: [BlueprintClosure.Job]

        public var exceedsOneFreighterLoad: Bool {
            resourceUnits > EventPlan.freighterCargoCapacity
        }
    }

    /// Whether an event can be worked without asking the operator.
    public enum Resolution: Equatable, Sendable {
        case decided(Option)
        case needsChoice([Option])
        /// Every option needs a blueprint the account does not have.
        case blocked([Option])
        /// The blob carries no readable option — never treat this as free.
        case undecodable
    }

    /// Resolve `event` against an optional recorded pick, over the printable
    /// options only. A pick naming no printable option is ignored, so a stale
    /// choice re-asks rather than misfires.
    public static func resolve(
        _ event: LocationEvent,
        chosenOption: String?,
        bills: [String: ResourceCost],
        components: [String: [String: Int]] = [:]
    ) -> Resolution {
        guard let detail = LocationEventDetail(event.detail), !detail.options.isEmpty else {
            return .undecodable
        }
        let priced = detail.options.map { price($0, bills, components) }
        // An empty catalogue cannot judge printability; leave every option standing.
        let printable = bills.isEmpty ? priced : priced.filter(\.unprintable.isEmpty)
        if printable.isEmpty { return .blocked(priced) }
        if printable.count == 1, let only = printable.first { return .decided(only) }
        if let name = chosenOption, let picked = printable.first(where: { $0.name == name }) {
            return .decided(picked)
        }
        return .needsChoice(printable)
    }

    /// What `option` still needs delivered: each requirement less what the
    /// ledger already counts against it. A type that is met drops out, so a
    /// second delivery never re-sends the first one's units. Falls back to the
    /// full requirement when the blob names no matching option, which is the
    /// only reading that cannot under-deliver.
    public static func outstandingResources(
        _ option: Option, in event: LocationEvent
    ) -> [String: Int] {
        guard let live = LocationEventDetail(event.detail)?
            .options.first(where: { $0.name == option.name })
        else { return option.resources }
        return live.resources.reduce(into: [:]) { bill, requirement in
            let short = requirement.required - requirement.current
            if short > 0 { bill[requirement.resourceType] = short }
        }
    }

    private static func price(
        _ option: LocationEventDetail.Option,
        _ bills: [String: ResourceCost],
        _ components: [String: [String: Int]]
    ) -> Option {
        let devices = option.devices.reduce(into: [String: Int]()) { $0[$1.deviceType] = $1.required }
        let resources = option.resources.reduce(into: [String: Int]()) { $0[$1.resourceType] = $1.required }
        let expansion = BlueprintClosure.expand(devices, bills: bills, components: components)
        return Option(
            name: option.name,
            devices: devices,
            resources: resources,
            deviceUnits: expansion.resources.total,
            resourceUnits: resources.values.reduce(0, +),
            unprintable: expansion.unprintable,
            jobs: expansion.jobs
        )
    }
}
