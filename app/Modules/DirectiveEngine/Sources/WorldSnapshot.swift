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
    /// The moment this snapshot was taken. Every time comparison in a mission
    /// uses this rather than `Date()`, so step machines stay pure and their
    /// tests deterministic.
    public let now: Date

    public init(
        devices: [String: Device],
        openOperations: [String: GameModels.Operation],
        now: Date
    ) {
        self.devices = devices
        self.openOperations = openOperations
        self.now = now
    }

    public func device(_ code: String) -> Device? { devices[code] }
    public func openOperation(for code: String) -> GameModels.Operation? { openOperations[code] }

    /// One consistent read of the tables a mission reasons over.
    public static func read(from database: any DatabaseReader, now: Date) async throws -> WorldSnapshot {
        try await database.read { db in
            let devices = try Device.all.fetchAll(db)
            let operations = try GameModels.Operation
                .where { $0.status.in(OperationStatus.openCases) }
                .fetchAll(db)
            return WorldSnapshot(
                devices: Dictionary(devices.map { ($0.deviceCode, $0) }, uniquingKeysWith: { _, last in last }),
                openOperations: Dictionary(operations.map { ($0.entityCode, $0) }, uniquingKeysWith: { _, last in last }),
                now: now
            )
        }
    }
}
