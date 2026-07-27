//
//  SurveyOverlayTests.swift
//  NewStarMapFeature
//
//  The survey's second pass overlays per-replicant `explored` / `has_life` onto
//  the objective catalogue by walking the paged census. It used to stop at the
//  first page carrying no explored systems, assuming the distance-sorted listing
//  put them all up front. It does not: the sort is by *current* distance while
//  exploration is *history*, so a system the probe has since left sinks to
//  wherever its distance now puts it. On the live account explored systems sat on
//  pages 1–3, 12, 13, and 28 of 141 — page 4 was already empty, so the walk
//  stopped there and lost SOL (page 13, 39.5 ly out) along with three others.
//

import ComposableArchitecture
import Foundation
import GameDatabase
import GameModels
import GameServices
import SQLiteData
import Testing
import UniverseModels
@testable import NewStarMapFeature

// Free functions, not members: the suite is @MainActor (the module defaults to
// MainActor isolation), and these are called from the `@Sendable` client stubs.
private func item(_ designation: String, explored: Bool, hasLife: Bool? = nil) -> StarItem {
    StarItem(
        designation: designation, spectralType: "G2", color: "yellow-white",
        position: Position(x: 0, y: 0, z: 0), estimatedPlanets: 8,
        explored: explored, hasLife: hasLife, entryPoint: nil
    )
}

private func censusPage(_ stars: [StarItem], page: Int, totalPages: Int) -> StarPage {
    StarPage(
        stars: stars, page: page, perPage: 100, totalStars: 100 * totalPages,
        totalPages: totalPages, replicantPosition: Position(x: 0, y: 0, z: 0)
    )
}

@MainActor
@Suite struct SurveyOverlayTests {

    /// The regression: an explored system separated from the front of the listing
    /// by a page with none must still be recorded, and every page must be read.
    @Test func surveyWalksPastPagesWithNoExploredSystems() async throws {
        let database = try GameDatabase.bootstrap()
        let catalogue = [
            item("AINALRAM", explored: false), item("NEARBY", explored: false),
            item("EMPTY-A", explored: false), item("EMPTY-B", explored: false),
            item("SOL", explored: false),
        ]

        // Page 2 is empty of explored systems and page 3 holds SOL — the exact
        // shape that used to truncate the walk.
        let pages = [
            censusPage([item("AINALRAM", explored: true), item("NEARBY", explored: false)], page: 1, totalPages: 3),
            censusPage([item("EMPTY-A", explored: false), item("EMPTY-B", explored: false)], page: 2, totalPages: 3),
            censusPage([item("SOL", explored: true, hasLife: true)], page: 3, totalPages: 3),
        ]

        let store = TestStore(initialState: NewStarMapFeature.State()) {
            NewStarMapFeature()
        } withDependencies: {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.starsClient.catalogue = { catalogue }
            $0.starsClient.cooldownUntil = { nil }
            $0.starsClient.survey = { _, _ in
                AsyncThrowingStream { continuation in
                    for page in pages { continuation.yield(page) }
                    continuation.finish()
                }
            }
        }
        store.exhaustivity = .off

        store.state.$activeReplicantCode.withLock { $0 = "99380EDF" }
        await store.send(.surveyButtonTapped)
        await store.receive(\.catalogueLoaded)
        await store.receive(\.surveyFinished)
        await store.receive(\.surveyCooldownStarted)

        // Page 3's SOL is the proof the walk continued past the empty page 2.
        let explored = try await database.read { db in
            try UniverseModels.Star.where { $0.explored }.fetchAll(db).map(\.designation).sorted()
        }
        #expect(explored == ["AINALRAM", "SOL"])

        // The overlay carries `has_life` too, and it must survive the deep page.
        let sol = try await database.read { db in
            try UniverseModels.Star.where { $0.designation.eq("SOL") }.fetchOne(db)
        }
        #expect(try #require(sol).hasLife == true)
    }

    /// The catalogue pass must not clobber per-replicant knowledge: it carries no
    /// `explored` of its own, so re-running it leaves an already-explored row set.
    @Test func catalogueRefreshPreservesExploration() async throws {
        let database = try GameDatabase.bootstrap()
        let solOnly = [item("SOL", explored: false)]
        let exploredSol = censusPage([item("SOL", explored: true, hasLife: true)], page: 1, totalPages: 1)

        let store = TestStore(initialState: NewStarMapFeature.State()) {
            NewStarMapFeature()
        } withDependencies: {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.starsClient.catalogue = { solOnly }
            $0.starsClient.cooldownUntil = { nil }
            $0.starsClient.survey = { _, _ in
                AsyncThrowingStream { continuation in
                    continuation.yield(exploredSol)
                    continuation.finish()
                }
            }
        }
        store.exhaustivity = .off
        store.state.$activeReplicantCode.withLock { $0 = "99380EDF" }

        // Two full surveys back to back — the second one's catalogue write lands on
        // a row the first one's overlay already marked explored.
        for _ in 0..<2 {
            await store.send(.surveyButtonTapped)
            await store.receive(\.catalogueLoaded)
            await store.receive(\.surveyFinished)
            await store.receive(\.surveyCooldownStarted)
        }

        let sol = try await database.read { db in
            try UniverseModels.Star.where { $0.designation.eq("SOL") }.fetchOne(db)
        }
        #expect(try #require(sol).explored)
    }
}
