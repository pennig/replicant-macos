//
//  CivilisationsFeatureTests.swift
//  Replicould — Civilisations feature
//
//  The reducer's job: cold-load the species catalog + account reputation on
//  first run, refresh reputation alone on later visits (it moves with
//  gameplay), and surface a cold-load failure. Plus the schema mappings —
//  species optionals coalesce (including the optional `star_regions`), and
//  reputation's wire `Double` becomes an `Int`.
//

import API
import ComposableArchitecture
import Foundation
import GameDatabase
import GameModels
import SQLiteData
import Testing
@testable import CivilisationsFeature

private struct LoadError: Error {}

@MainActor
@Suite struct CivilisationsFeatureTests {

    /// The species mapping coalesces every optional; `star_regions` is stored
    /// when present and coalesces to empty when the payload omits it.
    @Test func mappingCoalescesOptionalsAndStarRegions() {
        let bare = Civilisation(schema: Components.Schemas.AppSchemasSpeciesSpeciesSchema())
        #expect(bare.speciesKey == "")
        #expect(bare.name == "")
        #expect(bare.speciesDescription == "")
        #expect(bare.government == "")
        #expect(bare.greeting == "")
        #expect(bare.homeworldType == "")
        #expect(bare.techAffinity == "")
        #expect(bare.trait == "")
        #expect(bare.starRegions == [])
        #expect(bare.totalReputation == nil)

        let full = Civilisation(
            schema: Components.Schemas.AppSchemasSpeciesSpeciesSchema(
                speciesKey: "dzhekari",
                name: "Dzhekari",
                homeworldType: "ice_world",
                description: "Fungal colony organisms.",
                greeting: "Low-frequency vibration.",
                government: "The Consensus",
                trait: "collective",
                techAffinity: "energy",
                starRegions: ["alpha"]
            )
        )
        #expect(full.speciesKey == "dzhekari")
        #expect(full.starRegions == ["alpha"])
        // Reputation is never carried by the species payload.
        #expect(full.totalReputation == nil)

        // The reputation entry's wire `number` maps to a whole Int.
        let reputation = SpeciesReputation(
            schema: Components.Schemas.AppSchemasSpeciesAccountReputationEntrySchema(
                speciesKey: "humans",
                name: "Humans",
                trait: "curious",
                totalReputation: 10,
                description: "A resourceful and adaptable species."
            )
        )
        #expect(reputation.speciesKey == "humans")
        #expect(reputation.totalReputation == 10)
    }

    /// An empty catalog triggers a full cold-load on `.task`, persisting the
    /// species rows with the account's reputation merged in.
    @Test func emptyCatalogColdLoadsOnTask() async throws {
        let database = try GameDatabase.bootstrap()
        let store = TestStore(initialState: CivilisationsFeature.State()) {
            CivilisationsFeature()
        } withDependencies: {
            $0.defaultDatabase = database
            $0.civilisationsClient.fetchSpecies = { Civilisation.previewCatalog }
            $0.civilisationsClient.fetchReputation = {
                [SpeciesReputation(speciesKey: "humans", totalReputation: 10)]
            }
        }
        store.exhaustivity = .off

        await store.send(.task)
        await store.receive(\.load)
        await store.receive(\.loadSucceeded)

        let rows = try await database.read { db in try Civilisation.all.fetchAll(db) }
        #expect(rows.count == Civilisation.previewCatalog.count)
        #expect(rows.first { $0.speciesKey == "humans" }?.totalReputation == 10)
        // Species without a reputation entry stay unmet.
        #expect(rows.first { $0.speciesKey == "dzhekari" }?.totalReputation == nil)
    }

    /// A non-empty catalog skips the species fetch on `.task` and refreshes
    /// reputation alone.
    @Test func nonEmptyCatalogRefreshesReputationOnly() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Civilisation.insert { Civilisation.previewCatalog[0] }.execute(db)
        }

        let store = TestStore(initialState: CivilisationsFeature.State()) {
            CivilisationsFeature()
        } withDependencies: {
            $0.defaultDatabase = database
            $0.civilisationsClient.fetchSpecies = {
                Issue.record("should not re-fetch species"); return []
            }
            $0.civilisationsClient.fetchReputation = {
                [SpeciesReputation(speciesKey: Civilisation.previewCatalog[0].speciesKey, totalReputation: 42)]
            }
        }
        store.exhaustivity = .off

        await store.send(.task)
        await store.receive(\.refreshReputation)
        await store.receive(\.reputationRefreshed)

        let rows = try await database.read { db in try Civilisation.all.fetchAll(db) }
        #expect(rows.first?.totalReputation == 42)
    }

    /// A reputation refresh clears values missing from the payload (stale),
    /// applies the ones present, and ignores unknown species keys.
    @Test func reputationRefreshClearsStaleAndIgnoresUnknownKeys() async throws {
        let database = try GameDatabase.bootstrap()
        let met: Civilisation = {
            var civilisation = Civilisation.previewCatalog[0]
            civilisation.totalReputation = 50
            return civilisation
        }()
        let unmet = Civilisation.previewCatalog[1]
        try await database.write { db in
            try Civilisation.insert { [met, unmet] }.execute(db)
        }

        let store = TestStore(initialState: CivilisationsFeature.State()) {
            CivilisationsFeature()
        } withDependencies: {
            $0.defaultDatabase = database
            $0.civilisationsClient.fetchReputation = {
                [
                    SpeciesReputation(speciesKey: unmet.speciesKey, totalReputation: 7),
                    SpeciesReputation(speciesKey: "no_such_species", totalReputation: 99),
                ]
            }
        }
        store.exhaustivity = .off

        await store.send(.refreshReputation)
        await store.receive(\.reputationRefreshed)

        let rows = try await database.read { db in try Civilisation.all.fetchAll(db) }
        #expect(rows.first { $0.speciesKey == met.speciesKey }?.totalReputation == nil)
        #expect(rows.first { $0.speciesKey == unmet.speciesKey }?.totalReputation == 7)
        #expect(rows.count == 2)
    }

    /// A failed cold-load surfaces an error banner and clears the loading flag.
    @Test func loadFailureSurfacesError() async throws {
        let database = try GameDatabase.bootstrap()
        let store = TestStore(initialState: CivilisationsFeature.State()) {
            CivilisationsFeature()
        } withDependencies: {
            $0.defaultDatabase = database
            $0.civilisationsClient.fetchSpecies = { throw LoadError() }
            $0.civilisationsClient.fetchReputation = { [] }
        }
        store.exhaustivity = .off

        await store.send(.load)
        await store.receive(\.loadFailed)

        #expect(store.state.errorMessage != nil)
        #expect(store.state.isLoading == false)
    }

    /// Search reloads the query in SQL, narrowing across name, trait,
    /// government, and tech affinity.
    @Test func searchFilterNarrowsQuery() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Civilisation.insert { Civilisation.previewCatalog }.execute(db)
        }

        let store = TestStore(initialState: CivilisationsFeature.State()) {
            CivilisationsFeature()
        } withDependencies: {
            $0.defaultDatabase = database
        }
        store.exhaustivity = .off

        await store.send(.binding(.set(\.searchText, "Dzhekari")))
        await store.finish()

        #expect(store.state.civilisations.map(\.speciesKey) == ["dzhekari"])

        // A trait matches too.
        await store.send(.binding(.set(\.searchText, "curious")))
        await store.finish()

        #expect(store.state.civilisations.allSatisfy { $0.trait == "curious" })
        #expect(!store.state.civilisations.isEmpty)
    }
}
