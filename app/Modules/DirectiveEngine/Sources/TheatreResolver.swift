//
//  TheatreResolver.swift
//  Replicould — DirectiveEngine
//
//  The one theatre rule, over the census geometry both world reads carry.
//

import Foundation
import GameModels
import UniverseModels

/// Which theatre owns a device or a system. Held by `WorldView` and
/// `WorldSnapshot` alike, so the brain and a mission cannot disagree.
public struct TheatreResolver: Equatable, Sendable {
    public let theatres: [Theatre]
    public let starPositions: [String: Position]
    /// System → mesh-component label, from `MeshGraph.components(of:)`.
    public let components: [String: String]

    public init(
        theatres: [Theatre] = [],
        starPositions: [String: Position] = [:],
        components: [String: String] = [:]
    ) {
        self.theatres = theatres
        self.starPositions = starPositions
        self.components = components
    }

    /// `device`'s theatre — a partition: at most one per device. An explicit
    /// scoped tag for `goal` outranks location; location decides only for a
    /// device wearing none. Nil for a stowed/cruising device or an unknown system.
    public func owningTheatre(of device: Device, goal: FleetTag.Goal?) -> Theatre? {
        if let goal, let designation = device.scopedTag(for: goal)?.scope?.designation,
           let tagged = theatres.first(where: { $0.isOperational && $0.depot.lowercased() == designation })
        {
            return tagged
        }
        guard let location = device.location else { return nil }
        return owningTheatre(ofSystem: SiteAssay.system(of: location))
    }

    /// The rule `owningTheatre(of:goal:)` applies to a device's location, for a
    /// caller reasoning about a SYSTEM (a belt candidate) rather than a device.
    public func owningTheatre(ofSystem system: String) -> Theatre? {
        theatre(servicing: system) ?? theatre(nearest: system)
    }

    /// Inward: same mesh component, then nearest. Operational only.
    public func theatre(servicing system: String) -> Theatre? {
        let component = components[system]
        return nearestTheatre(to: system) { components[$0.system] != nil && components[$0.system] == component }
    }

    /// Outward: nearest by straight-line distance, no component filter. Operational only.
    public func theatre(nearest system: String) -> Theatre? {
        nearestTheatre(to: system) { _ in true }
    }

    /// Ranks both resolvers; they differ only by `admits`. Orders by
    /// (distance, depot) for a stable result.
    private func nearestTheatre(to system: String, admits: (Theatre) -> Bool) -> Theatre? {
        guard let origin = starPositions[system] else { return nil }
        return theatres
            .filter { $0.isOperational && admits($0) }
            .compactMap { theatre -> (Double, Theatre)? in
                guard let position = starPositions[theatre.system] else { return nil }
                return (origin.distance(to: position), theatre)
            }
            .min { lhs, rhs in
                lhs.0 == rhs.0 ? lhs.1.depot < rhs.1.depot : lhs.0 < rhs.0
            }?.1
    }
}
