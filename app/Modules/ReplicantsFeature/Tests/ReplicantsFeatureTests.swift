//
//  ReplicantsFeatureTests.swift
//  Replicould — Replicants feature
//
//  The reducer owns intent — cold load / refresh and the on-demand details
//  fetch — and the directory/search derivation now lives in state, so it's
//  assertable here too. These pin the load lifecycle, the details spinner, error
//  handling, and that `sections` reflects the fetched rows + search text.
//
//  State holds `@FetchAll` queries, so every test runs inside a `withDependencies`
//  scope that provides an in-memory `defaultDatabase` (per SQLiteData's guidance).
//

import ComposableArchitecture
import Foundation
import GameModels
import GameServices
import SQLiteData
import Testing
@testable import ReplicantsFeature

private struct StubError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
@Suite struct ReplicantsFeatureTests {

    /// A refresh walks the directory and clears the loading flag on success.
    @Test func refreshLoadsDirectory() async throws {
        try await withDependencies {
            $0.defaultDatabase = try makeDatabase()
        } operation: {
            let store = TestStore(initialState: ReplicantsFeature.State()) {
                ReplicantsFeature()
            } withDependencies: {
                $0.replicantsClient.refresh = { 12 }
            }

            await store.send(.load) { $0.isLoading = true }
            await store.receive(\.loadSucceeded) { $0.isLoading = false }
        }
    }

    /// A failed refresh surfaces a banner and clears loading.
    @Test func refreshFailureSurfacesError() async throws {
        try await withDependencies {
            $0.defaultDatabase = try makeDatabase()
        } operation: {
            let store = TestStore(initialState: ReplicantsFeature.State()) {
                ReplicantsFeature()
            } withDependencies: {
                $0.replicantsClient.refresh = { throw StubError(message: "offline") }
            }

            await store.send(.load) { $0.isLoading = true }
            await store.receive(\.loadFailed) {
                $0.isLoading = false
                $0.errorMessage = "offline"
            }
        }
    }

    /// A second refresh while one is in flight is ignored (the guard short-circuits).
    @Test func refreshIgnoredWhileLoading() async throws {
        try await withDependencies {
            $0.defaultDatabase = try makeDatabase()
        } operation: {
            var loading = ReplicantsFeature.State()
            loading.isLoading = true
            let store = TestStore(initialState: loading) { ReplicantsFeature() }
            await store.send(.load)   // no state change, no effect
        }
    }

    /// Selecting a replicant fetches its details and shows/hides the spinner.
    @Test func detailsRequestedLoadsAndClearsSpinner() async throws {
        try await withDependencies {
            $0.defaultDatabase = try makeDatabase()
        } operation: {
            let loaded = LockIsolated<[String]>([])
            let store = TestStore(initialState: ReplicantsFeature.State()) {
                ReplicantsFeature()
            } withDependencies: {
                $0.replicantsClient.loadDetails = { code in loaded.withValue { $0.append(code) } }
            }

            await store.send(.detailsRequested(code: "99380EDF")) {
                $0.loadingDetailCode = "99380EDF"
            }
            await store.receive(\.detailsFinished) {
                $0.loadingDetailCode = nil
            }
            #expect(loaded.value == ["99380EDF"])
        }
    }

    /// Clearing the selection cancels any in-flight details fetch.
    @Test func detailsRequestedNilClearsSpinner() async throws {
        try await withDependencies {
            $0.defaultDatabase = try makeDatabase()
        } operation: {
            var initial = ReplicantsFeature.State()
            initial.loadingDetailCode = "ABC"
            let store = TestStore(initialState: initial) { ReplicantsFeature() }
            await store.send(.detailsRequested(code: nil)) {
                $0.loadingDetailCode = nil
            }
        }
    }

    /// A failed details fetch just stops the spinner; the row keeps prior intel.
    @Test func detailsFailureStopsSpinner() async throws {
        try await withDependencies {
            $0.defaultDatabase = try makeDatabase()
        } operation: {
            let store = TestStore(initialState: ReplicantsFeature.State()) {
                ReplicantsFeature()
            } withDependencies: {
                $0.replicantsClient.loadDetails = { _ in throw StubError(message: "boom") }
            }

            await store.send(.detailsRequested(code: "X")) { $0.loadingDetailCode = "X" }
            await store.receive(\.detailsFailed) { $0.loadingDetailCode = nil }
        }
    }

    /// `sections` is a pure, synchronous derivation of the fetched directory plus
    /// the search text: it groups Yours / Players / NPCs and filters by the query.
    /// Because the query lives in state, this is directly assertable — no view.
    @Test func sectionsDeriveFromDirectoryAndSearch() async throws {
        try await withDependencies {
            $0.defaultDatabase = try makeDatabase()
        } operation: {
            @Dependency(\.defaultDatabase) var database
            let now = Date(timeIntervalSince1970: 1_000)
            try await database.write { db in
                // The account owns OWN1; the others are a player and an NPC.
                try Replicant.upsert {
                    Replicant(replicantCode: "OWN1", name: "pennig-1", createdAt: now)
                }.execute(db)
                try KnownReplicant.upsert {
                    KnownReplicant(replicantCode: "OWN1", name: "pennig-1", isNPC: false, firstSeenAt: now, updatedAt: now)
                }.execute(db)
                try KnownReplicant.upsert {
                    KnownReplicant(replicantCode: "PLR2", name: "Zed", isNPC: false, firstSeenAt: now, updatedAt: now)
                }.execute(db)
                try KnownReplicant.upsert {
                    KnownReplicant(replicantCode: "NPC3", name: "Riker", isNPC: true, firstSeenAt: now, updatedAt: now)
                }.execute(db)
            }

            var state = ReplicantsFeature.State()
            // Force a synchronous fetch so the assertions see the seeded rows.
            try await state.$directory.load()
            try await state.$roster.load()

            #expect(state.sections.map(\.id) == ["Yours", "Players", "NPCs"])
            #expect(state.sections.first { $0.id == "Yours" }?.replicants.map(\.replicantCode) == ["OWN1"])
            #expect(state.sections.first { $0.id == "Players" }?.replicants.map(\.replicantCode) == ["PLR2"])

            // Searching narrows to matching rows across all groups.
            state.searchText = "riker"
            #expect(state.sections.map(\.id) == ["NPCs"])
            #expect(state.sections.first?.replicants.map(\.name) == ["Riker"])
        }
    }

    /// An in-memory database with the tables the directory list observes.
    private func makeDatabase() throws -> any DatabaseWriter {
        let database = try SQLiteData.defaultDatabase()
        var migrator = DatabaseMigrator()
        Replicant.registerMigrations(&migrator)
        KnownReplicant.registerMigrations(&migrator)
        try migrator.migrate(database)
        return database
    }
}
