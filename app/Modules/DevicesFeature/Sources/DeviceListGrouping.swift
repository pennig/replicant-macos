//
//  DeviceListGrouping.swift
//  Replicould — Devices feature
//
//  How a flattened grouping mode partitions the fleet. No `import SwiftUI`.
//

import Foundation
import GameModels

/// A dimension that partitions the fleet into headered sections.
public enum GroupDimension: Equatable, Sendable {
    case type
    case system
    case mission
}

/// One section a dimension partitions the fleet into.
public struct GroupBucket: Equatable, Sendable {
    public var id: String
    public var title: String
    /// The title is a designation, so it renders monospaced.
    public var isDesignation: Bool
    /// The catch-all, ordered after every named bucket whatever its count.
    public var sortsLast: Bool

    public init(id: String, title: String, isDesignation: Bool, sortsLast: Bool) {
        self.id = id
        self.title = title
        self.isDesignation = isDesignation
        self.sortsLast = sortsLast
    }
}

extension DeviceGrouping {
    /// Nil for the two modes that render one unheadered section.
    public var dimension: GroupDimension? {
        switch self {
        case .carrier, .flat: nil
        case .type:           .type
        case .system:         .system
        case .mission:        .mission
        }
    }
}

extension DeviceListLayout {

    /// Every section `device` files under. More than one only for Mission, which
    /// is a facet: a device carrying two tags appears under both.
    static func buckets(
        for device: Device,
        dimension: GroupDimension,
        hosts: [String: Device]
    ) -> [GroupBucket] {
        switch dimension {
        case .type:
            [
                GroupBucket(
                    id: "type:\(device.deviceType)",
                    title: DevicePresentation.displayName(device.deviceType),
                    isDesignation: false,
                    sortsLast: false
                )
            ]

        case .system:
            if let system = systemKey(for: device, hosts: hosts) {
                [GroupBucket(id: "system:\(system)", title: system, isDesignation: true, sortsLast: false)]
            } else {
                [GroupBucket(id: "system:unknown", title: "Unknown", isDesignation: false, sortsLast: true)]
            }

        case .mission:
            if device.tags.isEmpty {
                [GroupBucket(id: "mission:untagged", title: "Untagged", isDesignation: false, sortsLast: true)]
            } else {
                device.tags.sorted().map {
                    GroupBucket(id: "mission:\($0)", title: $0, isDesignation: false, sortsLast: false)
                }
            }
        }
    }

    /// The system `device` files under: its own location rolled up to the first
    /// designation segment, else the system of the nearest host that has one.
    /// Nil when nothing in the chain resolves.
    static func systemKey(for device: Device, hosts: [String: Device]) -> String? {
        var current = device
        var seen: Set<String> = [device.deviceCode]
        while true {
            if let location = current.location {
                let system = TravelSnapshot.systemDesignation(location)
                if !system.isEmpty { return system }
            }
            // The walk climbs declared hosts, so it needs the forest's own cycle
            // guard: `seen` grows every step over a finite fleet.
            guard let hostCode = hostCode(of: current),
                  !seen.contains(hostCode),
                  let host = hosts[hostCode]
            else { return nil }
            seen.insert(hostCode)
            current = host
        }
    }
}
