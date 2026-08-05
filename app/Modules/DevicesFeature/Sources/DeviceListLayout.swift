//
//  DeviceListLayout.swift
//  Replicould — Devices feature
//
//  How the fleet master list is organised. A pure, SwiftUI-free namespace: the
//  whole of search, containment, collapse, and attention promotion is plain
//  functions over values, so it is unit-tested directly rather than through the
//  view. Deliberately NOT a static on `DevicesListView` — pure logic hung off a
//  SwiftUI `View` traps with signal 5 under `swift test`
//  (.claude/memory/swiftui-view-statics-trap-in-tests.md).
//
//  DO NOT `import SwiftUI` in this file.
//

import Foundation
import GameModels

public enum DeviceListLayout {

    /// Rows deeper than this share the deepest indent. The containment tree is
    /// genuinely two levels (Vessel → AMI controller → drones); anything below
    /// that is a data surprise and should not run the row off the edge.
    static let maxIndentDepth = 2
}

extension DeviceListLayout {

    /// One node of the containment forest, before flattening. Internal: the view
    /// never sees a tree, only `[DeviceEntry]`.
    struct Node: Equatable {
        var device: Device
        var children: [Node]
    }

    /// Every host relationship this device declares, in precedence order:
    /// controller → stowed → attached.
    static func hostRelations(of device: Device) -> [HostRelation] {
        var relations: [HostRelation] = []
        if let code = device.controllerDeviceCode { relations.append(.controlled(by: code)) }
        if let code = device.stowedInDeviceCode { relations.append(.stowed(in: code)) }
        if let code = device.attachedToDeviceCode { relations.append(.attached(to: code)) }
        return relations
    }

    /// The host this device nests under — the highest-precedence relation it
    /// declares, resolved or not.
    static func hostCode(of device: Device) -> String? {
        hostRelations(of: device).first?.hostCode
    }

    /// The badge relationship: the first declared relation that isn't the one
    /// the row actually nests under. A top-level device (`parentCode == nil`)
    /// badges its first relation, so an unresolved host stays visible.
    static func badge(for device: Device, parentCode: String?) -> HostRelation? {
        hostRelations(of: device).first { $0.hostCode != parentCode }
    }

    /// Walks `code` up its declared host chain and reports whether the walk
    /// re-enters a code it has already seen. Every member of a cycle answers
    /// true, so a cycle dissolves entirely into roots — each of its devices is
    /// placed exactly once and the walk provably terminates (the seen set grows
    /// on every step over a finite fleet).
    static func closesCycle(_ code: String, in byCode: [String: Device]) -> Bool {
        var seen: Set<String> = [code]
        var current = code
        while let device = byCode[current], let next = hostCode(of: device) {
            if seen.contains(next) { return true }
            seen.insert(next)
            current = next
        }
        return false
    }

    /// Sort within a level: type display name, then device code.
    static func precedes(_ a: Device, _ b: Device) -> Bool {
        let nameA = DevicePresentation.displayName(a.deviceType)
        let nameB = DevicePresentation.displayName(b.deviceType)
        if nameA != nameB { return nameA < nameB }
        return a.deviceCode < b.deviceCode
    }

    /// Builds the containment forest. A device whose declared host is absent from
    /// the fleet, is itself, or would close a cycle is promoted to top level —
    /// the fleet syncs incrementally, so a dangling reference is cheap to guard
    /// and expensive to hit.
    static func forest(fleet: [Device]) -> [Node] {
        let byCode = Dictionary(fleet.map { ($0.deviceCode, $0) }, uniquingKeysWith: { first, _ in first })

        var childCodes: [String: [String]] = [:]
        var roots: [Device] = []
        for device in fleet {
            guard let host = hostCode(of: device),
                  host != device.deviceCode,
                  byCode[host] != nil,
                  !closesCycle(device.deviceCode, in: byCode)
            else {
                roots.append(device)
                continue
            }
            childCodes[host, default: []].append(device.deviceCode)
        }

        func node(for device: Device) -> Node {
            Node(
                device: device,
                children: (childCodes[device.deviceCode] ?? [])
                    .compactMap { byCode[$0] }
                    .sorted(by: precedes)
                    .map(node(for:))
            )
        }

        return roots.sorted(by: precedes).map(node(for:))
    }
}

extension DeviceListLayout {

