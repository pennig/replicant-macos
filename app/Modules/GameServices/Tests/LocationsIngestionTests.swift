//
//  LocationsIngestionTests.swift
//  Replicould — GameServices
//
//  The `locations.scan` route's glue — previously untestable in the app
//  target, now declared here beside the tested `LocationEventPolicy` it
//  applies. Covers the two behaviors the policy alone can't: the roster
//  update's provenance gate (only *live stream* arrivals move the roster;
//  catch-up replay must not walk it through stale waypoints), and the
//  passive-scan debounce (a burst collapses to one scan; logout teardown
//  cancels an armed scan).
//

import API
import ComposableArchitecture
import Foundation
import GameDatabase
import GameModels
import SQLiteData
import Testing
@testable import GameServices

@Suite struct LocationsIngestionTests {

    /// A host-vessel arrival at AINALRAM-BELT-1 (a system change for `replicant()`).
    private func arrival(provenance: GameEventEnvelope.Provenance) -> GameEventEnvelope {
        GameEventEnvelope(
            id: "1-0", category: "travel", event: "travel.arrived",
            replicantCode: "R1", deviceCode: "HOST",
            star: "AINALRAM", location: "AINALRAM-BELT-1",
            createdAt: "2026-07-21T09:00:00Z",
            provenance: provenance
        )
    }

    /// A replicant at ATIANFU-KUIPER hosted by vessel "HOST".
    private func replicant() -> Replicant {
        Replicant(
            replicantCode: "R1", name: "R", createdAt: Date(timeIntervalSince1970: 0),
            currentStar: "ATIANFU", currentStarName: "Atianfu",
            currentLocation: "ATIANFU-KUIPER", currentLocationName: "Kuiper",
            hostedDeviceCode: "HOST"
        )
    }

    /// A `LocationsClient` whose `scan` records each call and stops there
    /// (`scanAndPersist` calls `scan` first, so the throw skips only the
    /// persistence this test doesn't observe).
    private func countingLocationsClient(into scans: LockIsolated<[String]>) -> LocationsClient {
        LocationsClient(
            footprint: { [:] },
            system: { _ in throw LocationsError.notFound },
            body: { _ in throw LocationsError.notFound },
            scan: { code in
                scans.withValue { $0.append(code) }
                throw LocationsError.notFound
            }
        )
    }

    private func scanRoute(in ingestion: LocationsIngestion) throws -> EventRoute {
        try #require(ingestion.eventRoutes.first { $0.id == "locations.scan" })
    }

    @Test func streamArrivalMovesTheRosterAndClearsStaleNames() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { [replicant = replicant()] db in
            try Replicant.insert { replicant }.execute(db)
        }

        let ingestion = LocationsIngestion()
        let route = try scanRoute(in: ingestion)
        await withDependencies {
            $0.defaultDatabase = database
            $0.continuousClock = TestClock()   // hold the debounced scan; no client call
        } operation: {
            await route.apply(arrival(provenance: .stream))
        }
        ingestion.cancelPendingWork()

        let updated = try await database.read { db in try Replicant.fetchAll(db).first }
        #expect(updated?.currentStar == "AINALRAM")
        #expect(updated?.currentLocation == "AINALRAM-BELT-1")
        // A system change invalidates the old star's display name.
        #expect(updated?.currentStarName == nil)
        #expect(updated?.currentLocationName == nil)
    }

    @Test func catchUpArrivalLeavesTheRosterAlone() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { [replicant = replicant()] db in
            try Replicant.insert { replicant }.execute(db)
        }

        let ingestion = LocationsIngestion()
        let route = try scanRoute(in: ingestion)
        await withDependencies {
            $0.defaultDatabase = database
            $0.continuousClock = TestClock()
        } operation: {
            await route.apply(arrival(provenance: .catchUp))
        }
        ingestion.cancelPendingWork()

        // Replayed history must not walk the roster through stale waypoints —
        // the launch truth is `accounts/me`.
        let updated = try await database.read { db in try Replicant.fetchAll(db).first }
        #expect(updated?.currentStar == "ATIANFU")
        #expect(updated?.currentLocation == "ATIANFU-KUIPER")
        #expect(updated?.currentStarName == "Atianfu")
    }

    @Test func arrivalBurstCollapsesToOneDebouncedScan() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { [replicant = replicant()] db in
            try Replicant.insert { replicant }.execute(db)
        }

        let clock = TestClock()
        let scans = LockIsolated<[String]>([])
        let ingestion = LocationsIngestion()
        let route = try scanRoute(in: ingestion)

        await withDependencies {
            $0.defaultDatabase = database
            $0.continuousClock = clock
            $0.locationsClient = countingLocationsClient(into: scans)
        } operation: {
            // Two qualifying events in quick succession: the second re-arms the
            // debounce, so exactly one scan runs once the window elapses.
            await route.apply(arrival(provenance: .stream))
            await route.apply(arrival(provenance: .stream))
            await Task.megaYield()               // let the armed task reach its sleep
            #expect(scans.value.isEmpty)         // nothing runs inside the window
            await clock.advance(by: .seconds(2))
            await Task.megaYield()
        }

        #expect(scans.value == ["R1"])
    }

    @Test func cancelPendingWorkStopsAnArmedScan() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { [replicant = replicant()] db in
            try Replicant.insert { replicant }.execute(db)
        }

        let clock = TestClock()
        let scans = LockIsolated<[String]>([])
        let ingestion = LocationsIngestion()
        let route = try scanRoute(in: ingestion)

        await withDependencies {
            $0.defaultDatabase = database
            $0.continuousClock = clock
            $0.locationsClient = countingLocationsClient(into: scans)
        } operation: {
            await route.apply(arrival(provenance: .stream))
            await Task.megaYield()
            ingestion.cancelPendingWork()        // logout while the window is armed
            await clock.run()                    // drain: a cancelled sleep never fires
            await Task.megaYield()
        }

        #expect(scans.value.isEmpty)
    }
}
