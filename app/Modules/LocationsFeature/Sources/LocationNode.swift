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
    case system, belt, planet, moon

    public var symbol: String {
        switch self {
        case .system: "sparkles"
        case .belt:   "circle.dotted"
        case .planet: "globe.americas"
        case .moon:   "moon"
        }
    }
}

/// A little count chip on a row (sites, salvage, shops, devices).
public struct LocationBadge: Equatable, Sendable, Identifiable {
    public let symbol: String
    public let count: Int
    public var id: String { symbol }
    public init(symbol: String, count: Int) {
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

// MARK: - Builder

public enum LocationTree {
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
            switch filter {
            case .all:        true
            case .explored:   star.explored
            case .unexplored: !star.explored
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
            // Census-only: uncharted or charted-but-not-hydrated. Leaf.
            return LocationNode(
                id: star.designation,
                kind: .system,
                title: star.designation,
                subtitle: censusSubtitle(star),
                recon: star.explored ? .visited : .aware,
                badges: [],
                children: nil
            )
        }

        let children = system.belts.map(beltNode) + system.planets.map(planetNode)
        return LocationNode(
            id: system.designation,
            kind: .system,
            title: system.name ?? system.designation,
            subtitle: systemSubtitle(star: star, system: system),
            recon: system.recon,
            badges: systemBadges(system),
            children: children.isEmpty ? nil : children
        )
    }

    static func planetNode(_ p: Planet) -> LocationNode {
        LocationNode(
            id: p.designation,
            kind: .planet,
            title: p.name ?? p.designation,
            subtitle: [p.type, p.orbitalDistanceAu.map { String(format: "%.2f AU", $0) }]
                .compactMap { $0 }.joined(separator: " · "),
            recon: p.recon,
            badges: bodyBadges(sites: p.sites.count, salvage: p.salvage.count, devices: p.devices.count),
            children: p.moons.isEmpty ? nil : p.moons.map(moonNode)
        )
    }

    static func moonNode(_ m: Moon) -> LocationNode {
        LocationNode(
            id: m.designation,
            kind: .moon,
            title: m.name ?? m.designation,
            subtitle: m.type,
            recon: m.recon,
            badges: bodyBadges(sites: m.sites.count, salvage: m.salvage.count, devices: m.devices.count)
        )
    }

    static func beltNode(_ b: Belt) -> LocationNode {
        LocationNode(
            id: b.designation,
            kind: .belt,
            title: b.designation,
            subtitle: b.density.map { "\($0.capitalized) belt" } ?? "Asteroid belt",
            recon: .scanned,
            badges: bodyBadges(sites: b.sites.count, salvage: 0, devices: 0)
        )
    }

    // MARK: Badges & subtitles

    static func systemBadges(_ s: StarSystem) -> [LocationBadge] {
        var out: [LocationBadge] = []
        let sites = s.allResourceSites.count
        let salvage = s.allSalvageSites.count
        let shops = s.shops.count
        let devices = s.allDevices.count
        if sites > 0 { out.append(.init(symbol: "diamond", count: sites)) }
        if salvage > 0 { out.append(.init(symbol: "wrench.and.screwdriver", count: salvage)) }
        if shops > 0 { out.append(.init(symbol: "cart", count: shops)) }
        if devices > 0 { out.append(.init(symbol: "circle.hexagongrid", count: devices)) }
        return out
    }

    static func bodyBadges(sites: Int, salvage: Int, devices: Int) -> [LocationBadge] {
        var out: [LocationBadge] = []
        if sites > 0 { out.append(.init(symbol: "diamond", count: sites)) }
        if salvage > 0 { out.append(.init(symbol: "wrench.and.screwdriver", count: salvage)) }
        if devices > 0 { out.append(.init(symbol: "circle.hexagongrid", count: devices)) }
        return out
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
