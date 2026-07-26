//
//  WorldSnapshot.swift
//  Replicould — DirectiveEngine
//
//  The world as a step machine sees it: one consistent read of reconciled
//  SQLite state, keyed for lookup. Missions are pure functions over this — they
//  perform no I/O and never see a raw event, which is what makes them testable
//  as fixtures and immune to replay (directives design spec §4/§6).
//

import Foundation
import GameModels
import SQLiteData
import UniverseModels

// `GameModels.Operation` is qualified throughout rather than aliased: a
// file-private typealias cannot appear in this type's public API, and
// `Foundation.Operation` would otherwise win the name.

public struct WorldSnapshot: Equatable, Sendable {
    /// The fleet, by device code.
    public let devices: [String: Device]
    /// The single OPEN operation per device, by device code. Closed ops are
    /// excluded: a step machine asks "is this device busy?", and a completed op
    /// is not busy.
    public let openOperations: [String: GameModels.Operation]
    /// This directive's audit trail, oldest first. Completion detection reads
    /// it: the `directive.completed` route writes an entry, and the mission
    /// observes that ROW rather than the event — the observe-reconciled-state
    /// invariant is what keeps missions replay-immune.
    public let log: [DirectiveLogEntry]
    /// Cached `StarSystem` blobs for the systems this directive cares about, by
    /// star designation. Only the directive's own targets (plus its origin and
    /// the vessel's current system) are decoded: decoding the whole catalogue
    /// costs real time at thousands of bodies.
    public let systems: [String: StarSystem]
    /// The moment this snapshot was taken. Every time comparison in a mission
    /// uses this rather than `Date()`, so step machines stay pure and their
    /// tests deterministic.
    public let now: Date

    public init(
        devices: [String: Device],
        openOperations: [String: GameModels.Operation],
        log: [DirectiveLogEntry] = [],
        systems: [String: StarSystem] = [:],
        now: Date
    ) {
        self.devices = devices
        self.openOperations = openOperations
        self.log = log
        self.systems = systems
        self.now = now
    }

    public func device(_ code: String) -> Device? { devices[code] }
    public func openOperation(for code: String) -> GameModels.Operation? { openOperations[code] }
    public func system(_ designation: String) -> StarSystem? { systems[designation] }

    /// One consistent read of everything a mission reasons over, scoped to the
    /// directive being evaluated.
    public static func read(
        from database: any DatabaseReader,
        now: Date,
        directive: Directive
    ) async throws -> WorldSnapshot {
        // The systems worth decoding: every target, the origin, and whatever
        // system the vessel is in right now (the arrival check needs it).
        let baseWanted = Set(directive.targets)
            .union(directive.originDesignation.map { [$0] } ?? [])
        let directiveID = directive.id
        let vesselCode = directive.deviceCode

        return try await database.read { db in
            let devices = try Device.all.fetchAll(db)
            let operations = try GameModels.Operation
                .where { $0.status.in(OperationStatus.openCases) }
                .fetchAll(db)
            let log = try DirectiveLogEntry
                .where { $0.directiveID.eq(directiveID) }
                .order { $0.occurredAt }
                .fetchAll(db)

            var wanted = baseWanted
            if let vessel = devices.first(where: { $0.deviceCode == vesselCode }),
               let location = vessel.location {
                wanted.insert(SiteAssay.system(of: location))
            }
            let details = try SystemDetail
                .where { $0.designation.in(Array(wanted)) }
                .fetchAll(db)
            let systems = details.reduce(into: [String: StarSystem]()) { systems, detail in
                // A blob that fails to decode is treated as absent: the mission
                // then can't prove the target is scanned and surveys it again,
                // which is the safe direction to be wrong in.
                if let system = try? detail.system() { systems[detail.designation] = system }
            }

            return WorldSnapshot(
                devices: Dictionary(devices.map { ($0.deviceCode, $0) }, uniquingKeysWith: { _, last in last }),
                openOperations: Dictionary(operations.map { ($0.entityCode, $0) }, uniquingKeysWith: { _, last in last }),
                log: log,
                systems: systems,
                now: now
            )
        }
    }
}
