//
//  LocationNode.swift
//  LocationsFeature
//
//  The presentation tree for the catalog's disclosure list, built from the
//  persisted census (`Star`, all charted systems), the hydrated `StarSystem`
//  blobs (explored systems), and the `LocationFootprint` holdings overlay.
//
//  The tree is three levels — system → (belts + planets) → moons — matching the
//  sidebar spec. Resource/salvage sites, shops, lagrange points and events do
//  NOT appear as rows; they bubble up into the detail pane instead.
//
//  Pure value types + pure builders so filter/sort/assembly are unit-testable.
//

import Foundation
import SwiftUI
import UniverseModels

// MARK: - Sort & filter

public enum LocationSort: String, CaseIterable, Sendable, Identifiable {
    case alphabetical, distance, inventory
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .alphabetical: "Alphabetical"
        case .distance:     "Distance"
        case .inventory:    "Inventory"
        }
    }
    public var symbol: String {
        switch self {
        case .alphabetical: "textformat.abc"
        case .distance:     "ruler"
        case .inventory:    "shippingbox"
        }
    }
}

public enum LocationFilter: String, CaseIterable, Sendable, Identifiable {
    case all, explored, unexplored
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .all:        "All"
        case .explored:   "Explored"
        case .unexplored: "Uncharted"
        }
    }
}

// MARK: - Node

public enum LocationKind: String, Equatable, Sendable {
    case system, belt, planet, moon, object

    public var symbol: String {
        switch self {
        case .system: "sparkles"
        case .belt:   "circle.dotted"
        case .planet: "globe.americas"
        case .moon:   "moon"
        case .object: "cube.transparent"
        }
    }
}

/// A little count chip on a row (sites, salvage, shops, devices).
public struct LocationBadge: Equatable, Sendable, Identifiable {
    public let symbol: String
    public let count: Int?
    public var id: String { symbol }
    public init(symbol: String, count: Int?) {
        self.symbol = symbol
        self.count = count
    }
}

public struct LocationNode: Identifiable, Equatable, Sendable {
    public let id: String            // designation
    public let kind: LocationKind
    public let title: String
    public let subtitle: String?
    public let recon: Recon
    public let badges: [LocationBadge]
    public var children: [LocationNode]?

    public init(
        id: String, kind: LocationKind, title: String, subtitle: String?,
        recon: Recon, badges: [LocationBadge] = [], children: [LocationNode]? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.recon = recon
        self.badges = badges
        self.children = children
    }
}

// MARK: - Flattened row

/// One line in the flattened, currently-visible outline. Expansion collapses the
/// system → (belt/planet) → moon tree into a single lazy `List` of lightweight
/// rows: only on-screen rows are realized and each carries no nested view type,
/// so a toggle splices a few rows into a flat array instead of reconstructing a
/// 5,770-node graph of nested generic `DisclosureGroup`s (which the runtime spent
/// all its time instantiating metadata for + ARC-churning). Mirrors the
/// flatten-to-visible-rows approach in `JSONTreeView`, but over a `List` for
/// cell recycling + native selection.
public struct LocationFlatRow: Identifiable, Equatable, Sendable {
    public let node: LocationNode
    public let depth: Int
    public let hasChildren: Bool
    public let isExpanded: Bool
    public var id: String { node.id }

    public init(node: LocationNode, depth: Int, hasChildren: Bool, isExpanded: Bool) {
        self.node = node
        self.depth = depth
        self.hasChildren = hasChildren
        self.isExpanded = isExpanded
    }
}

// MARK: - Builder

public enum LocationTree {
    /// Walk the forest in render order, emitting only the currently-visible rows:
    /// a node's children are emitted only when its id is in `expanded`. Skipping
    /// collapsed subtrees is what keeps the fully-collapsed 5,770-system list a
    /// flat array of cheap rows.
    public static func flatten(_ forest: [LocationNode], expanded: Set<String>) -> [LocationFlatRow] {
        var rows: [LocationFlatRow] = []
        rows.reserveCapacity(forest.count)
        func walk(_ node: LocationNode, depth: Int) {
            let children = node.children ?? []
            let hasChildren = !children.isEmpty
            let isExpanded = hasChildren && expanded.contains(node.id)
            rows.append(LocationFlatRow(node: node, depth: depth, hasChildren: hasChildren, isExpanded: isExpanded))
            if isExpanded {
                for child in children { walk(child, depth: depth + 1) }
            }
        }
        for node in forest { walk(node, depth: 0) }
        return rows
    }

