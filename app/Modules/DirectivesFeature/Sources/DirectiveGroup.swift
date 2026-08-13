//
//  DirectiveGroup.swift
//  Replicould — Directives feature
//
//  The list's second axis: rows collected by the automation they serve, so a
//  mine reads as one thing rather than six. SwiftUI-free like `DirectiveRow`.
//

import DirectiveEngine
import Foundation
import GameModels

/// One collapsible section of the Directives list.
public struct DirectiveGroup: Equatable, Identifiable, Sendable {
    /// What binds a group's rows together. `automation` is read off the
    /// `auto:<name>[:<site>]` fleet tag; the other three are the buckets no
    /// fleet tag names.
    public enum Key: Hashable, Sendable {
        case automation(name: String, site: String?)
        case mesh
        case unassigned
        case finished
    }

    /// How loudly a group is asking for the operator — its worst row. Ordered
    /// so ascending sort puts the asking groups first.
    public enum Attention: Int, Comparable, Sendable {
        case needsAttention
        case paused
        case working

        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public let key: Key
    public let rows: [DirectiveRow]

    public init(key: Key, rows: [DirectiveRow]) {
        self.key = key
        self.rows = rows
    }

    /// Namespaced away from `DirectiveRow.id`, which is always `custom:`- or
    /// `builtin:`-prefixed, so expansion state can never key off a row.
    public var id: String {
        switch key {
        case let .automation(name, site): "auto:\(name)" + (site.map { ":\($0)" } ?? "")
        case .mesh: "group:mesh"
        case .unassigned: "group:unassigned"
        case .finished: "group:finished"
        }
    }

    /// Display names for the tag names that don't capitalise into the word the
    /// operator uses for the automation.
    private static let titles = ["tendmesh": "Mesh"]

    public var title: String {
        switch key {
        case let .automation(name, _): Self.titles[name] ?? name.capitalized
        case .mesh: "Mesh"
        case .unassigned: "Unassigned"
        case .finished: "Finished"
        }
    }

    /// The site the automation works, rendered mono by the header (house rule).
    public var designation: String? {
        guard case let .automation(_, site) = key else { return nil }
        return site
    }

    public var attention: Attention {
        rows.reduce(Attention.working) { worst, row in
            guard case let .custom(directive, _) = row else { return worst }
            switch directive.status {
            case .needsAttention: return Swift.min(worst, .needsAttention)
            case .paused: return Swift.min(worst, .paused)
            case .running, .completed, .cancelled: return worst
            }
        }
    }

    /// Finished last, then the asking groups, then the untagged buckets, then
    /// alphabetically.
    var sortKey: (Int, Int, Int, String, String) {
        (key == .finished ? 1 : 0, attention.rawValue, bucket, title, designation ?? "")
    }

    private var bucket: Int {
        switch key {
        case .automation: 0
        case .mesh: 1
        case .unassigned: 2
        case .finished: 3
        }
    }
}

extension DirectiveGroup {
    /// Collect `rows` into ordered groups, preserving each group's internal row
    /// order.
    public static func group(_ rows: [DirectiveRow]) -> [DirectiveGroup] {
        let keys = missionKeys(in: rows)
        var collected: [Key: [DirectiveRow]] = [:]
        var order: [Key] = []
        for row in rows {
            let key = key(for: row, missionKeys: keys)
            if collected[key] == nil { order.append(key) }
            collected[key, default: []].append(row)
        }
        return order
            .map { DirectiveGroup(key: $0, rows: collected[$0] ?? []) }
            .sorted { $0.sortKey < $1.sortKey }
    }

    /// The group each live mission contributes, reachable by its own id and by
    /// the device it drives — a pinned Haul Run can leave `controllerCode`
    /// unset, and then the device code is the only handle on its ferry's row.
    static func missionKeys(in rows: [DirectiveRow]) -> [String: Key] {
        var keys: [String: Key] = [:]
        for case let .custom(directive, _) in rows {
            guard !DirectiveStatus.finishedCases.contains(directive.status),
                  let tag = directive.fleetTag,
                  let key = automationKey(tag)
            else { continue }
            keys[directive.id] = key
            // First wins: `rows` is newest-first, and a device driven by two
            // rows belongs with the one that claimed it most recently.
            if keys[directive.deviceCode] == nil { keys[directive.deviceCode] = key }
        }
        return keys
    }

    /// A row's group. A built-in row a mission drives joins that mission rather
    /// than the automation its own tag names — the two agree everywhere except
    /// a pinned ferry, which stands at the delivery sink, not its belt.
    static func key(for row: DirectiveRow, missionKeys: [String: Key]) -> Key {
        switch row {
        case let .custom(directive, _):
            if DirectiveStatus.finishedCases.contains(directive.status) { return .finished }
            guard let tag = directive.fleetTag, let key = automationKey(tag) else { return .mesh }
            return key
        case let .builtIn(builtIn):
            if case let .mission(id) = builtIn.drivenBy?.holder, let key = missionKeys[id] {
                return key
            }
            if let key = missionKeys[builtIn.deviceCode] { return key }
            guard let tag = siteBearingTag(in: builtIn.tags) else { return .unassigned }
            return automationKey(tag, site: builtIn.drivenBy?.designation) ?? .unassigned
        }
    }

    /// The device's most specific fleet tag. A migrated device wears both the
    /// bare and the per-theatre form, and only the latter names where it works.
    static func siteBearingTag(in tags: [String]) -> String? {
        tags
            .map(Device.normalizedTag)
            .filter { $0.hasPrefix(RepairFleet.fleetTagPrefix) }
            .max { lhs, rhs in
                let (l, r) = (lhs.split(separator: ":").count, rhs.split(separator: ":").count)
                return l == r ? lhs > rhs : l < r
            }
    }

    /// `auto:mine:GRAZ-BELT-1` → (mine, GRAZ-BELT-1); a bare `auto:mine` takes
    /// `site`. Nil for anything that is not a fleet tag.
    static func automationKey(_ tag: String, site: String? = nil) -> Key? {
        let normalized = Device.normalizedTag(tag)
        guard normalized.hasPrefix(RepairFleet.fleetTagPrefix) else { return nil }
        let parts = normalized.split(separator: ":", maxSplits: 2).map(String.init)
        guard parts.count >= 2, !parts[1].isEmpty else { return nil }
        let designation = parts.count > 2 ? parts[2] : site
        return .automation(name: parts[1], site: designation?.uppercased())
    }
}
