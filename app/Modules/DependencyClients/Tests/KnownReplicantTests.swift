//
//  KnownReplicantTests.swift
//  Replicould — DependencyClients
//
//  `KnownReplicant` folds three sources into one record — the directory, the
//  details endpoint, and scan sightings — preserving richer intel rather than
//  clobbering it. These pin the merge precedence (scan/details location wins over
//  the directory's coarse `last_location`), the scan-block parsing that feeds
//  player-replicant tracking, and the persistence merge helpers.
//

import API
import Foundation
import SQLiteData
import Testing
import Utils
@testable import DependencyClients

@Suite struct KnownReplicantTests {

    private let now = Date(timeIntervalSince1970: 1_000)

    // MARK: Scan sighting parsing

    /// The real `replicants` block from a `system_scan` response.
    private var scanResponse: JSONValue {
        .object([
            "replicants": .array([
                .object([
                    "replicant_code": .string("99380EDF"),
                    "last_active": .string("2026-07-02T08:43:24-05:00"),
                    "location": .string("ATIANFU-BELT-1"),
                    "name": .string("pennig-1"),
                ]),
                // An entry missing a location is skipped — nothing to record.
                .object(["replicant_code": .string("BADCODE0"), "name": .string("ghost")]),
            ]),
        ])
    }

    @Test func parsesScanSightingsSkippingIncomplete() throws {
        let sightings = KnownReplicant.scanSightings(from: scanResponse)
        #expect(sightings.count == 1)
        let s = try #require(sightings.first)
        #expect(s.code == "99380EDF")
        #expect(s.location == "ATIANFU-BELT-1")
        #expect(s.name == "pennig-1")
        #expect(s.lastActive == (try Date("2026-07-02T13:43:24Z", strategy: .iso8601)))
    }

    @Test func scanSightingsEmptyWhenNoBlock() {
        #expect(KnownReplicant.scanSightings(from: .object([:])).isEmpty)
        #expect(KnownReplicant.scanSightings(from: nil).isEmpty)
    }

    // MARK: Merge precedence

    @Test func directoryMergeSetsCoarseLocationButKeepsPreciseIntel() {
        // A record that already has a precise scan location…
        var record = KnownReplicant.fresh(code: "P1", now: now)
        record.lastKnownLocation = "ATIANFU-BELT-1"
        record.lastKnownLocationName = "Belt"

        let item = Components.Schemas.AppSchemasReplicantsReplicantSearchItemSchema(
            replicantCode: "P1", name: "Neo", isNpc: false, lastLocation: "SOL"
        )
        let merged = record.merging(directoryItem: item, now: now)

        #expect(merged.name == "Neo")
        #expect(merged.directoryLocation == "SOL")
        // Precise intel is preserved and still preferred for display.
        #expect(merged.lastKnownLocation == "ATIANFU-BELT-1")
        #expect(merged.displayLocationLabel == "Belt")
    }

    @Test func sightingMergeUpdatesPreciseLocationAndTime() throws {
        let record = KnownReplicant.fresh(code: "P1", now: now)
        let seen = try Date("2026-07-02T13:43:24Z", strategy: .iso8601)
        let merged = record.merging(
            sighting: ScanSighting(code: "P1", name: "Neo", location: "ATIANFU-1", lastActive: seen),
            now: now
        )
        #expect(merged.lastKnownLocation == "ATIANFU-1")
        #expect(merged.lastSeenAt == seen)
        #expect(merged.name == "Neo")
        #expect(merged.displayLocation == "ATIANFU-1")
    }

    @Test func detailsMergeSetsAuthoritativeLocationAndStats() {
        let record = KnownReplicant.fresh(code: "P1", now: now)
        let schema = Components.Schemas.AppSchemasReplicantsReplicantStatusSchema(
            replicantCode: "P1", name: "Neo", isNpc: false,
            hostedDeviceCode: "965AC2C3", status: "stationary",
            experiencePoints: 1124, location: "ATIANFU-BELT-1", locationName: "The Belt"
        )
        let blob = JSONValue.object(["plan": .string("Explore")])
        let merged = record.merging(details: schema, blob: blob, now: now)

        #expect(merged.status == "stationary")
        #expect(merged.experiencePoints == 1124)
        #expect(merged.hostedDeviceCode == "965AC2C3")
        #expect(merged.lastKnownLocation == "ATIANFU-BELT-1")
        #expect(merged.lastKnownLocationName == "The Belt")
        #expect(merged.plan == "Explore")
        #expect(merged.detailFetchedAt == now)
    }

    // MARK: Persistence merge (fetch-merge-upsert survives across sources)

    @Test func scanThenDirectoryPreservesScanLocation() async throws {
        let database = try makeDatabase()

        // A scan records a precise sighting first…
        try await database.write { db in
            try KnownReplicant.record(
                sightings: [ScanSighting(code: "P1", name: "Neo", location: "ATIANFU-BELT-1", lastActive: now)],
                into: db, now: now
            )
        }
        // …then the directory reports only a coarse location.
        try await database.write { db in
            try KnownReplicant.upsert(
                directory: [.init(replicantCode: "P1", name: "Neo", isNpc: false, lastLocation: "SOL")],
                into: db, now: now
            )
        }

        let row = try await database.read { db in
            try KnownReplicant.where { $0.replicantCode.eq("P1") }.fetchOne(db)
        }
        #expect(row?.lastKnownLocation == "ATIANFU-BELT-1")   // scan intel survived
        #expect(row?.directoryLocation == "SOL")
        #expect(row?.displayLocation == "ATIANFU-BELT-1")     // precise still wins
    }

    @Test func rosterSeedMarksOwnAndLocation() async throws {
        let database = try makeDatabase()
        let roster = Replicant(
            replicantCode: "P1", name: "pennig-1", createdAt: now,
            currentLocation: "ATIANFU-BELT-1", currentLocationName: "The Belt",
            hostedDeviceCode: "965AC2C3", experiencePoints: 1124
        )
        try await database.write { db in
            try KnownReplicant.upsert(roster: [roster], into: db, now: now)
        }
        let row = try await database.read { db in
            try KnownReplicant.where { $0.replicantCode.eq("P1") }.fetchOne(db)
        }
        #expect(row?.isNPC == false)
        #expect(row?.experiencePoints == 1124)
        #expect(row?.lastKnownLocation == "ATIANFU-BELT-1")
    }

    private func makeDatabase() throws -> any DatabaseWriter {
        let database = try SQLiteData.defaultDatabase()
        var migrator = DatabaseMigrator()
        KnownReplicant.registerMigrations(&migrator)
        try migrator.migrate(database)
        return database
    }
}
