//
//  Recon.swift
//  UniverseModels
//
//  Shared reconnaissance taxonomies. `Recon` grades how thoroughly a system (or
//  body) has been reconnoitered — richer than the census's `explored: Bool` — and
//  `LifeTier` grades a detected biosignature beyond the census's `hasLife: Bool`.
//  Both the star map (glow dimming) and the locations catalog (filter/sort by
//  knowledge) key off these, so they live in the shared domain.
//

import Foundation

/// How thoroughly a system or body has been reconnoitered. Richer than the
/// census schema's `explored: Bool`:
///   - `.aware`   — in the census, `explored: false`. Position + estimates only.
///   - `.visited` — `explored: true`. Full body roster known, but *estimated*
///                  (per-body `scanned: false`, `type_estimated: true`).
///   - `.scanned` — per-body `scanned: true`. Real physical data + resource sites.
public enum Recon: String, Equatable, Sendable, Codable, CaseIterable {
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
public enum LifeTier: String, Equatable, Sendable, Codable, CaseIterable {
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
