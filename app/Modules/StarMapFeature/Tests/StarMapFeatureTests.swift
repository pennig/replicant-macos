import ComposableArchitecture
import Testing
@testable import StarMapFeature

@Suite struct GalaxyDataTests {
    @Test func seedsSixteenSystemsAndFiveRelays() {
        #expect(GalaxyData.systems.count == 16)
        #expect(GalaxyData.relays.count == 5)
    }

    @Test func homeIsChamakuyAtTheOrigin() throws {
        let home = try #require(GalaxyData.systems.first { $0.isHome })
        #expect(home.id == "CHK")
        // Distance is measured from home, so home's own distance is ~0.
        #expect(home.star.distanceFromReplicant == 0)
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
        #expect(store.state.selectedSystem?.id == "VLZ")

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

    @Test func drillInIgnoredForUnexploredSystem() async {
        let store = TestStore(initialState: StarMapFeature.State()) {
            StarMapFeature()
        } withDependencies: {
            $0.continuousClock = ImmediateClock()
        }
        // TYR is recon: .aware → not explored, so drilling is a no-op.
        await store.send(.drillInRequested("TYR"))
    }
}
