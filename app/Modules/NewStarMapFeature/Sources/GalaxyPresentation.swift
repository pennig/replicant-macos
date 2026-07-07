//
//  GalaxyPresentation.swift
//  NewStarMapFeature
//
//  Presentation value types for the galaxy HUD, ported from the SceneKit
//  `StarMapFeature` (StarMapModels.swift) so this feature stands alone as it
//  grows to replace it. Pure value types (no SwiftUI/Metal) built over the shared
//  `UniverseModels` census types, so they stay testable.
//
//  Only the galaxy-scale subset is ported here — the system-focus types
//  (`StarMapFocus`, drill-in) come with the zoom-to-solar-system work later.
//

import Foundation
import UniverseModels

// MARK: - Overlay taxonomies

/// Whose probe presence occupies a system.
enum Presence: String, Equatable, Sendable, CaseIterable {
    case mine, npc

    var label: String {
        switch self {
        case .mine: "My presence"
        case .npc:  "Foreign replicant"
        }
    }
}

// MARK: - Galaxy presentation model

/// A charted system as the HUD renders it: the API `StarItem` plus the overlay
/// fields the dossier needs. The stars list only carries `explored`/`hasLife`, so
/// the richer overlays (presence, relay, life tier, resources) start empty until a
/// deeper scan fills them in.
struct GalaxySystem: Identifiable, Equatable, Sendable {
    var star: StarItem
    var name: String
    var recon: Recon
    var lifeTier: LifeTier?
    var resourceRichness: Double
    var deviceCount: Int
    var vesselCount: Int
    var presence: Presence?
    var hasRelay: Bool
    var isCurrentLocation: Bool

    var id: String { star.designation }
    var position: Position { star.position }
    var spectralType: String { star.spectralType }

    /// Build a galaxy system from a freshly-surveyed star row.
    init(surveyed star: StarItem, isCurrentLocation: Bool) {
        self.star = star
        self.name = star.designation
        self.recon = star.explored ? .visited : .aware
        self.lifeTier = nil
        self.resourceRichness = 0
        self.deviceCount = 0
        self.vesselCount = 0
        self.presence = nil
        self.hasRelay = false
        self.isCurrentLocation = isCurrentLocation
    }
}

// MARK: - Focus

/// Which scale the map is showing: the whole galaxy, or one drilled-in system.
enum StarMapFocus: Equatable, Sendable {
    case galaxy
    case system(String)   // system designation
}

// MARK: - Database rebuild (first-run survey)

/// The themed first-run "database rebuild" sequence. The map presents the live
/// star survey as a recovery from (fictional) database corruption.
enum BootPhase: Equatable, Sendable {
    case idle               // normal galaxy
    case corruptionDetected // the fake error modal, awaiting manual override
    case rebuilding         // survey running; progress shown, stars stream in
    case complete           // brief success state before auto-dismiss
}

// MARK: - Info layers

/// The toggleable information overlays in the galaxy HUD. Ported for the layer
/// rail; not yet wired to the renderer (the rail is presentational for now).
public enum InfoLayer: String, Equatable, Sendable, CaseIterable, Identifiable {
    case presence, relay, recon, life, resource, npc

    public var id: String { rawValue }

    var label: String {
        switch self {
        case .presence: "My presence"
        case .relay:    "FTL relay network"
        case .recon:    "Recon state"
        case .life:     "Life"
        case .resource: "Resources"
        case .npc:      "Other replicants"
        }
    }
}
