//
//  FullyScannedBackfillTests.swift
//  GameDatabaseTests
//
//  The backfill for `stars.fullyScannedAt`. Nothing ever wrote the column, so
//  every already-surveyed system was left unstamped — 31 of them on the live
//  database. Without the backfill the star map keeps showing them as partial and
//  the survey-target picker keeps offering them.
//
//  Applies the same planets-and-moons rule as `StarSystem.isFullyScanned`, in
//  SQL, over the stored blob.
//

import Foundation
import SQLiteData
import Testing
import UniverseModels

@testable import GameDatabase

@Suite("Fully-scanned backfill")
struct FullyScannedBackfillTests {
    private static let hydrated = Date(timeIntervalSince1970: 900_000)
    private static let backfillIdentifier = "Backfill 'fullyScannedAt' from systemDetails"

    private func star(_ designation: String) -> Star {
        Star(
            designation: designation, spectralType: "G", color: "yellow",
            positionX: 0, positionY: 0, positionZ: 0, estimatedPlanets: 3,
            explored: true, hasLife: nil, entryPoint: nil,
            createdAt: Date(timeIntervalSince1970: 0)
        )
    }

    /// Migrate only up to (not including) the backfill, seed rows as they would
    /// have existed before it, then let each test run the backfill itself.
    ///
    /// `GameDatabase.bootstrap()` takes no arguments and always migrates the
    /// whole manifest, which would run the backfill against an empty database.
    /// So this opens the connection the same way bootstrap does and drives
    /// `GameDatabase.migrator(_:)` — the parameter exists for exactly this.
    private func seeded() async throws -> any DatabaseWriter {
        let upToBackfill = GameDatabase.manifest.filter {
            $0.identifier != Self.backfillIdentifier
        }
        let database = try SQLiteData.defaultDatabase(configuration: GameDatabase.configuration)
        try GameDatabase.migrator(upToBackfill).migrate(database)
        try await database.write { db in
            for designation in ["DONE", "PLANETSHORT", "MOONSHORT", "NODETAIL"] {
                try Star.insert { self.star(designation) }.execute(db)
            }
            let systems = [
                StarSystem(
                    designation: "DONE", recon: .scanned, systemScanned: true,
                    planetsScanned: 6, planetsTotal: 6, moonsScanned: 14, moonsTotal: 14
                ),
                StarSystem(
                    designation: "PLANETSHORT", recon: .visited, systemScanned: true,
                    planetsScanned: 5, planetsTotal: 6
                ),
                StarSystem(
                    designation: "MOONSHORT", recon: .scanned, systemScanned: true,
                    planetsScanned: 6, planetsTotal: 6, moonsScanned: 11, moonsTotal: 14
                ),
            ]
            for system in systems {
                let row = try SystemDetail(system: system, hydratedAt: Self.hydrated)
                try SystemDetail.upsert { row }.execute(db)
            }
        }
        return database
    }

    private func stamp(_ database: any DatabaseWriter, _ designation: String) async throws -> Date? {
        try await database.read { db in
            try Star.where { $0.designation.eq(designation) }.fetchOne(db)?.fullyScannedAt
        }
    }

    @Test func stampsAFullyScannedSystemFromItsHydrationTime() async throws {
        let database = try await seeded()
        try GameDatabase.migrator().migrate(database)
        #expect(try await stamp(database, "DONE") == Self.hydrated)
    }

    @Test func leavesAPlanetShortSystemUnstamped() async throws {
        let database = try await seeded()
        try GameDatabase.migrator().migrate(database)
        #expect(try await stamp(database, "PLANETSHORT") == nil)
    }

    /// `recon` is "scanned" for this system (it is computed from planets alone),
    /// so a recon-column backfill would wrongly stamp it.
    @Test func leavesAMoonShortSystemUnstamped() async throws {
        let database = try await seeded()
        try GameDatabase.migrator().migrate(database)
        #expect(try await stamp(database, "MOONSHORT") == nil)
    }

    @Test func leavesACensusOnlySystemUnstamped() async throws {
        let database = try await seeded()
        try GameDatabase.migrator().migrate(database)
        #expect(try await stamp(database, "NODETAIL") == nil)
    }
}
