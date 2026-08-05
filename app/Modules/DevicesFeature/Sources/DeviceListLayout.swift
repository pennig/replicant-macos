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