    /// Build the filtered, sorted forest of system nodes.
    public static func forest(
        stars: [Star],
        details: [String: StarSystem],
        footprints: [String: LocationCounts],
        myPosition: Position?,
        filter: LocationFilter,
        sort: LocationSort
    ) -> [LocationNode] {
        let filtered = stars.filter { star in
            // A system counts as explored if the bulk census says so *or* we hold
            // hydrated detail for it. The census `Star` table is only refreshed by
            // the Stars-view survey, so a system scanned while the app was closed
            // can still read `explored == false` here even though its hydrated
            // detail (and the "N/N scanned" subtitle) show it's been fully scanned.
            // A detail blob is only ever obtained while a replicant is in the system
            // (the endpoint 403s "No replicant in system" otherwise), and reaching a
            // system marks it explored — so a persisted blob implies exploration and
            // keeps the filter consistent with what the row shows.
            let isExplored = star.explored || details[star.designation] != nil
            return switch filter {
            case .all:        true
            case .explored:   isExplored
            case .unexplored: !isExplored
            }
        }

        let sorted = filtered.sorted { a, b in
            switch sort {
            case .alphabetical:
                return a.designation < b.designation
            case .distance:
                return distance(a, myPosition) < distance(b, myPosition)
            case .inventory:
                let ia = inventoryTotal(a.designation, details, footprints)
                let ib = inventoryTotal(b.designation, details, footprints)
                return ia == ib ? a.designation < b.designation : ia > ib
            }
        }

        return sorted.map { star in
            node(for: star, detail: details[star.designation], footprints: footprints)
        }
    }

    // MARK: System node

    static func node(for star: Star, detail: StarSystem?, footprints: [String: LocationCounts]) -> LocationNode {
        guard let system = detail else {
            // Census-only: uncharted or charted-but-not-hydrated. Leaf. It carries
            // no hydrated inventory, but the footprint overlay can still flag that
            // it holds resources before it's been scanned.
            let inventory = hasInventory(star.designation, own: [], footprints: footprints, includeDescendants: true)
            return LocationNode(
                id: star.designation,
                kind: .system,
                title: star.designation,
                subtitle: censusSubtitle(star),
                recon: star.explored ? .visited : .aware,
                badges: inventory ? [inventoryBadge] : [],
                children: nil
            )
        }

        let children = system.belts.map { beltNode($0, footprints) }
            + system.planets.map { planetNode($0, footprints) }
            + system.structures.map { objectNode($0, footprints) }
        return LocationNode(
            id: system.designation,
            kind: .system,
            title: system.name ?? system.designation,
            subtitle: systemSubtitle(star: star, system: system),
            recon: system.recon,
            badges: systemBadges(system, footprints: footprints),
            children: children.isEmpty ? nil : children
        )
    }

    static func planetNode(_ p: Planet, _ footprints: [String: LocationCounts]) -> LocationNode {
        // A planet's badges reflect it *and* its moons, so sites/salvage/devices/
        // inventory held on a moon still flag the planet row while it's collapsed.
        let inventory = p.inventory + p.moons.flatMap(\.inventory)
        let devices = p.devices.count + p.moons.reduce(0) { $0 + $1.devices.count }
        return LocationNode(
            id: p.designation,
            kind: .planet,
            title: p.name ?? p.designation,
            subtitle: [p.type, p.orbitalDistanceAu.map { String(format: "%.2f AU", $0) }]
                .compactMap { $0 }.joined(separator: " · "),
            recon: p.recon,
            badges: bodyBadges(
                sites: p.allResourceSites.count, salvage: p.allSalvageSites.count, devices: devices,
                hasInventory: hasInventory(p.designation, own: inventory, footprints: footprints, includeDescendants: true)
            ),
            children: p.moons.isEmpty ? nil : p.moons.map { moonNode($0, footprints) }
        )
    }

    static func moonNode(_ m: Moon, _ footprints: [String: LocationCounts]) -> LocationNode {
        LocationNode(
            id: m.designation,
            kind: .moon,
            title: m.name ?? m.designation,
            subtitle: m.type,
            recon: m.recon,
            badges: bodyBadges(
                sites: m.sites.count, salvage: m.salvage.count, devices: m.devices.count,
                hasInventory: hasInventory(m.designation, own: m.inventory, footprints: footprints, includeDescendants: false)
            )
        )
    }

