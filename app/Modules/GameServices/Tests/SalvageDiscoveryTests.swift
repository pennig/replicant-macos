//
//  SalvageDiscoveryTests.swift
//  GameServices
//
//  `salvage.discovered` is the only source of a site's original resource
//  totals, so recording it does two things: write the durable assay, and fold
//  the site into the catalog so a discovery is visible without waiting for the
//  next scan.
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

@Suite struct SalvageDiscoveryTests {
    private func payload(_ json: String) throws -> [String: JSONValue] {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        guard case .object(let object) = value else {
            Issue.record("expected an object"); return [:]
        }
        return object
    }

    private var livePayload: String {
        """
        { "salvage_type": "derelict_probe",
          "resources": { "conductive": 331, "rares": 99, "silicates": 248 },
          "designation": "TAANSI-6-SAL-1", "location": "TAANSI-6",
          "name": "Derelict Survey Probe" }
        """
    }

    @Test func discoveryWritesTheAssay() async throws {
        let database = try GameDatabase.bootstrap()
        let p = try payload(livePayload)

        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
        } operation: {
            _ = try await LocationsClient.liveValue.recordSalvageDiscovery(payload: p)
        }

        let assay = try await database.read { db in
            try SiteAssay.where { $0.id.eq("TAANSI-6-SAL-1") }.fetchOne(db)
        }
        let row = try #require(assay)
        #expect(row.body == "TAANSI-6")
        #expect(row.system == "TAANSI")
        #expect(row.siteType == "salvage")
        #expect(row.totals == ["conductive": 331, "rares": 99, "silicates": 248])
    }

    /// Events replay on catch-up, so a second delivery must be a no-op — and
    /// must never lower a total already raised by a later observation.
    @Test func discoveryIsIdempotentAndNeverLowersTotals() async throws {
        let database = try GameDatabase.bootstrap()
        let p = try payload(livePayload)

        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
        } operation: {
            _ = try await LocationsClient.liveValue.recordSalvageDiscovery(payload: p)
            // A larger total observed in between (as scan ingestion would write).
            try await database.write { db in
                try SiteAssay.where { $0.id.eq("TAANSI-6-SAL-1") }
                    .update { $0.totals = #bind(["conductive": 500.0]) }
                    .execute(db)
            }
            _ = try await LocationsClient.liveValue.recordSalvageDiscovery(payload: p)
        }

        let assay = try await database.read { db in
            try SiteAssay.where { $0.id.eq("TAANSI-6-SAL-1") }.fetchOne(db)
        }
        #expect(try #require(assay).totals["conductive"] == 500)
        let count = try await database.read { db in try SiteAssay.all.fetchCount(db) }
        #expect(count == 1)
    }

    /// The discovery is folded into the catalog so it shows up immediately,
    /// even when the system has never been hydrated.
    @Test func discoverySeedsTheCatalogWhenTheSystemIsUncached() async throws {
        let database = try GameDatabase.bootstrap()
        let p = try payload(livePayload)

        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
        } operation: {
            _ = try await LocationsClient.liveValue.recordSalvageDiscovery(payload: p)
        }

        let detail = try await database.read { db in
            try SystemDetail.where { $0.designation.eq("TAANSI") }.fetchOne(db)
        }
        let system = try #require(detail).system()
        let site = try #require(system.knownSalvageSites.first { $0.designation == "TAANSI-6-SAL-1" })
        #expect(site.name == "Derelict Survey Probe")
        #expect(site.salvageType == "derelict_probe")
        #expect(site.resourcesAvailable == ["conductive", "rares", "silicates"])
        // Percentages are NOT synthesised — they are observed data, and the
        // site reads as discovered totals until the first hydrate supplies them.
        #expect(site.remainingPct.isEmpty)
    }

    /// The bug this whole targeting change exists for, at the level it actually
    /// occurs: an envelope whose `location` is the survey controller's parking
    /// spot must not be mistaken for the body holding the salvage.
    @Test func theRouteTargetsThePayloadBodyNotTheEnvelopeLocation() async throws {
        let database = try GameDatabase.bootstrap()
        let ingestion = LocationsIngestion()
        let route = try #require(ingestion.eventRoutes.first { $0.id == "locations.catalog" })
        let envelope = GameEventEnvelope(
            id: "1784995249445-0",
            category: "salvage",
            event: "salvage.discovered",
            deviceCode: "B2CBDEC6",
            deviceType: "ami_survey_controller",
            star: "TAANSI",
            location: "TAANSI-5-L4",          // the CONTROLLER's location
            payload: try payload(livePayload)  // the SITE is on TAANSI-6
        )

        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.locationsClient = .liveValue
        } operation: {
            await route.apply(envelope)
        }

        let assay = try await database.read { db in
            try SiteAssay.where { $0.id.eq("TAANSI-6-SAL-1") }.fetchOne(db)
        }
        #expect(try #require(assay).body == "TAANSI-6")
        #expect(try #require(assay).system == "TAANSI")
    }

    @Test func aPayloadWithoutADesignationIsANoOp() async throws {
        let database = try GameDatabase.bootstrap()
        let p = try payload(#"{ "resources": { "carbon": 10 } }"#)

        let wrote = try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
        } operation: {
            try await LocationsClient.liveValue.recordSalvageDiscovery(payload: p)
        }
        #expect(wrote == false)
        let count = try await database.read { db in try SiteAssay.all.fetchCount(db) }
        #expect(count == 0)
    }
}
