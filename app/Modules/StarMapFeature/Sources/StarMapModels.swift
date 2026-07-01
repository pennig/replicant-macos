//
//  StarMapModels.swift
//  StarMapFeature
//
//  Presentation value types for the Galaxy Explorer. The shared, API-shaped core
//  (`Position`, `StarItem`, `Recon`, `LifeTier`) now lives in `UniverseModels`;
//  this file keeps only the map-specific overlays.
//
//  `GalaxySystem` is the presentation model the scene/HUD/info-layers consume.
//  It wraps a `StarItem` and adds overlay fields the census schema does not
//  carry (relay mesh membership, presence, device/vessel counts, recon detail,
//  resource richness, life tier). Those are sourced app-side for now and marked
//  as pending real endpoints — see `GalaxyData`.
//
//  Pure value types only: no SwiftUI/AppKit/SceneKit here, so the model is
//  importable in tests. Color mapping lives with the scene (NSColor) and the
//  HUD (SwiftUI Color) respectively.
//

import Foundation
import UniverseModels

// MARK: - Overlay taxonomies

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

    /// Build a galaxy system from a freshly-surveyed star. The stars list only
    /// carries `explored`/`hasLife`, so the richer overlays (presence, relay,
    /// life tier, resources) start empty until a deeper scan fills them in.
    public init(surveyed star: StarItem, isCurrentLocation: Bool) {
        self.init(
            star: star,
            name: star.designation,
            recon: star.explored ? .visited : .aware,
            lifeTier: nil,
            resourceRichness: 0,
            deviceCount: 0,
            vesselCount: 0,
            presence: nil,
            hasRelay: false,
            isCurrentLocation: isCurrentLocation
        )
    }

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

// MARK: - Database rebuild (first-run survey)

/// The themed first-run "database rebuild" sequence. The map presents the live
/// star survey as a recovery from (fictional) database corruption.
public enum BootPhase: Equatable, Sendable {
    case idle               // normal galaxy
    case corruptionDetected // the fake error modal, awaiting manual override
    case rebuilding         // survey running; progress shown, stars stream in
    case complete           // brief success state before auto-dismiss
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
