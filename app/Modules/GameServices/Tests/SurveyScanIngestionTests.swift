//
//  SurveyScanIngestionTests.swift
//  Replicould — GameServices
//
//  `LocationsClient.ingestSurveyScans` — folding an `ami.survey.digest`'s
//  `report.scans[]` (API v2.3.3) into `SystemDetail` and `SiteAssay`.
//
//  This is the only path by which a Survey Run's scan intel reaches the
//  catalog: an AMI-adopted drone emits no per-device events, so if this
//  regresses, every body a survey scans silently stays a roster stub.
//

import Dependencies
import Foundation
import GameDatabase
import GameModels
import SQLiteData
import Testing
import UniverseModels
import Utils
@testable import GameServices

@Suite("LocationsClient.ingestSurveyScans")
struct SurveyScanIngestionTests {
    private func payload(_ json: String) throws -> [String: JSONValue] {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        guard case .object(let object) = value else {
            Issue.record("expected a JSON object"); return [:]
        }
        return object
    }

    /// One planet scan and one moon scan in a single digest, as a live survey
    /// tick sends them.
    private var digest: String {
        """
        { "directive": "survey_system",
          "report": { "progress": { "remaining": 7, "scanned": 2, "total": 9 },
            "scans": [
              { "device_code": "A1D08194", "scan_target": "UDKUDUA-7", "scan_type": "planet",
                "report": {
                  "planet": { "designation": "UDKUDUA-7", "type": "Super Earth",
                    "axial_tilt_deg": 45.2, "rings": false, "rotation_period_hours": 75,
                    "orbital_distance_au": 1.525, "orbital_period_days": 1025.39,
                    "in_habitable_zone": false, "life_stage": "none",
                    "tags": ["rocky"] },
                  "moons": [
                    { "designation": "UDKUDUA-7-1", "scanned": false, "type": "Icy" },
                    { "designation": "UDKUDUA-7-2", "scanned": false, "type": "Rocky" } ] } },
              { "device_code": "A697D0E8", "scan_target": "UDKUDUA-4-1", "scan_type": "moon",
                "report": { "moon": { "designation": "UDKUDUA-4-1", "type": "Icy",
                  "tidally_locked": true, "orbital_period_hours": 599.03,
                  "orbital_distance_km": 733591.1,
                  "salvage": [
                    { "designation": "UDKUDUA-4-1-SAL-1", "location": "UDKUDUA-4-1",
                      "name": "Derelict Survey Probe", "salvage_type": "derelict_probe",
                      "depleted": false,
                      "resources_remaining": { "conductive": 214, "rares": 64 } } ] } } }
            ] } }
        """
    }

