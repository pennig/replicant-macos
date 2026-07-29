//
//  SystemScanStateTests.swift
//  UniverseModelsTests
//
//  The one definition of "this system is completely surveyed". Its bias is
//  deliberate and load-bearing: unknown counts are never "scanned", because
//  re-surveying a done system costs one wasted trip while skipping an unscanned
//  one silently loses the point of the survey.
//

import Foundation
import GameDatabase
import SQLiteData
import Testing

@testable import UniverseModels

@Suite("System scan state")
struct SystemScanStateTests {
    private func system(
        planetsScanned: Int? = nil, planetsTotal: Int? = nil,
        moonsScanned: Int? = nil, moonsTotal: Int? = nil
    ) -> StarSystem {
        StarSystem(
            designation: "SOL",
            planetsScanned: planetsScanned, planetsTotal: planetsTotal,
            moonsScanned: moonsScanned, moonsTotal: moonsTotal
        )
    }

    @Test func everyPlanetScannedAndNoMoonsReportedIsFull() {
        #expect(system(planetsScanned: 6, planetsTotal: 6).isFullyScanned)
    }

    @Test func everyPlanetAndEveryMoonScannedIsFull() {
        #expect(
            system(planetsScanned: 6, planetsTotal: 6, moonsScanned: 14, moonsTotal: 14)
                .isFullyScanned
        )
    }

    @Test func planetsShortIsNotFull() {
        #expect(!system(planetsScanned: 5, planetsTotal: 6).isFullyScanned)
    }

    /// The case a `recon`-column shortcut gets wrong: `recon == .scanned` is
    /// computed from planets alone, so a system with every planet but not every
    /// moon reads as scanned there while still being real survey work.
    @Test func moonsShortIsNotFull() {
        #expect(
            !system(planetsScanned: 6, planetsTotal: 6, moonsScanned: 11, moonsTotal: 14)
                .isFullyScanned
        )
    }

    @Test func unknownMoonsScannedAgainstAKnownTotalIsNotFull() {
        #expect(
            !system(planetsScanned: 6, planetsTotal: 6, moonsScanned: nil, moonsTotal: 14)
                .isFullyScanned
        )
    }

    @Test func unknownCountsAreNeverFull() {
        #expect(!system().isFullyScanned)
        #expect(!system(planetsScanned: nil, planetsTotal: 6).isFullyScanned)
    }

    @Test func zeroPlanetTotalIsNeverFull() {
        #expect(!system(planetsScanned: 0, planetsTotal: 0).isFullyScanned)
    }

    /// A moon total of zero is "no moons to scan", not an unmet requirement.
    @Test func zeroMoonTotalDoesNotBlockFullness() {
        #expect(
            system(planetsScanned: 6, planetsTotal: 6, moonsScanned: 0, moonsTotal: 0)
                .isFullyScanned
        )
    }
}

@Suite("System detail persistence")
struct SystemDetailPersistenceTests {
    private static let now = Date(timeIntervalSince1970: 1_000_000)

    /// A census row for `designation`, unstamped.
    private func star(_ designation: String) -> Star {
        Star(
            designation: designation, spectralType: "G", color: "yellow",
            positionX: 0, positionY: 0, positionZ: 0, estimatedPlanets: 3,
            explored: true, hasLife: nil, entryPoint: nil,
            createdAt: Date(timeIntervalSince1970: 0)
        )
    }

    private func complete(_ designation: String) -> StarSystem {
        StarSystem(
            designation: designation, recon: .scanned, systemScanned: true,
            planetsScanned: 6, planetsTotal: 6, moonsScanned: 14, moonsTotal: 14
        )
    }

