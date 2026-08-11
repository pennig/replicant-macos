//
//  Theatre.swift
//  Replicould — DirectiveEngine
//
//  A logistics theatre: a depot to explore outward from and accrete inward to.
//

import Foundation

public struct Theatre: Equatable, Sendable, Identifiable {
    /// The depot location IS the identity: a stateless brain must name the same
    /// theatre every tick from world state alone.
    public var id: String { depot }
    /// Where stock and printing live, e.g. `AINALRAM-BELT-1`.
    public let depot: String
    public let system: String
    public let origin: Origin
    public let readiness: Readiness
    /// Total units at the depot.
    public let stock: Int

    public enum Origin: Equatable, Sendable {
        case pinned
        /// Carries the claiming `system_hub` device's code.
        case systemHub(String)
        case derived
    }

    public enum Readiness: Equatable, Sendable {
        case operational
        case claimed(missing: Set<Shortfall>)
    }

    /// What a `.claimed` theatre lacks — the clauses of the recognition
    /// predicate reported individually rather than collapsed to nil.
    public enum Shortfall: String, Equatable, Sendable, CaseIterable, Codable {
        case noPrintCapableDevice
        case noStock
        case offMesh
    }

    public var isOperational: Bool { readiness == .operational }

    public init(
        depot: String, system: String, origin: Origin,
        readiness: Readiness, stock: Int
    ) {
        self.depot = depot
        self.system = system
        self.origin = origin
        self.readiness = readiness
        self.stock = stock
    }
}
