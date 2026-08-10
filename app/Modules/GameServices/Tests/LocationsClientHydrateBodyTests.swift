//
//  LocationsClientHydrateBodyTests.swift
//  Replicould — GameServices
//
//  `hydrateBody`'s delist inference: the server DELISTS a drained salvage site
//  (no `depleted: true`), so a scanned detail's roster omitting an assayed site
//  is the only remaining evidence it's spent. Scope + scanned gates included.
//

import Dependencies
import Foundation
import GameDatabase
import GameModels
import SQLiteData
import Testing
import UniverseModels
@testable import GameServices

@Suite("LocationsClient.hydrateBody")
struct LocationsClientHydrateBodyTests {
    private static let now = Date(timeIntervalSince1970: 1_000)

    /// MEREDIANA-3 (scanned) hosting SAL-1, with moon MEREDIANA-3-1 hosting its
    /// own site — the cached blob a hydration folds into.
    private func cachedSystem() -> StarSystem {
        StarSystem(
            designation: "MEREDIANA",
            planets: [Planet(
                designation: "MEREDIANA-3", recon: .scanned,
                moons: [Moon(
                    designation: "MEREDIANA-3-1", recon: .scanned,
                    salvage: [SalvageSite(
                        designation: "MEREDIANA-3-1-SAL-1",
                        resourcesAvailable: ["rares"],
                        depleted: false
                    )]
                )],
                salvage: [SalvageSite(
                    designation: "MEREDIANA-3-SAL-1",
                    resourcesAvailable: ["structural"],
                    depleted: false
                )]
            )]
        )
    }

    private func assay(id: String, body: String) -> SiteAssay {
        SiteAssay(
            id: id, body: body, system: "MEREDIANA", siteType: "salvage",
            totals: ["structural": 510], assayedAt: Self.now, depleted: false
        )
    }

    private func seededDatabase(assays: [SiteAssay]) async throws -> any DatabaseWriter {
        let database = try GameDatabase.bootstrap()
        try await database.write { [system = cachedSystem()] db in
            let row = try SystemDetail(system: system, hydratedAt: Self.now)
            try SystemDetail.upsert { row }.execute(db)
            for assay in assays {
                try SiteAssay.upsert { assay }.execute(db)
            }
        }
        return database
    }

    private func hydrate(_ database: any DatabaseWriter, returning detail: BodyDetail) async throws {
        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Self.now)
            $0.locationsClient.body = { _ in detail }
        } operation: {
            @Dependency(\.locationsClient) var client
            try await client.hydrateBody(
                systemDesignation: "MEREDIANA", bodyDesignation: "MEREDIANA-3"
            )
        }
    }

    private func storedAssay(_ database: any DatabaseWriter, id: String) async throws -> SiteAssay? {
        try await database.read { db in
            try SiteAssay.where { $0.id.eq(id) }.fetchOne(db)
        }
    }

    /// A scanned detail whose roster kept a sibling but dropped SAL-1: the
    /// delisted site's assay flips depleted and the blob stops offering it.
    @Test func delistedSiteFlipsItsAssayDepleted() async throws {
        let database = try await seededDatabase(
            assays: [assay(id: "MEREDIANA-3-SAL-1", body: "MEREDIANA-3")]
        )
        try await hydrate(database, returning: .planet(Planet(
            designation: "MEREDIANA-3", recon: .scanned,
            salvage: [SalvageSite(
                designation: "MEREDIANA-3-SAL-2",
                resourcesAvailable: ["carbon"],
                depleted: false
            )]
        )))
        let stored = try await storedAssay(database, id: "MEREDIANA-3-SAL-1")
        #expect(stored?.depleted == true)

        let blob = try await database.read { db in
            try SystemDetail.where { $0.designation.eq("MEREDIANA") }.fetchOne(db)
        }
        let sites = try #require(try blob?.system()).knownSalvageSites.map(\.designation)
        #expect(!sites.contains("MEREDIANA-3-SAL-1"), "the fresh roster replaces the blob's")
        #expect(sites.contains("MEREDIANA-3-SAL-2"))
    }

    /// A scanned body whose roster came back EMPTY — every site drained and
    /// delisted (the MEREDIANA-3 incident shape) — depletes every assay on it.
    @Test func emptyScannedRosterDepletesEveryAssayOnTheBody() async throws {
        let database = try await seededDatabase(
            assays: [assay(id: "MEREDIANA-3-SAL-1", body: "MEREDIANA-3")]
        )
        try await hydrate(database, returning: .planet(Planet(
            designation: "MEREDIANA-3", recon: .scanned, salvage: []
        )))
        let stored = try await storedAssay(database, id: "MEREDIANA-3-SAL-1")
        #expect(stored?.depleted == true)
    }

    /// A site the fresh roster still lists is live: its assay stays untouched.
    @Test func presentSiteLeavesItsAssayAlone() async throws {
        let database = try await seededDatabase(
            assays: [assay(id: "MEREDIANA-3-SAL-1", body: "MEREDIANA-3")]
        )
        try await hydrate(database, returning: .planet(Planet(
            designation: "MEREDIANA-3", recon: .scanned,
            salvage: [SalvageSite(
                designation: "MEREDIANA-3-SAL-1",
                resourcesAvailable: ["structural"],
                depleted: false
            )]
        )))
        let stored = try await storedAssay(database, id: "MEREDIANA-3-SAL-1")
        #expect(stored?.depleted == false)
    }

    /// An UNSCANNED body's empty roster is ignorance, not depletion: no
    /// inference runs and the assay stays untouched.
    @Test func unscannedDetailInfersNothing() async throws {
        let database = try await seededDatabase(
            assays: [assay(id: "MEREDIANA-3-SAL-1", body: "MEREDIANA-3")]
        )
        try await hydrate(database, returning: .planet(Planet(
            designation: "MEREDIANA-3", recon: .visited, salvage: []
        )))
        let stored = try await storedAssay(database, id: "MEREDIANA-3-SAL-1")
        #expect(stored?.depleted == false)
    }

    /// An assay on a DIFFERENT body — the fetched planet's moon — is out of
    /// scope: the planet's roster says nothing about the moon's sites.
    @Test func moonAssayUntouchedByPlanetFetch() async throws {
        let database = try await seededDatabase(
            assays: [assay(id: "MEREDIANA-3-1-SAL-1", body: "MEREDIANA-3-1")]
        )
        try await hydrate(database, returning: .planet(Planet(
            designation: "MEREDIANA-3", recon: .scanned, salvage: []
        )))
        let stored = try await storedAssay(database, id: "MEREDIANA-3-1-SAL-1")
        #expect(stored?.depleted == false)
    }
}
