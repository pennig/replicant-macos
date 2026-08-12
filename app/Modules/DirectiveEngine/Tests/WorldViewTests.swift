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
    @Test func theatreSurfacesOnlyWhenMeshed() async throws {
        let db = try GameDatabase.bootstrap()
        try await db.write { db in
            try seedRelay(db, code: "R1", location: "SOL-3-L4", status: "relaying")
            try seedPrintHub(db, code: "AF1", location: "SOL-3")
            try seedHubStockpile(db, location: "SOL-3", resources: 50_000)
        }
        let meshed = try await db.read { try WorldView.read(from: $0, now: Date()) }
        #expect(meshed.theatres.map(\.depot) == ["SOL-3"])
        #expect(meshed.theatres[0].isOperational)

        let db2 = try GameDatabase.bootstrap()
        try await db2.write { db in
            try seedPrintHub(db, code: "AF1", location: "VEGA-3")
            try seedHubStockpile(db, location: "VEGA-3", resources: 50_000)
        }
        let unmeshed = try await db2.read { try WorldView.read(from: $0, now: Date()) }
        #expect(unmeshed.theatres.isEmpty)
    }

    /// **A print-capable device standing on nothing is not a hub.**
    ///
    /// `Device.isPrintHub` is a CAPABILITY predicate, and a HEAVEN vessel
    /// advertises `enqueue_print` — so without the stock clause the carrier
    /// becomes its own hub wherever it happens to park. That is exactly what
    /// happened live on 2026-08-04: the carrier flew to RUGULUS-1-L4, the brain
    /// relocated with it, and the reserve rail read that location's stockpile
    /// (genuinely zero) while the real hub held 73,539 units.
    @Test func aPrintCapableDeviceWithNoStockpileIsNotAHub() async throws {
        let db = try GameDatabase.bootstrap()
        try await db.write { db in
            try seedRelay(db, code: "R1", location: "SOL-3-L4", status: "relaying")
            // A carrier parked in the meshed system, print-capable like the real
            // HEAVEN vessels, standing at a location holding nothing.
            try seedDevice(
                db, code: "V1", type: "heaven_vessel", location: "SOL-3-L4",
                availableCommands: ["enqueue_print", "travel"]
            )
        }

        let view = try await db.read { try WorldView.read(from: $0, now: Date()) }

        #expect(view.theatres.isEmpty)
    }

    /// …and when a real stockpile IS present, the richest one wins — a total
    /// order, so a stateless brain names the same hub every tick.
    @Test func theRichestStockpiledLocationWins() async throws {
        let db = try GameDatabase.bootstrap()
        try await db.write { db in
            try seedRelay(db, code: "R1", location: "SOL-3-L4", status: "relaying")
            try seedPrintHub(db, code: "AF1", location: "SOL-3")
            try seedDevice(
                db, code: "V1", type: "heaven_vessel", location: "SOL-3-L4",
                availableCommands: ["enqueue_print"]
            )
            try seedHubStockpile(db, location: "SOL-3", resources: 50_000)
            try seedHubStockpile(db, location: "SOL-3-L4", resources: 12)
        }

        let view = try await db.read { try WorldView.read(from: $0, now: Date()) }

        #expect(
            view.theatres.map(\.depot) == ["SOL-3"],
            "the autofactory's stocked location, not the vessel's scraps"
        )
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
        #expect(view.theatres.isEmpty)
        #expect(view.beltsBySystem.isEmpty)
        #expect(view.replicantSystems.isEmpty)
        #expect(view.replicantHostDevices.isEmpty)
        #expect(view.stockpileUnits.isEmpty)
    }

    /// Every location the census shows holding units, reduced to its system and
    /// SUMMED there — the piles a Haul Run exists to collect.
    ///
    /// Summing is what makes the magnitude usable: a system with five modest
    /// piles is worth more than one with a single pile of the same size, and
    /// both grow's ranking and any per-system judgement ask about the system.
    /// A location holding nothing contributes nothing to its system's total.
    @Test func stockpileUnitsSumEveryLocationHoldingUnitsPerSystem() async throws {
        let db = try GameDatabase.bootstrap()
        try await db.write { db in
            try seedStockpile(db, location: "ORASALAS-6-9", resources: 318)
            try seedStockpile(db, location: "ORASALAS-9-10", resources: 222)
            try seedStockpile(db, location: "ORASALAS-3-2", resources: 0)
            try seedStockpile(db, location: "VEGA-2", resources: 40)
        }
        let view = try await db.read { try WorldView.read(from: $0, now: Date()) }
        #expect(view.stockpileUnits == ["ORASALAS": 540, "VEGA": 40])
    }

    /// A census row reporting no units is not a stockpile. Most of the table is
    /// exactly that — a location visited once and found empty — so a read that
    /// took every row would make every system we have ever looked at pin its
    /// own relay forever, and prune would have nothing left to offer.
    @Test func aLocationHoldingNothingIsNotAStockpile() async throws {
        let db = try GameDatabase.bootstrap()
        try await db.write { db in
            try seedStockpile(db, location: "DEAD-1", resources: 0)
        }
        let view = try await db.read { try WorldView.read(from: $0, now: Date()) }
        #expect(view.stockpileUnits.isEmpty)
    }

    /// The `replicants` read (Task 23), projected into the two facts the brain
    /// actually reasons over: WHERE authority stands and WHICH hull carries it.
    ///
    /// `currentStar` goes through `SiteAssay.system(of:)`, so a row that
    /// arrives carrying a location rather than a bare designation still reduces
    /// to its system — the same normalisation every other designation in this
    /// file gets. A replicant with neither field set contributes to neither
    /// projection rather than seeding an empty string into one of them, which
    /// would read as a real system named "".
    @Test func readProjectsReplicantsIntoAuthorityAndHostFacts() async throws {
        let db = try GameDatabase.bootstrap()
        try await db.write { db in
            try seedReplicant(db, code: "REP1", star: "SOL", hostedDeviceCode: "V1")
            try seedReplicant(db, code: "REP2", star: "VEGA-3", hostedDeviceCode: "V2")
            try seedReplicant(db, code: "REP3", star: nil, hostedDeviceCode: nil)
        }
        let view = try await db.read { try WorldView.read(from: $0, now: Date()) }
        #expect(view.replicantSystems == ["SOL", "VEGA"])
        #expect(view.replicantHostDevices == ["V1", "V2"])
    }

    /// No `systemDetails` row means no belt data, regardless of mesh status —
    /// `beltsBySystem` stays empty when there's nothing to decode in the
    /// first place. The bounded-decode behaviour itself (surveyed + unmeshed
    /// only, malformed-blob handling, classification) is covered end-to-end
    /// in `WorldViewBeltsTests` (Task 11).
    @Test func beltsBySystemIsEmptyWithNoSystemDetailRows() async throws {
        let db = try GameDatabase.bootstrap()
        try await db.write { db in
            try seedRelay(db, code: "R1", location: "SOL-3-L4", status: "relaying")
        }
        let view = try await db.read { try WorldView.read(from: $0, now: Date()) }
        #expect(view.beltsBySystem.isEmpty)
    }
}
