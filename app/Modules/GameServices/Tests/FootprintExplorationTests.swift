//
//  FootprintExplorationTests.swift
//  GameServices
//
//  `GET /v1/locations` is a second, independent source of `Star.explored`.
//  The census walk that normally sets that flag is distance-sorted, so a system
//  explored long ago and since departed sinks deep into the listing and gets
//  missed — SOL sat on page 13 of 141 for a probe 39.5 ly out, leaving it
//  uncharted in the Locations catalog and unable to hydrate. Anything we hold at
//  a location proves we reached its system, so the footprint repairs those rows.
//

import Dependencies
import Foundation
import GameDatabase
import SQLiteData
import Testing
import UniverseModels
@testable import GameServices

@Suite struct FootprintExplorationTests {

    private func star(_ designation: String, explored: Bool) -> UniverseModels.Star {
        UniverseModels.Star(
            item: StarItem(
                designation: designation, spectralType: "G2", color: "yellow-white",
                position: Position(x: 0, y: 0, z: 0), estimatedPlanets: 8,
                explored: explored, hasLife: nil, entryPoint: nil
            ),
            createdAt: Date(timeIntervalSince1970: 0)
        )
    }

    private func seed(_ database: any DatabaseWriter, _ stars: [UniverseModels.Star]) throws {
        try database.write { db in
            try UniverseModels.Star.insert { stars }.execute(db)
        }
    }

    private func explored(_ database: any DatabaseWriter, _ designation: String) throws -> Bool {
        try database.read { db in
            try UniverseModels.Star.where { $0.designation.eq(designation) }.fetchOne(db)?.explored
        } ?? false
    }

    /// The bug, end to end: SOL is in the census but was never marked explored,
    /// and the only trace of it is a resource site at `SOL-BELT-1`. Refreshing the
    /// footprint must promote the *system* on the strength of that child location.
    @Test func footprintMarksTheSystemOfEveryHeldLocationExplored() async throws {
        let database = try GameDatabase.bootstrap()
        try seed(database, [star("SOL", explored: false), star("DABAH", explored: false)])

        var client = LocationsClient.testValue
        client.footprint = {
            [
                "SOL-BELT-1": LocationCounts(resourceSites: 1),
                "SOL-3-1": LocationCounts(devices: 2),
            ]
        }

        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
        } operation: {
            try await client.refreshFootprint()
        }

        #expect(try explored(database, "SOL"))
        // A system the footprint never names is left exactly as the census left it.
        #expect(try explored(database, "DABAH") == false)
    }

    /// The holdings overlay is not a knowledge index — a system we explored but
    /// hold nothing in is simply absent from it. Absence must never *clear* the
    /// flag, or every refresh would undo the census.
    @Test func footprintNeverClearsAnAlreadyExploredSystem() async throws {
        let database = try GameDatabase.bootstrap()
        try seed(database, [star("UNALEDI", explored: true)])

        var client = LocationsClient.testValue
        client.footprint = { ["SOL-BELT-1": LocationCounts(resourceSites: 1)] }

        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
        } operation: {
            try await client.refreshFootprint()
        }

        #expect(try explored(database, "UNALEDI"))
    }

    /// The holdings rows themselves still land — this call replaced the feature's
    /// own inline fetch-and-upsert, so the overlay must survive the move.
    @Test func footprintRowsArePersisted() async throws {
        let database = try GameDatabase.bootstrap()
        var client = LocationsClient.testValue
        client.footprint = { ["TENEGSHE-3": LocationCounts(locationEvents: 1, devices: 1, resources: 80)] }

        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
        } operation: {
            try await client.refreshFootprint()
        }

        let row = try await database.read { db in
            try LocationFootprint.where { $0.location.eq("TENEGSHE-3") }.fetchOne(db)
        }
        let footprint = try #require(row)
        #expect(footprint.devices == 1)
        #expect(footprint.resources == 80)
        #expect(footprint.locationEvents == 1)
        #expect(footprint.fetchedAt == Date(timeIntervalSince1970: 1_000))
    }

    /// A star the census has not charted yet simply has no row to update; the
    /// footprint write must not fail or invent one.
    @Test func footprintForAnUnchartedSystemIsHarmless() async throws {
        let database = try GameDatabase.bootstrap()
        var client = LocationsClient.testValue
        client.footprint = { ["NOWHERE-2": LocationCounts(devices: 1)] }

        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
        } operation: {
            try await client.refreshFootprint()
        }

        let count = try await database.read { db in
            try UniverseModels.Star.where { $0.designation.eq("NOWHERE-2") }.fetchCount(db)
        }
        #expect(count == 0)
    }

    // MARK: - The pure designation → system rule

    @Test func systemsAreDerivedFromEveryDepthOfLocationCode() {
        let systems = LocationFootprint.systems(in: [
            "SOL",           // bare system
            "SOL-3",         // planet
            "SOL-3-1",       // moon
            "SOL-BELT-1",    // belt
            "SOL-5-L4",      // Lagrange
            "TENEGSHE-5-31", // deep body
            "",              // junk
        ])
        #expect(systems == ["SOL", "TENEGSHE"])
    }
}
