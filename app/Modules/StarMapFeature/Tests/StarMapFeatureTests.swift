import ComposableArchitecture
import DependencyClients
import Foundation
import SQLiteData
import Testing
import UniverseModels
@testable import StarMapFeature

@Suite struct GalaxyDataTests {
    @Test func seedsSixteenSystemsAndFiveRelays() {
        #expect(GalaxyData.systems.count == 16)
        #expect(GalaxyData.relays.count == 5)
    }

    @Test func reconControlsExploredFlag() throws {
        let aware = try #require(GalaxyData.system("TYR"))   // recon: .aware
        #expect(aware.recon == .aware)
        #expect(aware.star.explored == false)
        let scanned = try #require(GalaxyData.system("CHK")) // recon: .scanned
        #expect(scanned.star.explored == true)
    }
}

@Suite struct SeededFieldTests {
    @Test func lcgIsDeterministicForAGivenSeed() {
        var a = SeededLCG(seed: 42)
        var b = SeededLCG(seed: 42)
        let seqA = (0..<8).map { _ in a.next() }
        let seqB = (0..<8).map { _ in b.next() }
        #expect(seqA == seqB)
        #expect(seqA.allSatisfy { $0 >= 0 && $0 < 1 })
    }

    @Test func differentSeedsDiverge() {
        var a = SeededLCG(seed: 1)
        var b = SeededLCG(seed: 2)
        #expect(a.next() != b.next())
    }
}

@MainActor
@Suite struct StarMapReducerTests {
    @Test func tappingASystemSelectsIt() async {
        let store = TestStore(initialState: StarMapFeature.State()) {
            StarMapFeature()
        }
        await store.send(.systemTapped("VLZ")) {
            $0.selectedSystemID = "VLZ"
        }
        await store.send(.systemTapped(nil)) {
            $0.selectedSystemID = nil
        }
    }

    @Test func togglingALayerAddsThenRemovesIt() async {
        let store = TestStore(initialState: StarMapFeature.State(activeLayers: [.presence])) {
            StarMapFeature()
        }
        await store.send(.layerToggled(.life)) {
            $0.activeLayers = [.presence, .life]
        }
        await store.send(.layerToggled(.presence)) {
            $0.activeLayers = [.life]
        }
    }

    @Test func autoRotateAndRecenter() async {
        let store = TestStore(initialState: StarMapFeature.State()) {
            StarMapFeature()
        }
        await store.send(.autoRotateToggled) { $0.autoRotate = false }
        await store.send(.recenterTapped) { $0.cameraResetToken = 1 }
        await store.send(.recenterTapped) { $0.cameraResetToken = 2 }
    }

    @Test func drillInThenZoomOutDrivesFocusAndTransition() async {
        let clock = TestClock()
        let store = TestStore(initialState: StarMapFeature.State()) {
            StarMapFeature()
        } withDependencies: {
            $0.continuousClock = clock
        }

        await store.send(.drillInRequested("CHK")) {
            $0.selectedSystemID = "CHK"
            $0.focus = .system("CHK")
            $0.isTransitioning = true
        }
        await clock.advance(by: .milliseconds(1150))
        await store.receive(\.transitionCompleted) {
            $0.isTransitioning = false
        }

        await store.send(.zoomOutRequested) {
            $0.focus = .galaxy
            $0.isTransitioning = true
        }
        await clock.advance(by: .milliseconds(950))
        await store.receive(\.transitionCompleted) {
            $0.isTransitioning = false
        }
    }

    @Test func drillInIgnoredWhileTransitioning() async {
        let store = TestStore(initialState: StarMapFeature.State(isTransitioning: true)) {
            StarMapFeature()
        }
        // A drill request mid-fly is a no-op (no state change, no effect).
        await store.send(.drillInRequested("CHK"))
    }
}

// MARK: - Survey & persistence

@MainActor
@Suite struct StarSurveyTests {
    private func makeStarsDatabase() throws -> any DatabaseWriter {
        let database = try SQLiteData.defaultDatabase()
        var migrator = DatabaseMigrator()
        Star.registerMigrations(&migrator)
        try migrator.migrate(database)
        return database
    }

    private func item(_ designation: String, explored: Bool = true, spectral: String = "G2 V") -> StarItem {
        StarItem(
            designation: designation, spectralType: spectral, color: "#fff4ea",
            position: Position(x: 1, y: 2, z: 3), estimatedPlanets: 3,
            explored: explored, hasLife: nil, entryPoint: nil
        )
    }

    private func page(_ number: Int, totalPages: Int, _ designations: [String], totalStars: Int) -> StarPage {
        StarPage(
            stars: designations.map { item($0) }, page: number, perPage: 100,
            totalStars: totalStars, totalPages: totalPages, replicantPosition: Position(x: 0, y: 0, z: 0)
        )
    }

