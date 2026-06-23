//
//  StarMapModels.swift
//  StarMapFeature
//
//  Value types for the Galaxy Explorer. The core star types mirror the backend
//  OpenAPI schemas so seed data and (later) live data share one shape:
//    - `Position`  ← app_schemas_common_PositionSchema
//    - `StarItem`  ← app_schemas_stars_StarItemSchema
//
//  `GalaxySystem` is the presentation model the scene/HUD/info-layers consume.
//  It wraps a `StarItem` and adds overlay fields the *list* schema does not
//  carry (relay mesh membership, presence, device/vessel counts, recon detail,
//  resource richness, life tier). Those are sourced app-side for now and marked
//  as pending real endpoints — see `GalaxyData`.
//
//  Pure value types only: no SwiftUI/AppKit/SceneKit here, so the model is
//  importable in tests. Color mapping lives with the scene (NSColor) and the
//  HUD (SwiftUI Color) respectively.
//

import Foundation

// MARK: - API-shaped core (mirrors OpenAPI)

/// A point in 3D galactic space. Mirrors `app_schemas_common_PositionSchema`.
public struct Position: Equatable, Sendable, Codable {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(x: Double, y: Double, z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    /// Euclidean distance to another position (scene units).
    public func distance(to other: Position) -> Double {
        let dx = x - other.x, dy = y - other.y, dz = z - other.z
        return (dx * dx + dy * dy + dz * dz).squareRoot()
    }
}

/// A charted star as it appears in the stars list. Mirrors
/// `app_schemas_stars_StarItemSchema` (camelCased). `hasLife` and `entryPoint`
/// are nullable in the schema.
public struct StarItem: Equatable, Sendable, Codable {
    public var designation: String
    public var spectralType: String
    public var color: String
    public var distanceFromReplicant: Double   // light-years
    public var estimatedTravelTime: Int        // seconds
    public var position: Position
    public var estimatedPlanets: Int
    public var explored: Bool
    public var hasLife: Bool?
    public var entryPoint: String?

    public init(
        designation: String,
        spectralType: String,
        color: String,
        distanceFromReplicant: Double,
        estimatedTravelTime: Int,
        position: Position,
        estimatedPlanets: Int,
        explored: Bool,
        hasLife: Bool?,
        entryPoint: String?
    ) {
        self.designation = designation
        self.spectralType = spectralType
        self.color = color
        self.distanceFromReplicant = distanceFromReplicant
        self.estimatedTravelTime = estimatedTravelTime
        self.position = position
        self.estimatedPlanets = estimatedPlanets
        self.explored = explored
        self.hasLife = hasLife
        self.entryPoint = entryPoint
    }
}

// MARK: - Overlay taxonomies

/// How thoroughly a system has been reconnoitered. Richer than the list
/// schema's `explored: Bool` — pending a real recon field.
public enum Recon: String, Equatable, Sendable, CaseIterable {
    case scanned   // ● full intel
    case visited   // ◐ been there · partial intel
    case aware     // ○ detected only · uncharted

    public var label: String {
        switch self {
        case .scanned: "Scanned"
        case .visited: "Visited"
        case .aware:   "Aware"
        }
    }

    /// Dimming factor applied to the system's glow in the field (1 = full).
    public var dim: Double {
        switch self {
        case .scanned: 1.0
        case .visited: 0.78
        case .aware:   0.5
        }
    }
}

/// Detected biosignature tier. Richer than the schema's `hasLife: Bool`.
public enum LifeTier: String, Equatable, Sendable, CaseIterable {
    case microbial, flora, fauna

    public var label: String { rawValue.capitalized }
    public var tier: Int {
        switch self {
        case .microbial: 1
        case .flora:     2
        case .fauna:     3
        }
    }
}

/// Whose probe presence occupies a system.
public enum Presence: String, Equatable, Sendable, CaseIterable {
    case mine, npc

    public var label: String {
        switch self {
        case .mine: "My presence"
        case .npc:  "Foreign replicant"
        }
    }
}

// MARK: - Galaxy presentation model

/// A charted system as the map renders it: the API `StarItem` plus the overlay
/// fields the info-layers and dossier need.
public struct GalaxySystem: Identifiable, Equatable, Sendable {
    public var star: StarItem
    public var name: String              // display name (not in the list schema)
    public var recon: Recon
    public var lifeTier: LifeTier?
    public var resourceRichness: Double  // 0…1 mineable richness
    public var deviceCount: Int
    public var vesselCount: Int
    public var presence: Presence?
    public var hasRelay: Bool            // participates in a relay mesh
    public var isCurrentLocation: Bool

    public var id: String { star.designation }
    public var position: Position { star.position }
    public var spectralType: String { star.spectralType }

    public init(
        star: StarItem,
        name: String,
        recon: Recon,
        lifeTier: LifeTier?,
        resourceRichness: Double,
        deviceCount: Int,
        vesselCount: Int,
        presence: Presence?,
        hasRelay: Bool,
        isCurrentLocation: Bool
    ) {
        self.star = star
        self.name = name
        self.recon = recon
        self.lifeTier = lifeTier
        self.resourceRichness = resourceRichness
        self.deviceCount = deviceCount
        self.vesselCount = vesselCount
        self.presence = presence
        self.hasRelay = hasRelay
        self.isCurrentLocation = isCurrentLocation
    }
}

/// A superluminal link between two systems. No OpenAPI schema describes the
/// relay mesh yet — modeled app-side, pending a real endpoint.
public struct RelayLink: Identifiable, Equatable, Sendable {
    public var a: String   // system designation
    public var b: String   // system designation
    public var owner: Presence
    public var planned: Bool

    public var id: String { "\(a)→\(b)" }

    public init(a: String, b: String, owner: Presence, planned: Bool = false) {
        self.a = a
        self.b = b
        self.owner = owner
        self.planned = planned
    }
}

// MARK: - Focus

/// Which scale the map is showing: the whole galaxy, or one drilled-in system.
public enum StarMapFocus: Equatable, Sendable {
    case galaxy
    case system(String)   // system designation
}

// MARK: - Info layers

/// The toggleable information overlays in the galaxy HUD.
public enum InfoLayer: String, Equatable, Sendable, CaseIterable, Identifiable {
    case presence, relay, recon, life, resource, npc

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .presence: "My presence"
        case .relay:    "FTL relay network"
        case .recon:    "Recon state"
        case .life:     "Life"
        case .resource: "Resources"
        case .npc:      "Other replicants"
        }
    }

    public var legend: String {
        switch self {
        case .presence: "Systems with my devices & vessels"
        case .relay:    "Superluminal links between nodes"
        case .recon:    "Scanned · visited · only aware"
        case .life:     "Biosignatures detected"
        case .resource: "Mineable richness"
        case .npc:      "Foreign probe presence"
        }
    }
}
