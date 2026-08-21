//
//  StarItem.swift
//  UniverseModels
//
//  A charted star as it appears in the census (`GET /v1/replicants/{code}/stars`).
//  Mirrors `app_schemas_stars_StarItemSchema`. This is the "root source of truth"
//  row: every star we can observe appears here, and travelling + scanning is what
//  hydrates the deeper locations tree beneath an explored system.
//

import Foundation

/// A charted star as it appears in the stars list. Mirrors
/// `app_schemas_stars_StarItemSchema` (camelCased). `hasLife`, `entryPoint`,
/// and `region` are nullable in the schema; `hasHub` and `hasWard` are not —
/// both arrive present-or-absent, so absent reads as false.
public struct StarItem: Equatable, Sendable, Codable {
    public var designation: String
    public var spectralType: String
    public var color: String
    public var position: Position
    public var estimatedPlanets: Int
    public var explored: Bool
    public var hasLife: Bool?
    public var entryPoint: String?
    public var region: String?
    public var hasHub: Bool
    public var hasWard: Bool

    public init(
        designation: String,
        spectralType: String,
        color: String,
        position: Position,
        estimatedPlanets: Int,
        explored: Bool,
        hasLife: Bool?,
        entryPoint: String?,
        region: String? = nil,
        hasHub: Bool = false,
        hasWard: Bool = false
    ) {
        self.designation = designation
        self.spectralType = spectralType
        self.color = color
        self.position = position
        self.estimatedPlanets = estimatedPlanets
        self.explored = explored
        self.hasLife = hasLife
        self.entryPoint = entryPoint
        self.region = region
        self.hasHub = hasHub
        self.hasWard = hasWard
    }
}
