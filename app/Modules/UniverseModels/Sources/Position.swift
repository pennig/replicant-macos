//
//  Position.swift
//  UniverseModels
//
//  A point in 3D galactic space. Mirrors `app_schemas_common_PositionSchema`.
//  Lives in the shared universe domain so both the star map and the locations
//  catalog measure distance in one, consistent coordinate space.
//

import Foundation

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

    /// Component-wise difference — used to re-base absolute galactic
    /// coordinates onto the replicant (so home sits at the scene origin).
    public static func - (lhs: Position, rhs: Position) -> Position {
        Position(x: lhs.x - rhs.x, y: lhs.y - rhs.y, z: lhs.z - rhs.z)
    }
}
