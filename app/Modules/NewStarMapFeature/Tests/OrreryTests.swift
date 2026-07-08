import ComposableArchitecture
import Foundation
import SQLiteData
import Testing
import UniverseModels
import simd
@testable import NewStarMapFeature

// Drill-in / zoom-out reducer flow and the pure orrery geometry. The camera fly,
// galaxy fade and orrery rendering live in the imperative renderer (not unit-
// tested); the reducer owns only the focus/transition state exercised here.

@MainActor
struct OrreryFocusReducerTests {
    @Test func drillInThenZoomOutTogglesFocusAndTransition() async {
        let clock = TestClock()
        let store = TestStore(initialState: NewStarMapFeature.State()) {
            NewStarMapFeature()
        } withDependencies: {
            $0.continuousClock = clock
            $0.locationsClient.system = { _ in throw LocationsError.notFound }
            $0.date = .constant(Date(timeIntervalSince1970: 0))
            $0.defaultDatabase = try! DatabaseQueue()
        }

        await store.send(.drillInRequested("CHK")) {
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
        let clock = TestClock()
        let store = TestStore(initialState: NewStarMapFeature.State()) {
            NewStarMapFeature()
        } withDependencies: {
            $0.continuousClock = clock
            $0.locationsClient.system = { _ in throw LocationsError.notFound }
            $0.date = .constant(Date(timeIntervalSince1970: 0))
            $0.defaultDatabase = try! DatabaseQueue()
        }

        await store.send(.drillInRequested("CHK")) {
            $0.focus = .system("CHK")
            $0.isTransitioning = true
        }
        // A second drill (or one for another system) mid-fly is a no-op.
        await store.send(.drillInRequested("XYZ"))

        await clock.advance(by: .milliseconds(1150))
        await store.receive(\.transitionCompleted) {
            $0.isTransitioning = false
        }
    }

    @Test func zoomOutFromGalaxyIsANoOp() async {
        let store = TestStore(initialState: NewStarMapFeature.State()) {
            NewStarMapFeature()
        } withDependencies: {
            $0.continuousClock = TestClock()
        }
        await store.send(.zoomOutRequested)   // already in the galaxy → nothing happens
    }
}

struct OrreryGeometryTests {
    @Test func unitSphereHasExpectedTopology() {
        let sphere = OrreryGeometry.unitSphere(rings: 8, sectors: 12)
        #expect(sphere.vertices.count == 9 * 13)
        #expect(sphere.indices.count == 8 * 12 * 6)
    }

    @Test func hexColorParses() {
        let c = OrreryGeometry.rgb(hex: "#ffb648")
        #expect(abs(c.x - 1) < 0.005)
        #expect(abs(c.y - Float(0xB6) / 255) < 0.005)
        #expect(abs(c.z - Float(0x48) / 255) < 0.005)
        #expect(OrreryGeometry.rgb(hex: "bad") == SIMD3<Float>(1, 1, 1))
    }

}

struct OrreryMappingTests {
    @Test func radialMapIsMonotonicAndCompressed() {
        // Inner planets stay legible while the outer system compresses inward.
        #expect(OrreryMapping.sceneRadius(au: 0.1) < OrreryMapping.sceneRadius(au: 1))
        #expect(OrreryMapping.sceneRadius(au: 1) < OrreryMapping.sceneRadius(au: 30))
        // 30 AU is ~300× 0.1 AU, but compressed to well under 30× on screen.
        let ratio = OrreryMapping.sceneRadius(au: 30) / OrreryMapping.sceneRadius(au: 0.1)
        #expect(ratio < 30)
    }

    @Test func phaseIsDeterministicAndInRange() {
        let a = OrreryMapping.phaseDeg("SHERATANON-6")
        #expect(a == OrreryMapping.phaseDeg("SHERATANON-6"))
        #expect(a >= 0 && a < 360)
        #expect(OrreryMapping.phaseDeg("SHERATANON-6") != OrreryMapping.phaseDeg("SHERATANON-7"))
    }

    @Test func planetColorByType() {
        #expect(OrreryMapping.planetColor(type: "Ocean World") == "#3f7fd0")
        #expect(OrreryMapping.planetColor(type: "Ice Giant") == "#9fd0e0")
        #expect(OrreryMapping.planetColor(type: nil) == OrreryMapping.planetColor(type: "unknown"))
    }

    @Test func mapsRealSystemToPlanetsBeltsHazards() {
        let system = StarSystem(
            designation: "AINALRAM",
            star: SystemStar(
                designation: "AINALRAM", stellarClass: "M2", color: "Red",
                temperatureK: 3411, massSolar: 0.37, luminositySolar: 0.06,
                habitableZoneInnerAu: 0.24, habitableZoneOuterAu: 0.42),
            recon: .scanned, systemScanned: true,
            belts: [Belt(designation: "AINALRAM-BELT-1", innerRadiusAu: 0.62, outerRadiusAu: 0.92, density: "moderate")],
            planets: [Planet(
                designation: "AINALRAM-1", type: "Barren", orbitalDistanceAu: 0.08,
                inHabitableZone: false, recon: .scanned, moonCount: 2,
                salvage: [SalvageSite(designation: "AINALRAM-1-SAL-1")])],
            structures: [
                SpecialSite(designation: "AINALRAM-KUIPER", kind: .kuiper, orbitalDistanceAu: 21.59),
                SpecialSite(designation: "AINALRAM-OBJ-2", kind: .object,
                            objectType: "incoming_asteroid", orbitalDistanceAu: 1.1),
            ])
        let m = OrreryMapping.systemModel(from: system)
        #expect(m.planets.count == 1)
        #expect(m.planets[0].indicators.contains(.salvage))
        #expect(m.planets[0].hasInterestingMoon)   // moonCount > 0 hint
        #expect(m.belts.count == 1)
        #expect(m.kuiperScene != nil)
        #expect(m.hazards.contains { $0.objectType == "incoming_asteroid" })
        #expect(m.star.habitableZone != nil)
        #expect(m.hzInnerScene != nil)
    }
}
