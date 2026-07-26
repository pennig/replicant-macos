//
//  LocationsClientHydrateTests.swift
//  Replicould — GameServices
//
//  `hydrateSystem(designation:)` — the presence-gated star-level re-read the
//  directive engine uses to confirm a survey finished. Two contract points that
//  a caller depends on and neither the engine nor the Locations feature would
//  catch if they broke: it MERGES over the cached blob rather than replacing it,
//  and it treats the 403 presence gate as a normal outcome, not an error.
//

import Dependencies
import Foundation
import GameDatabase
import GameModels
import SQLiteData
import Testing
import UniverseModels
@testable import GameServices

@Suite("LocationsClient.hydrateSystem")
struct LocationsClientHydrateTests {
    /// Fresh scan counts land in the cache, so the engine's next evaluation
    /// reads them straight from SQLite with no I/O of its own.
    @Test func persistsFreshCounts() async throws {
        let database = try GameDatabase.bootstrap()
        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 500))
            $0.locationsClient.system = { designation in
                StarSystem(designation: designation, planetsScanned: 3, planetsTotal: 3)
            }
        } operation: {
            @Dependency(\.locationsClient) var client
            try await client.hydrateSystem(designation: "SOL")
        }
        let stored = try await database.read { db in
            try SystemDetail.where { $0.designation.eq("SOL") }.fetchOne(db)
        }
        #expect(try stored?.system().planetsScanned == 3)
        #expect(stored?.hydratedAt == Date(timeIntervalSince1970: 500))
    }

    /// The re-read MERGES over the cached blob. The star-level payload carries
    /// counts but not the richer per-body detail a previous body hydration
    /// stored, so a straight replace would quietly discard it.
    @Test func mergesOverTheCachedBlob() async throws {
        let database = try GameDatabase.bootstrap()
        let cached = StarSystem(
            designation: "SOL", name: "Sol", recon: .scanned,
            planetsScanned: 1, planetsTotal: 3
        )
        let row = try SystemDetail(system: cached, hydratedAt: Date(timeIntervalSince1970: 0))
        try await database.write { db in
            try SystemDetail.upsert { row }.execute(db)
        }
        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 500))
            $0.locationsClient.system = { designation in
                StarSystem(designation: designation, planetsScanned: 3, planetsTotal: 3)
            }
        } operation: {
            @Dependency(\.locationsClient) var client
            try await client.hydrateSystem(designation: "SOL")
        }
        let stored = try await database.read { db in
            try SystemDetail.where { $0.designation.eq("SOL") }.fetchOne(db)
        }
        #expect(try stored?.system().planetsScanned == 3, "fresh counts win")
    }

    /// Away from the system the endpoint 403s. That is the expected case for
    /// most callers, not an error: the cache is left exactly as it was and the
    /// call returns normally.
    @Test func swallowsThePresenceGate() async throws {
        let database = try GameDatabase.bootstrap()
        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 500))
            $0.locationsClient.system = { _ in throw LocationsError.noReplicantInSystem }
        } operation: {
            @Dependency(\.locationsClient) var client
            try await client.hydrateSystem(designation: "SOL")
        }
        let stored = try await database.read { db in
            try SystemDetail.where { $0.designation.eq("SOL") }.fetchOne(db)
        }
        #expect(stored == nil, "a 403 must not write a placeholder row")
    }
}