    /// Walks the forest in render order, emitting a node's children only when it
    /// is open. A collapsed host contributes no entries, so
    /// `sections.flatMap(\.entries).map(\.id)` — the list's `orderedIDs` — skips
    /// hidden rows by construction.
    ///
    /// `expandedHosts` is the operator's own disclosure state; `forcedOpen` is
    /// the transient reveal a search query applies to a match's ancestors, and
    /// never writes back.
    static func flatten(
        _ nodes: [Node],
        depth: Int = 0,
        parentCode: String? = nil,
        expandedHosts: Set<String>,
        forcedOpen: Set<String>,
        attention: [String: [AttentionFlag]]
    ) -> [DeviceEntry] {
        var entries: [DeviceEntry] = []
        for node in nodes {
            let code = node.device.deviceCode
            let isOpen = !node.children.isEmpty
                && (expandedHosts.contains(code) || forcedOpen.contains(code))
            entries.append(
                DeviceEntry(
                    device: node.device,
                    depth: min(depth, maxIndentDepth),
                    childCount: node.children.count,
                    isExpanded: isOpen,
                    host: badge(for: node.device, parentCode: parentCode),
                    attention: attention[code] ?? []
                )
            )
            if isOpen {
                entries.append(
                    contentsOf: flatten(
                        node.children,
                        depth: depth + 1,
                        parentCode: code,
                        expandedHosts: expandedHosts,
                        forcedOpen: forcedOpen,
                        attention: attention
                    )
                )
            }
        }
        return entries
    }
}

extension DeviceListLayout {

    /// Lifts every flagged node out of the forest — at whatever depth it sat,
    /// taking its own subtree with it — and returns it alongside what's left.
    /// A flagged node inside another flagged node's subtree travels with its
    /// host rather than being lifted again, so it appears exactly once.
    static func promote(_ nodes: [Node], flagged: Set<String>) -> (promoted: [Node], remaining: [Node]) {
        var promoted: [Node] = []
        var remaining: [Node] = []
        for node in nodes {
            if flagged.contains(node.device.deviceCode) {
                promoted.append(node)
            } else {
                let split = promote(node.children, flagged: flagged)
                promoted.append(contentsOf: split.promoted)
                remaining.append(Node(device: node.device, children: split.remaining))
            }
        }
        return (promoted, remaining)
    }

    /// Every device a forest holds, roots and descendants alike.
    static func devices(in nodes: [Node]) -> [Device] {
        nodes.flatMap { [$0.device] + devices(in: $0.children) }
    }

    /// The section's status distribution, count descending then status name.
    static func statusShares(_ devices: [Device]) -> [StatusShare] {
        Dictionary(grouping: devices, by: \.statusBase)
            .map { StatusShare(status: $0.key, count: $0.value.count) }
            .sorted {
                $0.count != $1.count ? $0.count > $1.count : $0.status < $1.status
            }
    }

    /// The list's one entry point. Returns a pinned Needs Attention section (when
    /// anything is flagged) above one unheadered Carrier section. Empty sections
    /// are dropped, except a *collapsed* Needs Attention, which keeps its header
    /// so the operator can open it again.
    public static func sections(
        fleet: [Device],
        attentionDirectives: [Directive],
        searchText: String,
        expandedHosts: Set<String>,
        collapsedGroups: Set<String>
    ) -> [DeviceListSection] {
        let attention = Dictionary(
            fleet.map { ($0.deviceCode, attentionFlags(for: $0, directives: attentionDirectives)) },
            uniquingKeysWith: { first, _ in first }
        )
        let flagged = Set(attention.filter { !$0.value.isEmpty }.keys)

        let split = promote(forest(fleet: fleet), flagged: flagged)
        let attentionRoots = split.promoted.sorted {
            attentionPrecedes($0.device, $1.device, attention: attention)
        }

        var sections: [DeviceListSection] = []

        if !attentionRoots.isEmpty {
            let isCollapsed = collapsedGroups.contains(DeviceListSection.attentionID)
            let members = devices(in: attentionRoots)
            sections.append(
                DeviceListSection(
                    id: DeviceListSection.attentionID,
                    header: DeviceListHeader(
                        title: "Needs Attention",
                        count: attentionRoots.count,
                        isCollapsed: isCollapsed,
                        statusShares: statusShares(members),
                        hasDamaged: members.contains { $0.operationalCapacity < damagedCapacityThreshold }
                    ),
                    entries: isCollapsed ? [] : flatten(
                        attentionRoots,
                        expandedHosts: expandedHosts,
                        forcedOpen: [],
                        attention: attention
                    )
                )
            )
        }

        let fleetEntries = flatten(
            split.remaining,
            expandedHosts: expandedHosts,
            forcedOpen: [],
            attention: attention
        )
        if !fleetEntries.isEmpty {
            sections.append(
                DeviceListSection(id: DeviceListSection.fleetID, header: nil, entries: fleetEntries)
            )
        }

        return sections
    }
}
