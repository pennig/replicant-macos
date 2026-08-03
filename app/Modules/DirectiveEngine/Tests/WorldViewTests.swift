//
//  WorldViewTests.swift
//  Replicould — DirectiveEngine
//
//  The galaxy-wide brain snapshot: every meshed system, every census star
//  position, every non-depleted salvage assay, live location events, and the
//  print hub — the single input every later brain task consumes.
//

import Foundation
import GameDatabase
import GameModels
import SQLiteData
import Testing
import UniverseModels
@testable import DirectiveEngine

@Suite("WorldView")
struct WorldViewTests {
    /// The four cheap tables read in one pass: mesh derives from a relaying
    /// relay's location (not the `ftlLinks` table — see
    /// `SalvageTargetPlanner.meshSystems(in:)`), star positions come straight
    /// off the census, and salvage sums a non-depleted assay's totals.
    @Test func readDerivesMeshFromRelayingRelays() async throws {
        let db = try GameDatabase.bootstrap()
        try await db.write { db in
            try seedRelay(db, code: "R1", location: "SOL-3-L4", status: "relaying")
            try seedStar(db, designation: "SOL", x: 0, y: 0, z: 0)
            try seedSalvageAssay(
                db, id: "VEGA-2-SAL-1", system: "VEGA",
                totals: ["metal": 1200, "silicon": 800], depleted: false
            )
        }
        let now = Date(timeIntervalSince1970: 1_000)
        let view = try await db.read { try WorldView.read(from: $0, now: now) }
        #expect(view.meshSystems == ["SOL"])
        #expect(view.starPositions["SOL"] == Position(x: 0, y: 0, z: 0))
        #expect(view.salvageUnits["VEGA"] == 2000)
        #expect(view.now == now)
    }

    /// A depleted site's units never count — `SalvageTargetPlanner`'s target
    /// ranking excludes them for the same reason (a drained site's `totals`
    /// only ever go up, so `depleted` is the sole signal a site is spent).
    @Test func depletedSalvageExcluded() async throws {
        let db = try GameDatabase.bootstrap()
        try await db.write { db in
            try seedSalvageAssay(db, id: "DEAD-1-SAL-1", system: "DEAD", totals: ["metal": 500], depleted: true)
        }
        let view = try await db.read { try WorldView.read(from: $0, now: Date()) }
        #expect(view.salvageUnits["DEAD"] == nil)
    }

    /// A live event's system is surfaced; a completed one is not — matches
    /// `LocationEvent.isActive`'s case-insensitive `"active"` check exactly.
    @Test func eventSystemsReflectOnlyActiveEvents() async throws {
        let db = try GameDatabase.bootstrap()
        try await db.write { db in
            try seedLocationEvent(db, designation: "KRIOS-2-EVT-001", location: "KRIOS-2", status: "Active")
            try seedLocationEvent(db, designation: "TAU-1-EVT-002", location: "TAU-1", status: "completed")
        }
        let view = try await db.read { try WorldView.read(from: $0, now: Date()) }
        #expect(view.eventSystems == ["KRIOS"])
    }

    /// The print hub surfaces only when its system is meshed — an off-mesh hub
    /// is a later concern (escalate/unsupported, per the 06 design), not
    /// something the brain can dispatch a `deliver` toward yet.
    @Test func hubLocationSurfacesOnlyWhenMeshed() async throws {
        let db = try GameDatabase.bootstrap()
        try await db.write { db in
            try seedRelay(db, code: "R1", location: "SOL-3-L4", status: "relaying")
            try seedPrintHub(db, code: "AF1", location: "SOL-3")
        }
        let meshed = try await db.read { try WorldView.read(from: $0, now: Date()) }
        #expect(meshed.hubLocation == "SOL-3")

        let db2 = try GameDatabase.bootstrap()
        try await db2.write { db in
            try seedPrintHub(db, code: "AF1", location: "VEGA-3")
        }
        let unmeshed = try await db2.read { try WorldView.read(from: $0, now: Date()) }
        #expect(unmeshed.hubLocation == nil)
    }

    /// Devices come back keyed by code, the whole fleet — the brain's ranking
    /// passes need every device, not a directive-scoped subset.
    @Test func devicesAreKeyedByCode() async throws {
        let db = try GameDatabase.bootstrap()
        try await db.write { db in
            try seedDevice(db, code: "V1", location: "SOL-3")
        }
        let view = try await db.read { try WorldView.read(from: $0, now: Date()) }
        #expect(view.devices["V1"]?.location == "SOL-3")
    }

    /// An empty database is a valid snapshot, not an error — the brain must
    /// tick cleanly before the fleet has cold-loaded.
    @Test func emptyDatabaseYieldsAnEmptySnapshot() async throws {
        let db = try GameDatabase.bootstrap()
        let view = try await db.read { try WorldView.read(from: $0, now: Date()) }
        #expect(view.devices.isEmpty)
        #expect(view.starPositions.isEmpty)
        #expect(view.meshSystems.isEmpty)
        #expect(view.salvageUnits.isEmpty)
        #expect(view.eventSystems.isEmpty)
        #expect(view.hubLocation == nil)
        #expect(view.beltsBySystem.isEmpty)
    }

    /// Task 9 scope addition: `beltsBySystem` exists on `WorldView` ahead of
    /// its Task 11 hydration, always empty out of `read(from:now:)` since
    /// that read touches no blob.
    @Test func beltsBySystemIsAlwaysEmptyUntilTask11() async throws {
        let db = try GameDatabase.bootstrap()
        try await db.write { db in
            try seedRelay(db, code: "R1", location: "SOL-3-L4", status: "relaying")
        }
        let view = try await db.read { try WorldView.read(from: $0, now: Date()) }
        #expect(view.beltsBySystem.isEmpty)
    }
}
