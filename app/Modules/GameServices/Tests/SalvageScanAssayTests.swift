//
//  SalvageScanAssayTests.swift
//  GameServices
//
//  scan.completed carries absolute `resources_remaining` per salvage site. That
//  is a second, self-refreshing source of capacity: combined with the site's
//  known percentage it implies the original total, which keeps assays correct
//  when a discovery event is missed.
//

import API
import Dependencies
import Foundation
import GameDatabase
import SQLiteData
import Testing
import UniverseModels
import Utils
@testable import GameServices

@Suite struct SalvageScanAssayTests {
    private func payload(_ json: String) throws -> [String: JSONValue] {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        guard case .object(let object) = value else {
            Issue.record("expected an object"); return [:]
        }
        return object
    }

    /// A real `scan.completed` result block (moon scan).
    private var scanPayload: String {
        """
        { "result": { "moon": {
            "designation": "SHERATANON-6-26", "type": "Rocky",
            "salvage": [
              { "designation": "SHERATANON-6-26-SAL-1", "salvage_type": "crashed_vessel",
                "name": "Crashed Vessel", "location": "SHERATANON-6-26",
                "resources_remaining": { "structural": 339, "conductive": 226 },
                "depleted": false }
            ] } } }
        """
    }

    /// With no percentage known, the absolute remaining is a floor on capacity.
    @Test func scanSeedsAnAssayFromAbsoluteRemaining() async throws {
        let database = try GameDatabase.bootstrap()
        let p = try payload(scanPayload)

        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
        } operation: {
            _ = try await LocationsClient.liveValue.ingestScanResult(payload: p)
        }

        let assay = try await database.read { db in
            try SiteAssay.where { $0.id.eq("SHERATANON-6-26-SAL-1") }.fetchOne(db)
        }
        let row = try #require(assay)
        #expect(row.body == "SHERATANON-6-26")
        #expect(row.system == "SHERATANON")
        #expect(row.totals == ["structural": 339, "conductive": 226])
    }

    /// With a percentage known, remaining ÷ pct implies the original capacity —
    /// 339 units at 30% means the site started with 1130.
    @Test func scanImpliesTheOriginalTotalFromAKnownPercentage() async throws {
        let database = try GameDatabase.bootstrap()
        let p = try payload(scanPayload)

        let moon = Moon(
            designation: "SHERATANON-6-26",
            salvage: [
                SalvageSite(
                    designation: "SHERATANON-6-26-SAL-1", location: "SHERATANON-6-26",
                    resourcesAvailable: ["structural", "conductive"],
                    remainingPct: ["structural": 30, "conductive": 100]
                )
            ]
        )
        let system = StarSystem(
            designation: "SHERATANON", recon: .visited,
            planets: [Planet(designation: "SHERATANON-6", moons: [moon])]
        )

        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
        } operation: {
            try await database.write { db in
                let row = try SystemDetail(system: system, hydratedAt: Date(timeIntervalSince1970: 0))
                try SystemDetail.upsert { row }.execute(db)
            }
            _ = try await LocationsClient.liveValue.ingestScanResult(payload: p)
        }

        let assay = try await database.read { db in
            try SiteAssay.where { $0.id.eq("SHERATANON-6-26-SAL-1") }.fetchOne(db)
        }
        let totals = try #require(assay).totals
        #expect(totals["structural"] == 1130)
        #expect(totals["conductive"] == 226)
    }

    /// A scan must not destroy the percentages it just used. `applying(_:)`
    /// replaces the body's salvage wholesale from a payload that carries no
    /// `resources_remaining_pct`, so without the restore the inspector drops
    /// back to a bare name list, `salvageBodies` loses its units, and the NEXT
    /// scan finds no percentage and degrades to a raw floor — the self-correction
    /// decaying with every scan.
    @Test func scanKeepsTheCachedPercentagesItMergedOver() async throws {
        let database = try GameDatabase.bootstrap()
        let p = try payload(scanPayload)

        let moon = Moon(
            designation: "SHERATANON-6-26",
            salvage: [
                SalvageSite(
                    designation: "SHERATANON-6-26-SAL-1", location: "SHERATANON-6-26",
                    resourcesAvailable: ["structural", "conductive"],
                    remainingPct: ["structural": 30, "conductive": 100]
                )
            ]
        )
        let system = StarSystem(
            designation: "SHERATANON", recon: .visited,
            planets: [Planet(designation: "SHERATANON-6", moons: [moon])]
        )

        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
        } operation: {
            try await database.write { db in
                let row = try SystemDetail(system: system, hydratedAt: Date(timeIntervalSince1970: 0))
                try SystemDetail.upsert { row }.execute(db)
            }
            _ = try await LocationsClient.liveValue.ingestScanResult(payload: p)
        }

        let merged = try await database.read { db in
            try SystemDetail.where { $0.designation.eq("SHERATANON") }.fetchOne(db)
        }
        let cached = try #require(merged).system()
        let site = try #require(cached.knownSalvageSites.first { $0.designation == "SHERATANON-6-26-SAL-1" })
        #expect(site.remainingPct == ["structural": 30, "conductive": 100])
        // The scan's own fresher fields still landed.
        #expect(site.name == "Crashed Vessel")
        #expect(site.salvageType == "crashed_vessel")
        // And the surfaces that read through those percentages still work.
        let bodies = cached.salvageBodies(totals: ["SHERATANON-6-26-SAL-1": ["structural": 1130]])
        #expect(bodies.first?.unitsRemaining == 339)   // 1130 × 30%
    }

    /// A scan of a site with no salvage must not create empty assay rows.
    @Test func aScanWithoutSalvageWritesNoAssay() async throws {
        let database = try GameDatabase.bootstrap()
        let p = try payload("""
        { "result": { "moon": { "designation": "SHERATANON-6-27", "type": "Rocky" } } }
        """)

        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
        } operation: {
            _ = try await LocationsClient.liveValue.ingestScanResult(payload: p)
        }

        let count = try await database.read { db in try SiteAssay.all.fetchCount(db) }
        #expect(count == 0)
    }
}
