//
//  FleetTag.swift
//  Replicould — GameModels
//
//  The `auto:<goal>[:<depot|belt>]` fleet-tag grammar, replacing six
//  formatters and seven parsers with one type. The third segment is a
//  theatre depot for every goal except `.mine`, which ferries belong to a
//  belt instead — `MineRecipe.fleetTag(forTheatre:)`'s INSTALL tag and a
//  mine-ferry tag are the same string; only the caller's context tells them
//  apart (S1.1).
//

/// One canonical fleet-tag grammar. `string` is always lowercase — the
/// server normalises tags to lowercase regardless of what was sent.
public struct FleetTag: Sendable, Codable, CustomStringConvertible {
    public enum Goal: String, CaseIterable, Sendable, Codable {
        case haul, survey, salvage, mine, carrier, event
        case tendMesh = "tendmesh"
    }

    public enum Scope: Sendable, Codable {
        case theatre(depot: String)
        case belt(designation: String)

        /// The raw third segment; a theatre depot and a belt are both
        /// designations — the goal decides which one this is.
        public var designation: String {
            switch self {
            case .theatre(let depot): depot
            case .belt(let designation): designation
            }
        }
    }

    public enum MatchPolicy: Sendable { case exact, exactOrUnscoped }

    public let goal: Goal
    public let scope: Scope?

    public init(goal: Goal, scope: Scope? = nil) {
        self.goal = goal
        self.scope = scope.map(Self.lowercased)
    }

    public init?(parsing raw: String) {
        let lowered = raw.lowercased()
        guard lowered.hasPrefix(Self.prefix) else { return nil }
        let segments = lowered.dropFirst(Self.prefix.count).split(separator: ":", maxSplits: 1)
        guard let goalSegment = segments.first, let goal = Goal(rawValue: String(goalSegment)) else { return nil }
        guard segments.count > 1 else {
            self.init(goal: goal)
            return
        }
        let designation = String(segments[1])
        self.init(goal: goal, scope: goal == .mine ? .belt(designation: designation) : .theatre(depot: designation))
    }

    public var string: String {
        guard let scope else { return "\(Self.prefix)\(goal.rawValue)" }
        return "\(Self.prefix)\(goal.rawValue):\(scope.designation)"
    }

    public var unscoped: FleetTag { FleetTag(goal: goal) }
    public var isScoped: Bool { scope != nil }
    public static let prefix = "auto:"
    public var description: String { string }

    private static func lowercased(_ scope: Scope) -> Scope {
        switch scope {
        case .theatre(let depot): .theatre(depot: depot.lowercased())
        case .belt(let designation): .belt(designation: designation.lowercased())
        }
    }
}

// MARK: - Equality

extension FleetTag: Equatable, Hashable {
    // R2: two tags with the same designation are the same reservation even
    // when their Scope case differs (.theatre vs .belt) — see task report.
    public static func == (lhs: FleetTag, rhs: FleetTag) -> Bool {
        lhs.goal == rhs.goal && lhs.scope?.designation == rhs.scope?.designation
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(goal)
        hasher.combine(scope?.designation)
    }
}

extension FleetTag.Scope: Equatable, Hashable {
    // Same rule as FleetTag.== — identity is the designation, not the case.
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.designation == rhs.designation }
    public func hash(into hasher: inout Hasher) { hasher.combine(designation) }
}
