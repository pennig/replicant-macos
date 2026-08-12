//
//  BlueprintsFeatureTests.swift
//  Replicould — Blueprints feature
//
//  The reducer's job: cold-load the unlocked catalog on first run (upserting
//  each blueprint into SQLite) and surface a load failure. Plus the schema
//  mapping, which must coalesce the sparse `resources` dict and the
//  hub-only `current_hubs`.
//

import API
import ComposableArchitecture
import Foundation
import GameDatabase
import GameModels
import GameServices
import SQLiteData
import Testing
@testable import BlueprintsFeature

private struct LoadError: Error {}

@MainActor
@Suite struct BlueprintsFeatureTests {

    /// An empty catalog triggers a cold-load on `.task`, persisting the rows.
    @Test func emptyCatalogColdLoadsOnTask() async throws {
        let database = try GameDatabase.bootstrap()
        let store = TestStore(initialState: BlueprintsFeature.State()) {
            BlueprintsFeature()
        } withDependencies: {
            $0.defaultDatabase = database
            $0.blueprintsClient.fetchAll = { Blueprint.previewCatalog }
        }
        store.exhaustivity = .off

        await store.send(.task)
        await store.receive(\.load)
        await store.receive(\.loadSucceeded)

        let count = try await database.read { db in try Blueprint.fetchCount(db) }
        #expect(count == Blueprint.previewCatalog.count)
    }

    /// A non-empty catalog does not cold-load on `.task`.
    @Test func nonEmptyCatalogSkipsColdLoad() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Blueprint.insert { Blueprint.previewCatalog[0] }.execute(db)
        }

        let store = TestStore(initialState: BlueprintsFeature.State()) {
            BlueprintsFeature()
        } withDependencies: {
            $0.defaultDatabase = database
            $0.blueprintsClient.fetchAll = { Issue.record("should not cold-load"); return [] }
        }
        store.exhaustivity = .off

        await store.send(.task)   // no .load follows
    }

    /// A failed fetch surfaces an error banner and clears the loading flag.
    @Test func loadFailureSurfacesError() async throws {
        let database = try GameDatabase.bootstrap()
        let store = TestStore(initialState: BlueprintsFeature.State()) {
            BlueprintsFeature()
        } withDependencies: {
            $0.defaultDatabase = database
            $0.blueprintsClient.fetchAll = { throw LoadError() }
        }
        store.exhaustivity = .off

        await store.send(.load)
        await store.receive(\.loadFailed)

        #expect(store.state.errorMessage != nil)
        #expect(store.state.isLoading == false)
    }

    /// The schema mapping coalesces the sparse `resources` dict to zeros and
    /// keeps `current_hubs` nil when the payload omits it.
    @Test func mappingCoalescesSparseResources() {
        let schema = Components.Schemas.AppSchemasBlueprintsBlueprintSchema(
            deviceType: "mining_drone",
            shortDescription: "short",
            description: "full",
            features: ["mine"],
            directives: [],
            printTime: 600,
            resources: .init(additionalProperties: ["carbon": 25, "structural": 100, "conductive": 50]),
            currentHubs: nil,
            stowCapacity: nil,
            cargoCapacity: nil,
            attachCapacity: nil,
            queueSize: nil,
            strength: nil
        )

        let blueprint = Blueprint(schema: schema)

        #expect(blueprint.deviceType == "mining_drone")
        #expect(blueprint.printTime == 600)
        #expect(blueprint.resources.carbon == 25)
        #expect(blueprint.resources.structural == 100)
        #expect(blueprint.resources.conductive == 50)
        // Omitted keys coalesce to 0.
        #expect(blueprint.resources.rares == 0)
        #expect(blueprint.resources.volatiles == 0)
        // Missing capacities and hubs coalesce to 0 / nil.
        #expect(blueprint.stowCapacity == 0)
        #expect(blueprint.currentHubs == nil)
        // Only non-zero resources become line items.
        #expect(blueprint.resources.lineItems.count == 3)
    }
}
