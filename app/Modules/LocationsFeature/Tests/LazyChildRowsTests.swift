//
//  LazyChildRowsTests.swift
//  LocationsFeature
//

import ComposableArchitecture
import Foundation
import GameDatabase
import SQLiteData
import Testing
import UniverseModels
@testable import LocationsFeature

@MainActor
@Suite struct LazyChildRowsTests {
    private func system(planets: [Planet]) -> StarSystem {
        StarSystem(
            designation: "SOL", systemScanned: true, planetsScanned: 1, planetsTotal: 1,
            belts: [Belt(designation: "SOL-BELT-1")],
            planets: planets
        )
    }

    private func store(
        _ system: StarSystem
    ) async throws -> (StoreOf<LocationsFeature>, any DatabaseWriter) {
        let database = try GameDatabase.bootstrap()
        let row = try SystemDetail(system: system, hydratedAt: .distantPast)
        try await database.write { db in
            try Star.upsert {
                Star(
                    designation: "SOL", spectralType: "G2", color: "white",
                    positionX: 0, positionY: 0, positionZ: 0, estimatedPlanets: 1,
                    explored: true, hasLife: nil, entryPoint: nil, createdAt: .distantPast
                )
            }
            .execute(db)
            try SystemDetail.upsert { row }.execute(db)
        }
        let store = withDependencies {
            $0.defaultDatabase = database
        } operation: {
            Store(initialState: LocationsFeature.State()) { LocationsFeature() }
        }
        return (store, database)
    }

    /// A collapsed system carries no children; expanding it builds them from the
    /// blob, and only then.
    @Test func expandingBuildsChildRowsFromTheBlob() async throws {
        let (store, database) = try await store(system(planets: [Planet(designation: "SOL-3", recon: .scanned)]))
        store.send(.activeReplicantChanged)
        try await Task.sleep(for: .milliseconds(200))

        #expect(store.childRows.isEmpty, "nothing is expanded, so no blob has been decoded")
        let sol = try #require(store.forest.nodes.first { $0.id == "SOL" })
        #expect(sol.hasChildren)
        #expect(sol.children == nil)

        store.send(.toggleExpansion("SOL"))
        #expect(store.childRows["SOL"]?.map(\.id) == ["SOL-BELT-1", "SOL-3"])

        let rows = LocationTree.flatten(
            store.forest.nodes, expanded: store.expanded, loaded: store.childRows
        )
        #expect(rows.map(\.id) == ["SOL", "SOL-BELT-1", "SOL-3"])
    }

    /// Collapsing keeps the built rows — re-expanding must not pay the decode a
    /// second time — and the flattened list drops them all the same.
    @Test func collapsingKeepsTheBuiltRowsButHidesThem() async throws {
        let (store, database) = try await store(system(planets: [Planet(designation: "SOL-3", recon: .scanned)]))
        store.send(.activeReplicantChanged)
        try await Task.sleep(for: .milliseconds(200))

        store.send(.toggleExpansion("SOL"))
        store.send(.toggleExpansion("SOL"))
        #expect(store.childRows["SOL"] != nil, "kept, so re-expanding is free")
        let rows = LocationTree.flatten(
            store.forest.nodes, expanded: store.expanded, loaded: store.childRows
        )
        #expect(rows.map(\.id) == ["SOL"])
    }

    /// A hydration write under an expanded system rebuilds its rows — otherwise
    /// the newly-scanned bodies never appear until it is collapsed and reopened.
    @Test func aHydrationRebuildsAnExpandedSystemsRows() async throws {
        let (store, database) = try await store(system(planets: [Planet(designation: "SOL-3", recon: .scanned)]))
        store.send(.activeReplicantChanged)
        try await Task.sleep(for: .milliseconds(200))
        store.send(.toggleExpansion("SOL"))
        #expect(store.childRows["SOL"]?.map(\.id) == ["SOL-BELT-1", "SOL-3"])

        let grown = try SystemDetail(
            system: system(planets: [
                Planet(designation: "SOL-3", recon: .scanned),
                Planet(designation: "SOL-4", recon: .scanned),
            ]),
            hydratedAt: Date(timeIntervalSince1970: 1)
        )
        try await database.write { db in try SystemDetail.upsert { grown }.execute(db) }
        try await Task.sleep(for: .milliseconds(200))

        store.send(.hydrated("SOL"))
        #expect(store.childRows["SOL"]?.map(\.id) == ["SOL-BELT-1", "SOL-3", "SOL-4"])
    }
}