    private func ingest(
        _ json: String, into database: any DatabaseWriter, now: TimeInterval = 1_000
    ) async throws -> Int {
        let p = try payload(json)
        return try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: now))
        } operation: {
            try await LocationsClient.liveValue.ingestSurveyScans(payload: p)
        }
    }

    private func system(_ designation: String, in database: any DatabaseWriter) async throws -> StarSystem? {
        let row = try await database.read { db in
            try SystemDetail.where { $0.designation.eq(designation) }.fetchOne(db)
        }
        return try row?.system()
    }

    /// A survey can scan bodies in a system the catalog has never hydrated —
    /// the intel must not be dropped for want of a container.
    @Test func seedsASystemTheCatalogHasNeverSeen() async throws {
        let database = try GameDatabase.bootstrap()
        let count = try await ingest(digest, into: database)
        #expect(count == 2)

        let stored = try #require(try await system("UDKUDUA", in: database))
        #expect(stored.planets.count == 2)   // UDKUDUA-7 scanned, UDKUDUA-4 seeded for its moon

        let planet = try #require(stored.planets.first { $0.designation == "UDKUDUA-7" })
        #expect(planet.recon == .scanned)
        #expect(planet.type == "Super Earth")
        #expect(planet.typeEstimated == false)
        #expect(planet.physical?.axialTiltDeg == 45.2)
        #expect(planet.physical?.rotationPeriodHours == 75)
        #expect(planet.moons.count == 2)

        let parent = try #require(stored.planets.first { $0.designation == "UDKUDUA-4" })
        let moon = try #require(parent.moons.first)
        #expect(moon.designation == "UDKUDUA-4-1")
        #expect(moon.recon == .scanned)
        #expect(moon.physical?.tidallyLocked == true)
        #expect(moon.physical?.orbitalPeriodHours == 599.03)
    }

    /// Absolute `resources_remaining` is the only source of a site's unit
    /// totals; with no known percentage it stands as a floor.
    @Test func writesSalvageAssaysFromAbsoluteAmounts() async throws {
        let database = try GameDatabase.bootstrap()
        _ = try await ingest(digest, into: database)

        let assay = try await database.read { db in
            try SiteAssay.where { $0.id.eq("UDKUDUA-4-1-SAL-1") }.fetchOne(db)
        }
        let row = try #require(assay)
        #expect(row.body == "UDKUDUA-4-1")
        #expect(row.system == "UDKUDUA")
        #expect(row.siteType == "salvage")
        #expect(row.totals == ["conductive": 214, "rares": 64])
    }

    /// With a percentage already known, remaining ÷ pct implies the original
    /// capacity — 214 units at 50% means the site started with 428.
    @Test func impliesTheOriginalTotalFromAKnownPercentage() async throws {
        let database = try GameDatabase.bootstrap()
        let cached = StarSystem(
            designation: "UDKUDUA",
            planets: [
                Planet(
                    designation: "UDKUDUA-4", recon: .visited,
                    moons: [
                        Moon(
                            designation: "UDKUDUA-4-1", recon: .visited,
                            salvage: [
                                SalvageSite(
                                    designation: "UDKUDUA-4-1-SAL-1",
                                    remainingPct: ["conductive": 50]
                                )
                            ]
                        )
                    ]
                )
            ]
        )
        let cachedRow = try SystemDetail(system: cached, hydratedAt: Date(timeIntervalSince1970: 1))
        try await database.write { db in
            try SystemDetail.upsert { cachedRow }.execute(db)
        }

        _ = try await ingest(digest, into: database)

        let assay = try await database.read { db in
            try SiteAssay.where { $0.id.eq("UDKUDUA-4-1-SAL-1") }.fetchOne(db)
        }
        #expect(try #require(assay).totals["conductive"] == 428)
    }

    /// The reason `BodyObservation` exists rather than a `BodyDetail`: a survey
    /// scan carries no devices, sites, or inventory, and merging one must not
    /// read that silence as "these are gone".
    @Test func doesNotEraseDetailTheScanNeverCarried() async throws {
        let database = try GameDatabase.bootstrap()
        let cached = StarSystem(
            designation: "UDKUDUA",
            planets: [
                Planet(
                    designation: "UDKUDUA-7", type: "Rocky", typeEstimated: true, recon: .visited,
                    sites: [ResourceSite(designation: "UDKUDUA-7-SITE-0", remaining: ["ferrous": 60])],
                    devices: [LocatedDevice(deviceCode: "ABCD1234", deviceType: "survey_drone")],
                    inventory: [InventoryItem(resourceType: "ferrous", quantity: 12)]
                )
            ]
        )
        let cachedRow = try SystemDetail(system: cached, hydratedAt: Date(timeIntervalSince1970: 1))
        try await database.write { db in
            try SystemDetail.upsert { cachedRow }.execute(db)
        }

        _ = try await ingest(digest, into: database)

        let stored = try #require(try await system("UDKUDUA", in: database))
        let planet = try #require(stored.planets.first { $0.designation == "UDKUDUA-7" })
        #expect(planet.sites.map(\.designation) == ["UDKUDUA-7-SITE-0"])
        #expect(planet.devices.map(\.deviceCode) == ["ABCD1234"])
        #expect(planet.inventory.map(\.resourceType) == ["ferrous"])
        // …and the scan's own contribution still landed.
        #expect(planet.type == "Super Earth")
        #expect(planet.recon == .scanned)
    }

    /// Events replay on launch catch-up, so the same digest arriving twice must
    /// settle to the same rows.
    @Test func isIdempotentAcrossAReplayedEvent() async throws {
        let database = try GameDatabase.bootstrap()
        _ = try await ingest(digest, into: database)
        let first = try #require(try await system("UDKUDUA", in: database))

        _ = try await ingest(digest, into: database, now: 2_000)
        let second = try #require(try await system("UDKUDUA", in: database))

        #expect(first == second)
        let assays = try await database.read { db in try SiteAssay.fetchAll(db) }
        #expect(assays.count == 1)
    }

    /// Digests arrive by the hundred per hour and almost none carry scans, so
    /// the common case must cost nothing.
    @Test func noOpsWhenTheDigestCarriesNoScans() async throws {
        let database = try GameDatabase.bootstrap()
        let counts = """
        { "directive": "survey_system",
          "activity": { "counts": { "travel.arrived": 3 }, "event_count": 3 },
          "report": { "busy": 6, "idle": 0, "progress": { "remaining": 9, "scanned": 0, "total": 9 } } }
        """
        #expect(try await ingest(counts, into: database) == 0)
        #expect(try await ingest("{ \"report\": { \"scans\": [] } }", into: database) == 0)

        let rows = try await database.read { db in try SystemDetail.fetchAll(db) }
        #expect(rows.isEmpty)
    }

    /// Drones in a digest can be spread across systems; each gets its own blob.
    @Test func groupsScansBySystem() async throws {
        let database = try GameDatabase.bootstrap()
        let multi = """
        { "report": { "scans": [
          { "scan_target": "UDKUDUA-7", "scan_type": "planet",
            "report": { "planet": { "designation": "UDKUDUA-7", "type": "Super Earth" } } },
          { "scan_target": "ATIANFU-2", "scan_type": "planet",
            "report": { "planet": { "designation": "ATIANFU-2", "type": "Gas Giant" } } }
        ] } }
        """
        #expect(try await ingest(multi, into: database) == 2)
        #expect(try await system("UDKUDUA", in: database)?.planets.first?.type == "Super Earth")
        #expect(try await system("ATIANFU", in: database)?.planets.first?.type == "Gas Giant")
    }
}
