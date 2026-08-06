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

    /// Rows for a flattened mode: position encodes no containment, so every row
    /// sits at depth 0 and badges its highest-precedence host relation instead.
    /// `devices` is emitted in the order given.
    static func flatEntries(
        _ devices: [Device],
        attention: [String: [AttentionFlag]],
        hostTypes: [String: String]
    ) -> [DeviceEntry] {
        devices.map { device in
            let host = badge(for: device, parentCode: nil)
            return DeviceEntry(
                device: device,
                depth: 0,
                childCount: 0,
                isExpanded: false,
                host: host,
                hostDeviceType: host.flatMap { hostTypes[$0.hostCode] },
                attention: attention[device.deviceCode] ?? []
            )
        }
    }

    /// Needs Attention above the sections `dimension` partitions the rest into,
    /// or above one unheadered fleet section when `dimension` is nil (Flat).
    static func flattenedSections(
        fleet: [Device],
        dimension: GroupDimension?,
        query: Query,
        attention: [String: [AttentionFlag]],
        hosts: [String: Device],
        hostTypes: [String: String],
        collapsedGroups: Set<String>
    ) -> [DeviceListSection] {
        let visible = fleet.filter { matches($0, query: query) }
        let flags = { (device: Device) in attention[device.deviceCode] ?? [] }
        var sections: [DeviceListSection] = []

        let flagged = visible
            .filter { !flags($0).isEmpty }
            .sorted { attentionPrecedes($0, $1, attention: attention) }
        if !flagged.isEmpty {
            let isCollapsed = collapsedGroups.contains(DeviceListSection.attentionID)
            sections.append(
                DeviceListSection(
                    id: DeviceListSection.attentionID,
                    header: header(title: attentionTitle, members: flagged, isCollapsed: isCollapsed),
                    entries: isCollapsed
                        ? []
                        : flatEntries(flagged, attention: attention, hostTypes: hostTypes)
                )
            )
        }

        let rest = visible.filter { flags($0).isEmpty }.sorted(by: precedes)

        guard let dimension else {
            if !rest.isEmpty {
                sections.append(
                    DeviceListSection(
                        id: DeviceListSection.fleetID,
                        header: nil,
                        entries: flatEntries(rest, attention: attention, hostTypes: hostTypes)
                    )
                )
            }
            return sections
        }

        var members: [String: [Device]] = [:]
        var byID: [String: GroupBucket] = [:]
        for device in rest {
            for bucket in buckets(for: device, dimension: dimension, hosts: hosts) {
                members[bucket.id, default: []].append(device)
                byID[bucket.id] = bucket
            }
        }

        // Count descending, then title — with the catch-all after every named
        // bucket however large it grows.
        let ordered = byID.values.sorted { a, b in
            if a.sortsLast != b.sortsLast { return b.sortsLast }
            let countA = members[a.id]?.count ?? 0
            let countB = members[b.id]?.count ?? 0
            if countA != countB { return countA > countB }
            return a.title < b.title
        }

        for bucket in ordered {
            let group = members[bucket.id] ?? []
            let isCollapsed = collapsedGroups.contains(bucket.id)
            sections.append(
                DeviceListSection(
                    id: bucket.id,
                    header: header(
                        title: bucket.title,
                        isDesignation: bucket.isDesignation,
                        members: group,
                        isCollapsed: isCollapsed
                    ),
                    entries: isCollapsed
                        ? []
                        : flatEntries(group, attention: attention, hostTypes: hostTypes)
                )
            )
        }

        return sections
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