    @Test func stampsTheCensusRowWhenTheSystemBecomesComplete() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Star.insert { self.star("SOL") }.execute(db)
            try SystemDetail.persist(system: self.complete("SOL"), at: Self.now, in: db)
        }
        let stored = try await database.read { db in
            try Star.where { $0.designation.eq("SOL") }.fetchOne(db)
        }
        #expect(stored?.fullyScannedAt == Self.now)
    }

    @Test func persistsTheBlobRegardlessOfCompleteness() async throws {
        let database = try GameDatabase.bootstrap()
        let partial = StarSystem(
            designation: "SOL", recon: .visited, systemScanned: true,
            planetsScanned: 2, planetsTotal: 6
        )
        try await database.write { db in
            try Star.insert { self.star("SOL") }.execute(db)
            try SystemDetail.persist(system: partial, at: Self.now, in: db)
        }
        let stored = try await database.read { db in
            try SystemDetail.where { $0.designation.eq("SOL") }.fetchOne(db)
        }
        #expect(stored != nil)
        #expect(try stored?.system().planetsScanned == 2)
    }

    @Test func doesNotStampWhenPlanetsFallShort() async throws {
        let database = try GameDatabase.bootstrap()
        let partial = StarSystem(
            designation: "SOL", recon: .visited, systemScanned: true,
            planetsScanned: 5, planetsTotal: 6
        )
        try await database.write { db in
            try Star.insert { self.star("SOL") }.execute(db)
            try SystemDetail.persist(system: partial, at: Self.now, in: db)
        }
        let stored = try await database.read { db in
            try Star.where { $0.designation.eq("SOL") }.fetchOne(db)
        }
        #expect(stored?.fullyScannedAt == nil)
    }

    /// The case a `recon`-column shortcut gets wrong. `recon` is computed from
    /// planets alone, so this system reads as `.scanned` there — but its moons
    /// are unfinished and it is still real survey work.
    @Test func doesNotStampWhenMoonsFallShort() async throws {
        let database = try GameDatabase.bootstrap()
        let moonShort = StarSystem(
            designation: "SOL", recon: .scanned, systemScanned: true,
            planetsScanned: 6, planetsTotal: 6, moonsScanned: 11, moonsTotal: 14
        )
        try await database.write { db in
            try Star.insert { self.star("SOL") }.execute(db)
            try SystemDetail.persist(system: moonShort, at: Self.now, in: db)
        }
        let stored = try await database.read { db in
            try Star.where { $0.designation.eq("SOL") }.fetchOne(db)
        }
        #expect(stored?.fullyScannedAt == nil)
    }

    /// Write-once. The column is named for an event, and moon totals get revised
    /// (`moonsTotalEstimated`), so a later re-persist must not move the stamp.
    @Test func doesNotOverwriteAnExistingStamp() async throws {
        let database = try GameDatabase.bootstrap()
        let first = Date(timeIntervalSince1970: 500_000)
        try await database.write { db in
            try Star.insert { self.star("SOL") }.execute(db)
            try SystemDetail.persist(system: self.complete("SOL"), at: first, in: db)
            try SystemDetail.persist(system: self.complete("SOL"), at: Self.now, in: db)
        }
        let stored = try await database.read { db in
            try Star.where { $0.designation.eq("SOL") }.fetchOne(db)
        }
        #expect(stored?.fullyScannedAt == first)
    }

    /// A single body's scan seeds a minimal system with no planet totals. That
    /// can never imply the whole system is done.
    @Test func doesNotStampASeededMinimalSystem() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Star.insert { self.star("SOL") }.execute(db)
            try SystemDetail.persist(
                system: StarSystem(designation: "SOL", recon: .visited),
                at: Self.now, in: db
            )
        }
        let stored = try await database.read { db in
            try Star.where { $0.designation.eq("SOL") }.fetchOne(db)
        }
        #expect(stored?.fullyScannedAt == nil)
    }

    /// No census row to stamp is not an error — the blob still persists.
    @Test func persistsTheBlobWhenNoCensusRowExists() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try SystemDetail.persist(system: self.complete("NOSTAR"), at: Self.now, in: db)
        }
        let detail = try await database.read { db in
            try SystemDetail.where { $0.designation.eq("NOSTAR") }.fetchOne(db)
        }
        #expect(detail != nil)
    }
}
