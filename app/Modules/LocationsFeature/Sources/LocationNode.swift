//
//  LocationNode.swift
//  LocationsFeature
//
//  The presentation tree for the catalog's disclosure list, built from the
//  persisted census (`Star`, all charted systems), the hydrated `StarSystem`
//  blobs (explored systems), and the `LocationFootprint` holdings overlay.
//
//  The tree is three levels — system → (belts + planets) → (moons + lagrange
//  points) — matching the sidebar spec. A planet lists its moons followed by its
//  five Lagrange points (valid travel destinations that can hold inventory and
//  devices). Resource/salvage sites, shops and events do NOT appear as rows; they
//  bubble up into the detail pane instead.
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
    case system, belt, planet, moon, object, lagrange

    public var symbol: String {
        switch self {
        case .system:   "sparkles"
        case .belt:     "circle.dotted"
        case .planet:   "globe.americas"
        case .moon:     "moon"
        case .object:   "cube.transparent"
        case .lagrange: "scope"
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

// MARK: - Inventory index

/// The `LocationFootprint` overlay rolled up by designation: stored resources at
/// each location, and at each location *or anywhere beneath it*. Built once per
/// forest so a row answers "holds anything?" with a lookup — the tree asks that
/// question of every system, and the footprint table is galaxy-wide.
struct LocationInventoryIndex: Equatable, Sendable {
    private var own: [String: Double] = [:]
    private var rolled: [String: Double] = [:]

    init(footprints: [String: LocationCounts]) {
        for (location, counts) in footprints where counts.resources > 0 {
            let resources = Double(counts.resources)
            own[location, default: 0] += resources
            // Credit every ancestor designation: `SOL-3-L4` also counts toward
            // `SOL-3` and `SOL`. Splitting on the separator is what keeps `SOL`
            // from claiming `SOLARIS-1`.
            var segments = location.split(separator: "-")
            while !segments.isEmpty {
                rolled[segments.joined(separator: "-"), default: 0] += resources
                segments.removeLast()
            }
        }
    }

    /// Resources stored exactly at this location.
    func resources(at designation: String) -> Double { own[designation] ?? 0 }

    /// Resources stored at this location or anywhere beneath it.
    func rolledUp(at designation: String) -> Double { rolled[designation] ?? 0 }
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

        let index = LocationInventoryIndex(footprints: footprints)

        let sorted: [Star]
        switch sort {
        case .alphabetical:
            sorted = filtered.sorted { $0.designation < $1.designation }
        case .distance:
            sorted = filtered.sorted { distance($0, myPosition) < distance($1, myPosition) }
        case .inventory:
            // Key each system once rather than per comparison: the roll-up walks a
            // hydrated system's whole structure, which a comparator would repeat
            // O(n log n) times.
            let keys = Dictionary(
                filtered.map { ($0.designation, inventoryTotal($0.designation, details, index)) },
                uniquingKeysWith: { first, _ in first }
            )
            sorted = filtered.sorted { a, b in
                let ia = keys[a.designation] ?? 0
                let ib = keys[b.designation] ?? 0
                return ia == ib ? a.designation < b.designation : ia > ib
            }
        }

        return sorted.map { star in
            node(for: star, detail: details[star.designation], index)
        }
    }

    // MARK: System node

    static func node(for star: Star, detail: StarSystem?, _ index: LocationInventoryIndex) -> LocationNode {
        guard let system = detail else {
            // Census-only: uncharted or charted-but-not-hydrated. Leaf. It carries
            // no hydrated inventory, but the footprint overlay can still flag that
            // it holds resources before it's been scanned.
            let inventory = hasInventory(star.designation, own: [], index: index, includeDescendants: true)
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

        let children = system.belts.map { beltNode($0, index) }
            + system.planets.map { planetNode($0, index) }
            + system.structures.map { objectNode($0, index) }
        return LocationNode(
            id: system.designation,
            kind: .system,
            title: system.name ?? system.designation,
            subtitle: systemSubtitle(star: star, system: system),
            recon: system.recon,
            badges: systemBadges(system, index: index),
            children: children.isEmpty ? nil : children
        )
    }

    static func planetNode(_ p: Planet, _ index: LocationInventoryIndex) -> LocationNode {
        // A planet's badges reflect it *and* its moons and Lagrange points, so
        // sites/salvage/devices/inventory held beneath it still flag the planet row
        // while it's collapsed.
        let inventory = p.inventory + p.moons.flatMap(\.inventory) + p.lagrange.flatMap(\.inventory)
        let devices = p.devices.count
            + p.moons.reduce(0) { $0 + $1.devices.count }
            + p.lagrange.reduce(0) { $0 + $1.devices.count }
        // Moons first, then the five Lagrange points. Every planet has L1–L5 with
        // deterministic designations (`SYSTEM-n-L[1-5]`); any hydrated detail
        // (holdings, stationed devices) overlays by designation.
        let children = p.moons.map { moonNode($0, index) }
            + (1...5).map { n -> LocationNode in
                let code = "\(p.designation)-L\(n)"
                return lagrangeNode(code: code, point: n,
                                    hydrated: p.lagrange.first { $0.designation == code },
                                    index)
            }
        return LocationNode(
            id: p.designation,
            kind: .planet,
            title: p.name ?? p.designation,
            subtitle: [p.type, p.orbitalDistanceAu.map { String(format: "%.2f AU", $0) }]
                .compactMap { $0 }.joined(separator: " · "),
            recon: p.recon,
            badges: bodyBadges(
                sites: p.allResourceSites.count, salvage: p.allSalvageSites.count, devices: devices,
                hasInventory: hasInventory(p.designation, own: inventory, index: index, includeDescendants: true)
            ),
            children: children
        )
    }

    /// A planet's Lagrange point row. Synthesized for every planet (L1–L5); a
    /// `hydrated` `SpecialSite` supplies stationed-device and inventory badges once
    /// its per-location detail has been fetched. L4/L5 are the stable points.
    static func lagrangeNode(
        code: String, point: Int, hydrated: SpecialSite?, _ index: LocationInventoryIndex
    ) -> LocationNode {
        LocationNode(
            id: code,
            kind: .lagrange,
            title: "L\(point)",
            subtitle: (point == 4 || point == 5) ? "Lagrange point · stable" : "Lagrange point",
            recon: hydrated != nil ? .scanned : .aware,
            badges: bodyBadges(
                sites: 0, salvage: 0, devices: hydrated?.devices.count ?? 0,
                hasInventory: hasInventory(code, own: hydrated?.inventory ?? [],
                                           index: index, includeDescendants: false)
            )
        )
    }

    static func moonNode(_ m: Moon, _ index: LocationInventoryIndex) -> LocationNode {
        LocationNode(
            id: m.designation,
            kind: .moon,
            title: m.name ?? m.designation,
            subtitle: m.type,
            recon: m.recon,
            badges: bodyBadges(
                sites: m.sites.count, salvage: m.salvage.count, devices: m.devices.count,
                hasInventory: hasInventory(m.designation, own: m.inventory, index: index, includeDescendants: false)
            )
        )
    }

    static func beltNode(_ b: Belt, _ index: LocationInventoryIndex) -> LocationNode {
        LocationNode(
            id: b.designation,
            kind: .belt,
            title: b.designation,
            subtitle: b.density.map { "\($0.capitalized) belt" } ?? "Asteroid belt",
            recon: .scanned,
            badges: bodyBadges(
                sites: b.sites.count, salvage: 0, devices: 0,
                hasInventory: hasInventory(b.designation, own: b.inventory, index: index, includeDescendants: false)
            )
        )
    }

    static func objectNode(_ s: SpecialSite, _ index: LocationInventoryIndex) -> LocationNode {
        LocationNode(
            id: s.designation,
            kind: .object,
            title: s.title ?? s.name ?? s.designation,
            subtitle: (s.objectType ?? s.kind.rawValue).replacingOccurrences(of: "_", with: " ").capitalized,
            recon: .scanned,
            badges: bodyBadges(
                sites: 0, salvage: 0, devices: 0,
                hasInventory: hasInventory(s.designation, own: s.inventory, index: index, includeDescendants: false)
            )
        )
    }

    // MARK: Badges & subtitles

    static func systemBadges(_ s: StarSystem, index: LocationInventoryIndex) -> [LocationBadge] {
        var out: [LocationBadge] = []
        let sites = s.allResourceSites.count
        let salvage = s.allSalvageSites.count
        let shops = s.shops.count
        let devices = s.allDevices.count
        if sites > 0 { out.append(.init(symbol: "diamond", count: sites)) }
        if salvage > 0 { out.append(.init(symbol: "wrench.and.screwdriver", count: salvage)) }
        if shops > 0 { out.append(.init(symbol: "cart", count: shops)) }
        if devices > 0 { out.append(.init(symbol: "circle.hexagongrid", count: devices)) }
        if hasInventory(s.designation, own: s.allInventory, index: index, includeDescendants: true) {
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
        index: LocationInventoryIndex,
        includeDescendants: Bool
    ) -> Bool {
        if !inventory.isEmpty { return true }
        return includeDescendants
            ? index.rolledUp(at: designation) > 0
            : index.resources(at: designation) > 0
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

    /// The L-number (1…5) of a Lagrange designation whose last segment is `L[1-5]`
    /// (`SOL-5-L4` → 4). Nil when the tail isn't a recognized Lagrange marker — the
    /// detail pane uses it to resolve a selected Lagrange point back to its planet.
    public static func lPointNumber(_ designation: String) -> Int? {
        guard let last = designation.split(separator: "-").last,
              last.first == "L", let n = Int(last.dropFirst()), (1...5).contains(n)
        else { return nil }
        return n
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
        _ index: LocationInventoryIndex
    ) -> Double {
        if let system = details[designation] {
            let rolled = system.totalInventoryQuantity
            if rolled > 0 { return rolled }
        }
        return index.rolledUp(at: designation)
    }
}