    static func beltNode(_ b: Belt, _ footprints: [String: LocationCounts]) -> LocationNode {
        LocationNode(
            id: b.designation,
            kind: .belt,
            title: b.designation,
            subtitle: b.density.map { "\($0.capitalized) belt" } ?? "Asteroid belt",
            recon: .scanned,
            badges: bodyBadges(
                sites: b.sites.count, salvage: 0, devices: 0,
                hasInventory: hasInventory(b.designation, own: b.inventory, footprints: footprints, includeDescendants: false)
            )
        )
    }

    static func objectNode(_ s: SpecialSite, _ footprints: [String: LocationCounts]) -> LocationNode {
        LocationNode(
            id: s.designation,
            kind: .object,
            title: s.title ?? s.name ?? s.designation,
            subtitle: (s.objectType ?? s.kind.rawValue).replacingOccurrences(of: "_", with: " ").capitalized,
            recon: .scanned,
            badges: bodyBadges(
                sites: 0, salvage: 0, devices: 0,
                hasInventory: hasInventory(s.designation, own: s.inventory, footprints: footprints, includeDescendants: false)
            )
        )
    }

    // MARK: Badges & subtitles

    static func systemBadges(_ s: StarSystem, footprints: [String: LocationCounts]) -> [LocationBadge] {
        var out: [LocationBadge] = []
        let sites = s.allResourceSites.count
        let salvage = s.allSalvageSites.count
        let shops = s.shops.count
        let devices = s.allDevices.count
        if sites > 0 { out.append(.init(symbol: "diamond", count: sites)) }
        if salvage > 0 { out.append(.init(symbol: "wrench.and.screwdriver", count: salvage)) }
        if shops > 0 { out.append(.init(symbol: "cart", count: shops)) }
        if devices > 0 { out.append(.init(symbol: "circle.hexagongrid", count: devices)) }
        if hasInventory(s.designation, own: s.allInventory, footprints: footprints, includeDescendants: true) {
            out.append(inventoryBadge)
        }
        return out
    }

    static func bodyBadges(sites: Int, salvage: Int, devices: Int, hasInventory: Bool) -> [LocationBadge] {
        var out: [LocationBadge] = []
        if sites > 0 { out.append(.init(symbol: "diamond", count: sites)) }
        if salvage > 0 { out.append(.init(symbol: "wrench.and.screwdriver", count: salvage)) }
        if devices > 0 { out.append(.init(symbol: "circle.hexagongrid", count: devices)) }
        if hasInventory { out.append(inventoryBadge) }
        return out
    }

    /// The unnumbered "holds inventory" chip (matches the Inventory sort's icon).
    static let inventoryBadge = LocationBadge(symbol: "shippingbox", count: nil)

    /// Whether a location holds stored resources — itself, or (for a container)
    /// anywhere beneath it. Prefers hydrated inventory; falls back to the
    /// `LocationFootprint` overlay's resource count so a census-only system still
    /// flags holdings before it's hydrated.
    static func hasInventory(
        _ designation: String,
        own inventory: [InventoryItem],
        footprints: [String: LocationCounts],
        includeDescendants: Bool
    ) -> Bool {
        if !inventory.isEmpty { return true }
        if includeDescendants {
            let prefix = designation + "-"
            return footprints.contains { location, counts in
                (location == designation || location.hasPrefix(prefix)) && counts.resources > 0
            }
        }
        return (footprints[designation]?.resources ?? 0) > 0
    }

    static func censusSubtitle(_ star: Star) -> String {
        let planets = star.estimatedPlanets
        let est = star.explored ? "" : "≈"
        return "\(star.spectralType) · \(est)\(planets) planet\(planets == 1 ? "" : "s")"
    }

    static func systemSubtitle(star: Star, system: StarSystem) -> String {
        var parts = [star.spectralType]
        if let scanned = system.planetsScanned, let total = system.planetsTotal {
            parts.append("\(scanned)/\(total) scanned")
        } else {
            parts.append("\(system.planets.count) planets")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Sort keys

    static func distance(_ star: Star, _ me: Position?) -> Double {
        guard let me else { return .greatestFiniteMagnitude }
        return star.position.distance(to: me)
    }

    /// Inventory magnitude for a system: prefer the hydrated roll-up, else the
    /// footprint `resources` counts for any location under this system.
    static func inventoryTotal(
        _ designation: String,
        _ details: [String: StarSystem],
        _ footprints: [String: LocationCounts]
    ) -> Double {
        if let system = details[designation] {
            let rolled = system.totalInventoryQuantity
            if rolled > 0 { return rolled }
        }
        let prefix = designation + "-"
        return footprints.reduce(0.0) { sum, entry in
            (entry.key == designation || entry.key.hasPrefix(prefix))
                ? sum + Double(entry.value.resources)
                : sum
        }
    }
}