    @Test func surveyWalksPagesAndPersistsAllStars() async throws {
        let database = try makeStarsDatabase()
        let defaults = UserDefaults.inMemory
        defaults.set("RC", forKey: Account.activeReplicantCodeKey)
        let page1 = page(1, totalPages: 2, ["AAA", "BBB"], totalStars: 3)
        let page2 = page(2, totalPages: 2, ["CCC"], totalStars: 3)

        let store = withDependencies {
            $0.defaultAppStorage = defaults
        } operation: {
            TestStore(initialState: StarMapFeature.State()) {
                StarMapFeature()
            } withDependencies: {
                $0.defaultDatabase = database
                $0.date = .constant(Date(timeIntervalSince1970: 1_000))
                $0.starsClient.survey = { _, _ in
                    AsyncThrowingStream { continuation in
                        continuation.yield(page1)
                        continuation.yield(page2)
                        continuation.finish()
                    }
                }
            }
        }

        await store.send(.surveyButtonTapped) { $0.isSurveying = true }
        await store.receive(\.surveyProgress) {
            $0.surveyPagesDone = 1; $0.surveyTotalPages = 2; $0.surveyStarCount = 3
        }
        await store.receive(\.surveyProgress) {
            $0.surveyPagesDone = 2; $0.surveyTotalPages = 2; $0.surveyStarCount = 3
        }
        await store.receive(\.surveyFinished) { $0.isSurveying = false }

        let count = try await database.read { db in try Star.fetchCount(db) }
        #expect(count == 3)
    }

    @Test func emptyDatabaseTriggersCorruptionModal() async throws {
        let database = try makeStarsDatabase()   // empty
        let store = TestStore(initialState: StarMapFeature.State()) {
            StarMapFeature()
        } withDependencies: {
            $0.defaultDatabase = database
        }
        await store.send(.task)
        await store.receive(\.bootCorruptionDetected) { $0.bootPhase = .corruptionDetected }
    }

    @Test func manualOverrideRebuildsThenAutoDismisses() async throws {
        let database = try makeStarsDatabase()
        let defaults = UserDefaults.inMemory
        defaults.set("RC", forKey: Account.activeReplicantCodeKey)
        let clock = TestClock()
        let only = page(1, totalPages: 1, ["AAA"], totalStars: 1)

        let store = withDependencies {
            $0.defaultAppStorage = defaults
        } operation: {
            TestStore(initialState: StarMapFeature.State()) {
                StarMapFeature()
            } withDependencies: {
                $0.defaultDatabase = database
                $0.continuousClock = clock
                $0.date = .constant(Date(timeIntervalSince1970: 1_000))
                $0.starsClient.survey = { _, _ in
                    AsyncThrowingStream { $0.yield(only); $0.finish() }
                }
            }
        }

        await store.send(.manualOverrideTapped) {
            $0.bootPhase = .rebuilding
            $0.isSurveying = true
        }
        await store.receive(\.surveyProgress) {
            $0.surveyPagesDone = 1; $0.surveyTotalPages = 1; $0.surveyStarCount = 1
        }
        await store.receive(\.surveyFinished) {
            $0.isSurveying = false
            $0.bootPhase = .complete
        }
        await clock.advance(by: .milliseconds(1400))
        await store.receive(\.bootDismissed) { $0.bootPhase = .idle }

        let count = try await database.read { db in try Star.fetchCount(db) }
        #expect(count == 1)
    }

    @Test func reSurveyRefreshesFieldsButPreservesTimestamps() async throws {
        let database = try makeStarsDatabase()
        let created = Date(timeIntervalSince1970: 1_000)
        let initial = Star(item: item("AAA", explored: false, spectral: "G2 V"), createdAt: created)
        let resurvey = Star(item: item("AAA", explored: true, spectral: "M0 V"),
                            createdAt: Date(timeIntervalSince1970: 2_000))

        // First survey stores AAA (unexplored, G2 V) with createdAt = 1000.
        try await database.write { db in
            try Star.insert { initial }.execute(db)
        }

        // Re-survey with changed fields and a later stamp; timestamps must hold.
        try await database.write { db in
            try Star.insert {
                resurvey
            } onConflict: {
                $0.designation
            } doUpdate: { row, excluded in
                row.spectralType = excluded.spectralType
                row.explored = excluded.explored
            }
            .execute(db)
        }

        let star = try await database.read { db in
            try Star.where { $0.designation.eq("AAA") }.fetchOne(db)
        }
        #expect(star?.createdAt == created)       // preserved
        #expect(star?.firstVisitedAt == nil)      // preserved (still unset)
        #expect(star?.explored == true)           // refreshed
        #expect(star?.spectralType == "M0 V")     // refreshed
    }
}
