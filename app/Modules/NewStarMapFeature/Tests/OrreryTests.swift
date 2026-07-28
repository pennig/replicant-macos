import ComposableArchitecture
import Foundation
import GameModels
import GameServices
import SQLiteData
import Testing
import UniverseModels
import Utils
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

    @Test func drillIntoBodyThenZoomOutStepsThroughLevels() async {
        let clock = TestClock()
        let store = TestStore(initialState: NewStarMapFeature.State()) {
            NewStarMapFeature()
        } withDependencies: {
            $0.continuousClock = clock
            $0.locationsClient.system = { _ in throw LocationsError.notFound }
            $0.locationsClient.body = { _ in throw LocationsError.notFound }
            $0.date = .constant(Date(timeIntervalSince1970: 0))
            $0.defaultDatabase = try! DatabaseQueue()
        }

        await store.send(.drillInRequested("SHERATANON")) {
            $0.focus = .system("SHERATANON")
            $0.isTransitioning = true
        }
        await clock.advance(by: .milliseconds(1150))
        await store.receive(\.transitionCompleted) { $0.isTransitioning = false }

        // System → body.
        await store.send(.drillIntoBodyRequested("SHERATANON-6")) {
            $0.focus = .body("SHERATANON-6")
            $0.isTransitioning = true
        }
        await clock.advance(by: .milliseconds(1150))
        await store.receive(\.transitionCompleted) { $0.isTransitioning = false }

        // Zoom out steps exactly one level: body → system.
        await store.send(.zoomOutRequested) {
            $0.focus = .system("SHERATANON")
            $0.isTransitioning = true
        }
        await clock.advance(by: .milliseconds(950))
        await store.receive(\.transitionCompleted) { $0.isTransitioning = false }

        // Then system → galaxy.
        await store.send(.zoomOutRequested) {
            $0.focus = .galaxy
            $0.isTransitioning = true
        }
        await clock.advance(by: .milliseconds(950))
        await store.receive(\.transitionCompleted) { $0.isTransitioning = false }
    }

    @Test func drillIntoBodyFromGalaxyIsIgnored() async {
        let store = TestStore(initialState: NewStarMapFeature.State()) {
            NewStarMapFeature()
        } withDependencies: {
            $0.continuousClock = TestClock()
        }
        // Body drill is only valid from a system view.
        await store.send(.drillIntoBodyRequested("SHERATANON-6"))
    }

    @Test func locationSelectionIsExclusiveAndClearsOnLevelChange() async {
        let clock = TestClock()
        let store = TestStore(initialState: NewStarMapFeature.State()) {
            NewStarMapFeature()
        } withDependencies: {
            $0.continuousClock = clock
            $0.locationsClient.system = { _ in throw LocationsError.notFound }
            $0.date = .constant(Date(timeIntervalSince1970: 0))
            $0.defaultDatabase = try! DatabaseQueue()
        }

        await store.send(.drillInRequested("SOL")) {
            $0.focus = .system("SOL")
            $0.isTransitioning = true
        }
        await clock.advance(by: .milliseconds(1150))
        await store.receive(\.transitionCompleted) { $0.isTransitioning = false }

        // Picking a location surfaces it in the shared dossier slot.
        await store.send(.locationSelected("SOL-3")) { $0.selectedLocation = "SOL-3" }
        // A ship selection takes over the slot, clearing the location.
        await store.send(.shipSelected("ABCD1234")) {
            $0.selectedShipDeviceCode = "ABCD1234"
            $0.selectedLocation = nil
        }
        // Re-pick, then a level change (zoom out) clears it — anchors are level-specific.
        await store.send(.locationSelected("SOL-3")) {
            $0.selectedShipDeviceCode = nil
            $0.selectedLocation = "SOL-3"
        }
        await store.send(.zoomOutRequested) {
            $0.focus = .galaxy
            $0.selectedLocation = nil
            $0.isTransitioning = true
        }
        await clock.advance(by: .milliseconds(950))
        await store.receive(\.transitionCompleted) { $0.isTransitioning = false }
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

    @Test func pipEntriesAreOrderedAndEmptyWhenNoneSet() {
        #expect(OrreryGeometry.pipEntries([]).isEmpty)
        let all: BodyIndicators = [.inventory, .device, .life, .miningSite, .salvage]
        let kinds = OrreryGeometry.pipEntries(all).map(\.indicator)
        // Stable priority order regardless of insertion order (life first).
        #expect(kinds == [.life, .device, .salvage, .miningSite, .inventory])
    }

    @Test func hazardOffsetIsDeterministicAndClosesWithProgress() {
        let far = OrreryHazard(designation: "OBJ-1", objectType: "incoming_asteroid",
                               title: nil, orbitScene: 10, targetScene: nil,
                               progressPct: 0, deadline: nil)
        let near = OrreryHazard(designation: "OBJ-1", objectType: "incoming_asteroid",
                                title: nil, orbitScene: 10, targetScene: nil,
                                progressPct: 90, deadline: nil)
        // Same angle (same designation), nearer the star as progress climbs.
        #expect(OrreryGeometry.hazardOffset(far) == OrreryGeometry.hazardOffset(far))
        #expect(simd_length(OrreryGeometry.hazardOffset(near))
                    < simd_length(OrreryGeometry.hazardOffset(far)))
    }

    @Test func scaffoldIncludesHazardApproachSegment() {
        let base = SystemModel(
            star: StarDetail(designation: "S", name: nil, spectralType: nil, color: nil,
                             position: Position(x: 0, y: 0, z: 0), temperatureK: nil,
                             massSolar: nil, luminositySolar: nil, ageMy: nil,
                             habitableZone: nil, miningBonusPct: nil),
            hzInnerScene: nil, hzOuterScene: nil, planets: [], belts: [], hazards: [],
            kuiperScene: nil, frameScene: 20, deviceCount: 0, vesselCount: 0)
        let withHazard = SystemModel(
            star: base.star, hzInnerScene: nil, hzOuterScene: nil, planets: [], belts: [],
            hazards: [OrreryHazard(designation: "OBJ-1", objectType: "incoming_asteroid",
                                   title: nil, orbitScene: 10, targetScene: nil,
                                   progressPct: 20, deadline: nil)],
            kuiperScene: nil, frameScene: 20, deviceCount: 0, vesselCount: 0)
        let none = OrreryGeometry.scaffoldLines(model: base, center: .zero, scale: 1)
        let some = OrreryGeometry.scaffoldLines(model: withHazard, center: .zero, scale: 1)
        #expect(some.count == none.count + 2)   // one 2-vertex approach segment
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

    @Test func planetTypeClassification() {
        #expect(PlanetType(apiType: "Ocean World") == .oceanWorld)
        #expect(PlanetType(apiType: "Ice Giant") == .iceGiant)     // "giant" wins over bare "ice"
        #expect(PlanetType(apiType: "Frozen") == .frozen)
        #expect(PlanetType(apiType: "Super Earth") == .superEarth)
        #expect(PlanetType(apiType: "Volcanic") == .volcanic)
        #expect(PlanetType(apiType: nil) == .unknown(""))
        // Unrecognized labels keep their raw string (so a new game type isn't lost).
        #expect(PlanetType(apiType: "Ringworld Segment") == .unknown("Ringworld Segment"))
    }

    @Test func materialResolvesStyleLifeAndEstimated() {
        let ocean = PlanetMaterial.surface(for: .oceanWorld, lifeStage: "intelligent", estimated: false)
        #expect(ocean.style == .ocean)
        #expect(ocean.life == 1.0)
        #expect(!ocean.estimated)

        // An unconfirmed body still textures by its guessed type, flagged estimated.
        let guessedGiant = PlanetMaterial.surface(for: .gasGiant, lifeStage: nil, estimated: true)
        #expect(guessedGiant.style == .banded)
        #expect(guessedGiant.estimated)
        #expect(guessedGiant.life == 0)

        // Gas and ice giants texture with distinct styles.
        #expect(PlanetMaterial.style(.gasGiant) == .banded)
        #expect(PlanetMaterial.style(.iceGiant) == .iceGiant)

        // Unknown types fall back to the neutral rocky surface.
        #expect(PlanetMaterial.surface(for: .unknown("Ringworld"), lifeStage: nil, estimated: false).style == .rocky)
    }

    @Test func surfaceTemperatureShapesLavaAndIceCaps() {
        // Volcanic lava hue follows the black-body ramp: dull red → yellow/white.
        let cool = PlanetMaterial.surface(for: .volcanic, lifeStage: nil, estimated: false, surfaceTempC: 650)
        let hot  = PlanetMaterial.surface(for: .volcanic, lifeStage: nil, estimated: false, surfaceTempC: 1350)
        #expect(hot.detail.x >= cool.detail.x)                 // both near max red…
        #expect(hot.detail.y > cool.detail.y + 0.3)            // …but hotter adds green (toward yellow/white)
        #expect(hot.mods.lava > cool.mods.lava)                // hotter → more lava
        // Unknown temperature keeps the default lava tint (existing look preserved).
        let noTemp = PlanetMaterial.surface(for: .volcanic, lifeStage: nil, estimated: false)
        #expect(noTemp.detail == OrreryGeometry.rgb(hex: PlanetMaterial.detailHex(.volcanic)))
        #expect(noTemp.polarIce == 0)

        // Cold desert/terran/ocean worlds grow polar caps; the cap EXTENT ramps from
        // 40 °C (none) down to −40 °C (full), and colder always means more ice.
        func ice(_ type: PlanetType, _ temp: Double) -> Float {
            PlanetMaterial.surface(for: type, lifeStage: nil, estimated: false, surfaceTempC: temp).polarIce
        }
        #expect(ice(.superEarth, 40) == 0)                     // no ice at/above 40°C
        #expect(ice(.terrestrial, 15) > 0.03)                  // a mild-cold world shows a clear cap
        #expect(ice(.terrestrial, 15) < ice(.desertWorld, -30)) // colder → larger cap
        #expect(ice(.oceanWorld, -20) > 0.15)
        #expect(ice(.desertWorld, -200) == 1)                   // full extent by −40°C
        #expect(ice(.desertWorld, -300) == 1)                  // and clamps there
        // Ice caps are gated to those types — a cold gas giant gets none.
        #expect(ice(.gasGiant, -30) == 0)
    }

    @Test func appearanceSeedIsStableAndVaries() {
        // Same inputs → identical seed (a planet always looks the same), in [0, 1).
        let a = OrreryMapping.appearanceSeed(designation: "SOL-5", rotationPeriodHours: 9.9)
        let b = OrreryMapping.appearanceSeed(designation: "SOL-5", rotationPeriodHours: 9.9)
        #expect(a == b)
        #expect(a >= 0 && a < 1)

        // Different name or rotation → (almost surely) a different seed.
        #expect(OrreryMapping.appearanceSeed(designation: "SOL-6", rotationPeriodHours: 9.9) != a)
        #expect(OrreryMapping.appearanceSeed(designation: "SOL-5", rotationPeriodHours: 10.7) != a)

        // Absent rotation (unscanned) is handled and still stable.
        let n1 = OrreryMapping.appearanceSeed(designation: "SOL-5", rotationPeriodHours: nil)
        let n2 = OrreryMapping.appearanceSeed(designation: "SOL-5", rotationPeriodHours: nil)
        #expect(n1 == n2)
        #expect(n1 >= 0 && n1 < 1)
    }

    @Test func tagsMapToSurfaceModifiers() {
        // No useful tags → neutral modifiers (identical to the untagged look).
        #expect(PlanetMaterial.modifiers(tags: []) == SurfaceModifiers())
        #expect(PlanetMaterial.modifiers(tags: ["barren", "ice_giant"]) == SurfaceModifiers())

        let barren = PlanetMaterial.modifiers(tags: ["cratered", "no_atmosphere"])
        #expect(barren.craters == 1.6)
        #expect(barren.atmosphere == 0)

        // Strongest lava tag wins when several apply.
        let hell = PlanetMaterial.modifiers(tags: ["volcanic", "hellworld", "tectonically_active"])
        #expect(hell.lava == 1.8)

        #expect(PlanetMaterial.modifiers(tags: ["ice_surface"]).frost == 0.7)
        // Unknown tags are ignored (a new game tag can't break rendering).
        #expect(PlanetMaterial.modifiers(tags: ["ringed", "haunted"]) == SurfaceModifiers())
    }

    @Test func mapsLagrangePointsAndStructures() {
        let system = StarSystem(
            designation: "SOL",
            star: SystemStar(designation: "SOL", stellarClass: "G2", color: "Yellow"),
            recon: .scanned, systemScanned: true,
            planets: [Planet(
                designation: "SOL-5", type: "Gas Giant", orbitalDistanceAu: 5.2, recon: .scanned,
                lagrange: [
                    SpecialSite(designation: "SOL-5-L4", kind: .lagrange, parentBody: "SOL-5"),
                    SpecialSite(designation: "SOL-5-L1", kind: .lagrange, parentBody: "SOL-5"),
                ])],
            structures: [
                SpecialSite(designation: "SOL-KUIPER", kind: .kuiper, orbitalDistanceAu: 44.5),
                SpecialSite(designation: "SOL-OBJ-1", kind: .megastructure,
                            objectType: "megastructure", orbitalDistanceAu: 1.0),
            ])
        let m = OrreryMapping.systemModel(from: system)
        let ls = m.planets[0].lagrange
        // All 5 Lagrange points are synthesized per planet (shown/selectable device or not).
        #expect(Set(ls.map(\.point)) == [1, 2, 3, 4, 5])
        #expect(ls.first { $0.designation == "SOL-5-L4" }?.point == 4)
        // Structures with an orbital distance become positioned anchors.
        #expect(Set(m.structures.map(\.designation)) == ["SOL-KUIPER", "SOL-OBJ-1"])
    }

    @Test func beltIndicatorsFromSitesAndInventory() {
        let system = StarSystem(
            designation: "SOL",
            star: SystemStar(designation: "SOL", stellarClass: "G2", color: "Yellow"),
            recon: .scanned, systemScanned: true,
            belts: [
                Belt(designation: "SOL-BELT-1", innerRadiusAu: 2, outerRadiusAu: 3, density: "dense",
                     sites: [ResourceSite(designation: "SOL-BELT-1-SITE-0")],
                     inventory: [InventoryItem(resourceType: "structural", quantity: 100)]),
                Belt(designation: "SOL-BELT-2", innerRadiusAu: 4, outerRadiusAu: 5),
            ])
        let m = OrreryMapping.systemModel(from: system)
        let b1 = m.belts.first { $0.designation == "SOL-BELT-1" }
        let b2 = m.belts.first { $0.designation == "SOL-BELT-2" }
        #expect(b1?.indicators.contains(.miningSite) == true)
        #expect(b1?.indicators.contains(.inventory) == true)
        #expect(b2?.indicators.isEmpty == true)
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

    @Test func bodyModelBuildsCentralPlanetAndMoons() {
        let planet = Planet(
            designation: "SHERATANON-6", name: "Zeta", type: "Gas Giant",
            orbitalDistanceAu: 5.2, recon: .scanned, moonCount: 3,
            physical: BodyPhysical(radiusEarth: 9, rings: true),
            moons: [
                Moon(designation: "SHERATANON-6-a", type: "Icy", recon: .scanned,
                     physical: BodyPhysical(radiusEarth: 0.3, orbitalPeriodDays: 2,
                                            orbitalDistanceKm: 200_000)),
                Moon(designation: "SHERATANON-6-b", recon: .scanned,
                     salvage: [SalvageSite(designation: "SHERATANON-6-b-SAL-1")]),
            ])
        let m = OrreryMapping.bodyModel(planet: planet)
        #expect(m.centralBody != nil)
        #expect(m.centralBody?.rings != nil)
        #expect(m.planets.count == 2)                       // moons became orbiters
        // Both moons promote (the roster is well under the promote-all threshold).
        // Ordering is nearest-known-distance-first now, not interest-first — the cap
        // that ordering used to serve is gone, and MoonTiering already guarantees an
        // interesting moon is never dropped regardless of where it sorts.
        #expect(m.planets.first { $0.designation == "SHERATANON-6-b" }?
            .indicators.contains(.salvage) == true)
        // Every moon orbits outside the central planet.
        let central = m.centralBody?.displayRadius ?? 0
        #expect(m.planets.allSatisfy { $0.semiMajorScene - $0.displayRadius > central })
    }

    @Test func habitableZoneBandTracksSpacedPlanetOrbits() throws {
        // A crowded inner system so the spacing pass pushes orbits well past their raw
        // AU-mapped radii. The drawn HZ band must move with them: a planet whose AU is in
        // the zone must render INSIDE the band, and one outside must render OUTSIDE —
        // otherwise the visual would contradict the data.
        let hzInner = 0.7, hzOuter = 1.6
        let aus: [Double] = [0.05, 0.2, 0.5, 0.9, 1.2, 1.5, 2.4, 6.0]
        let planets = aus.enumerated().map { i, au in
            Planet(designation: "HZ-\(i + 1)", type: "Barren",
                   orbitalDistanceAu: au, inHabitableZone: au >= hzInner && au <= hzOuter,
                   recon: .scanned)
        }
        let system = StarSystem(
            designation: "HZTEST",
            star: SystemStar(designation: "HZTEST", stellarClass: "G2", color: "Yellow",
                             habitableZoneInnerAu: hzInner, habitableZoneOuterAu: hzOuter),
            recon: .scanned, systemScanned: true, planets: planets)
        let m = OrreryMapping.systemModel(from: system)
        let bandInner = try #require(m.hzInnerScene)
        let bandOuter = try #require(m.hzOuterScene)

        for planet in m.planets {
            let inByData = planet.orbitalDistanceAu >= hzInner && planet.orbitalDistanceAu <= hzOuter
            let inByGeometry = planet.semiMajorScene >= bandInner && planet.semiMajorScene <= bandOuter
            #expect(inByData == inByGeometry,
                    "\(planet.designation): au=\(planet.orbitalDistanceAu) inData=\(inByData) but orbit=\(planet.semiMajorScene) in [\(bandInner), \(bandOuter)]=\(inByGeometry)")
        }
    }

    @Test func crowdedInnerPlanetsClearSunAndEachOther() {
        // Modelled on SHERATANON: several close-in planets whose sqrt-mapped orbits land
        // inside the large sun and near one another. They must clear the star and never
        // stack on the same ring.
        let aus: [Double] = [0.251, 0.44, 0.805, 1.362, 1.856, 3.154, 5.343, 9.482, 18.881, 31.058]
        let planets = aus.enumerated().map { i, au in
            Planet(designation: "SHERATANON-\(i + 1)", type: "Barren",
                   orbitalDistanceAu: au, recon: .scanned)
        }
        let system = StarSystem(
            designation: "SHERATANON",
            star: SystemStar(designation: "SHERATANON", stellarClass: "K3", color: "Orange"),
            recon: .scanned, systemScanned: true, planets: planets)
        let m = OrreryMapping.systemModel(from: system)
        let sunScene = OrreryMapping.sunSceneFraction * m.frameScene

        // Every planet is smaller than the sun and orbits outside its sphere.
        #expect(m.planets.allSatisfy { $0.displayRadius < sunScene })
        #expect(m.planets.allSatisfy { $0.semiMajorScene - $0.displayRadius >= sunScene })

        // No two adjacent orbits intersect: the gap between neighbouring orbit radii
        // exceeds the sum of the two planet radii.
        let sorted = m.planets.sorted { $0.semiMajorScene < $1.semiMajorScene }
        for (a, b) in zip(sorted, sorted.dropFirst()) {
            #expect(b.semiMajorScene - a.semiMajorScene > a.displayRadius + b.displayRadius)
        }
    }
}

struct OrreryLayoutTests {
    // Minimal factories for precise control of the layout math.
    private func planet(_ id: String, phase: Double, semi: Double, radius: Double = 1,
                        period: Double = 100, lagrange: [LagrangePoint] = []) -> OrreryPlanet {
        OrreryPlanet(
            designation: id, name: nil, type: nil, planetType: .unknown(""), estimated: false,
            tags: [], surfaceTempC: nil, atmosphere: Atmosphere(apiValue: nil), appearanceSeed: 0,
            orbitalDistanceAu: 1, inHabitableZone: false, scanned: true, moonCount: 0, lifeStage: nil,
            inventory: [], semiMajorScene: semi, periodDays: period, phase0Deg: phase,
            displayRadius: radius, colorHex: "#ffffff", rings: nil, indicators: [],
            hasInterestingMoon: false, moons: [], lagrange: lagrange)
    }

    private func model(planets: [OrreryPlanet], belts: [BeltModel] = [],
                       structures: [OrreryStructure] = [], starID: String = "SOL") -> SystemModel {
        SystemModel(
            star: StarDetail(designation: starID, name: nil, spectralType: nil, color: nil,
                             position: Position(x: 0, y: 0, z: 0), temperatureK: nil, massSolar: nil,
                             luminositySolar: nil, ageMy: nil, habitableZone: nil, miningBonusPct: nil),
            hzInnerScene: nil, hzOuterScene: nil, planets: planets, belts: belts, hazards: [],
            structures: structures, kuiperScene: nil, frameScene: 20, deviceCount: 0, vesselCount: 0)
    }

    private func layout(_ m: SystemModel, center: SIMD3<Float> = .zero, scale: Float = 1,
                        reveal: Float = 1, time: Float = 0) -> OrreryLayout {
        OrreryLayout(model: m, center: center, scale: scale, reveal: reveal, time: time)
    }

    private func approx(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ tol: Float = 1e-3) -> Bool {
        simd_length(a - b) < tol
    }

    @Test func orbiterPositionMatchesOrbitMathAndScalesWithReveal() {
        let m = model(planets: [planet("SOL-5", phase: 90, semi: 10)])
        // phase 90°, time 0 → angle π/2 → (0, 0, 10).
        #expect(approx(layout(m).orbiterPosition(id: "SOL-5")!, SIMD3(0, 0, 10)))
        // Reveal scales the orbit radius; center offsets it.
        #expect(approx(layout(m, center: SIMD3(1, 0, 0), reveal: 0.5).orbiterPosition(id: "SOL-5")!,
                       SIMD3(1, 0, 5)))
        #expect(layout(m).orbiterPosition(id: "NOPE") == nil)
    }

    @Test func lagrangePointsSitRelativeToTheirPlanet() {
        // Planet at phase 0 → angle 0 → (10, 0, 0). off = max(10·0.1, 1·3) = 3.
        let ls = [1, 2, 3, 4, 5].map { LagrangePoint(designation: "SOL-5-L\($0)", point: $0) }
        let m = model(planets: [planet("SOL-5", phase: 0, semi: 10, radius: 1, lagrange: ls)])
        let L = layout(m)
        #expect(approx(L.lagrangePosition("SOL-5-L1")!, SIMD3(7, 0, 0)))    // sunward
        #expect(approx(L.lagrangePosition("SOL-5-L2")!, SIMD3(13, 0, 0)))   // anti-sunward
        #expect(approx(L.lagrangePosition("SOL-5-L3")!, SIMD3(-10, 0, 0)))  // opposite the star
        // L4/L5 lead/trail by 60° on the orbit radius (magnitude stays 10).
        #expect(approx(L.lagrangePosition("SOL-5-L4")!, SIMD3(5, 0, 10 * sinf(.pi / 3))))
        #expect(approx(L.lagrangePosition("SOL-5-L5")!, SIMD3(5, 0, -10 * sinf(.pi / 3))))
    }

    @Test func topLevelResolutionIsLevelAware() {
        let m = model(
            planets: [planet("SOL-5", phase: 0, semi: 10,
                             lagrange: [LagrangePoint(designation: "SOL-5-L4", point: 4)])],
            belts: [BeltModel(designation: "SOL-BELT-1", innerScene: 8, outerScene: 12,
                              density: "moderate", richness: [:], hasSites: false)],
            structures: [OrreryStructure(designation: "SOL-OBJ-1", kind: "megastructure", orbitScene: 20)])
        let L = layout(m)
        // The system star / central resolves to the centre.
        #expect(approx(L.position(ofLocation: "SOL")!, .zero))
        // A planet resolves exactly; a MOON collapses to its parent planet at system level.
        #expect(approx(L.position(ofLocation: "SOL-5")!, SIMD3(10, 0, 0)))
        #expect(approx(L.position(ofLocation: "SOL-5-1")!, SIMD3(10, 0, 0)))
        // A Lagrange point resolves to its offset spot.
        #expect(approx(L.position(ofLocation: "SOL-5-L4")!, SIMD3(5, 0, 10 * sinf(.pi / 3))))
        // A belt (and a site under it) resolves to the ring anchor (mid-radius 10).
        #expect(abs(simd_length(L.position(ofLocation: "SOL-BELT-1")!) - 10) < 1e-3)
        #expect(approx(L.position(ofLocation: "SOL-BELT-1-SITE-3")!, L.position(ofLocation: "SOL-BELT-1")!))
        // A structure resolves to its orbit radius (20).
        #expect(abs(simd_length(L.position(ofLocation: "SOL-OBJ-1")!) - 20) < 1e-3)
        // Nothing known, not even an ancestor → nil.
        #expect(L.position(ofLocation: "ZZZ-9") == nil)
    }

    @Test func anchorCodeCollapsesToTheDrawnLevel() {
        let m = model(
            planets: [planet("SOL-3", phase: 0, semi: 10,
                             lagrange: [LagrangePoint(designation: "SOL-3-L4", point: 4)])],
            belts: [BeltModel(designation: "SOL-BELT-1", innerScene: 8, outerScene: 12,
                              density: nil, richness: [:], hasSites: false)])
        let L = layout(m)
        #expect(L.anchor(ofLocation: "SOL-3")?.code == "SOL-3")            // planet, exact
        #expect(L.anchor(ofLocation: "SOL-3-1")?.code == "SOL-3")          // moon → parent planet
        #expect(L.anchor(ofLocation: "SOL-3-1-SITE-2")?.code == "SOL-3")   // site under a moon → planet
        #expect(L.anchor(ofLocation: "SOL-3-L4")?.code == "SOL-3-L4")      // Lagrange, exact
        #expect(L.anchor(ofLocation: "SOL-BELT-1")?.code == "SOL-BELT-1")  // belt, exact
        #expect(L.anchor(ofLocation: "SOL")?.code == "SOL")                // star centre
        #expect(L.anchor(ofLocation: "ZZZ-1") == nil)
    }

    @Test func clusteringDedupsOwnOverOthersAndGroupsByAnchor() {
        let m = model(planets: [planet("SOL-3", phase: 0, semi: 10)])
        let L = layout(m)
        let own = [
            DeviceClustering.Input(deviceCode: "AAA", deviceType: "mining_drone", status: "mining", location: "SOL-3"),
            DeviceClustering.Input(deviceCode: "BBB", deviceType: "ftl_relay", status: "relaying", location: "SOL-3-1"),
        ]
        let others = [
            // Duplicate of an own device → dropped (own wins).
            DeviceClustering.Input(deviceCode: "AAA", deviceType: "mining_drone", status: nil, location: "SOL-3"),
            // A foreign device on the planet.
            DeviceClustering.Input(deviceCode: "CCC", deviceType: "autofactory", status: "idle", location: "SOL-3"),
        ]
        let clusters = DeviceClustering.clusters(own: own, others: others, layout: L)
        // Everything rolls up to SOL-3 at system level (moon SOL-3-1 → its planet).
        #expect(clusters.count == 1)
        let c = try! #require(clusters.first)
        #expect(c.anchorCode == "SOL-3")
        #expect(c.count == 3)                       // AAA, BBB, CCC — the duplicate AAA dropped
        #expect(c.devices.filter(\.isOwn).count == 2)
        #expect(c.hasOwn)
        // Own devices sort first.
        let firstTwoOwn = c.devices.prefix(2).allSatisfy { $0.isOwn }
        #expect(firstTwoOwn)
        #expect(c.primaryType == "mining_drone")    // first own device's glyph
    }
}

/// The date-domain twin of the renderer's media-time walk: the LAST leg ends at
/// the trip's arrival and each earlier leg's end is found by subtracting the
/// durations after it. The callout counts down to one of these.
struct ShipLegDateTests {
    private let arrival = Date(timeIntervalSince1970: 1_000)

    @Test func lastLegEndsAtArrivalAndEarlierLegsWalkBackwards() {
        let dates = Ship.legEndDates(seconds: [45, 388, 35], arrivesAt: arrival)

        #expect(dates == [
            Date(timeIntervalSince1970: 1_000 - 388 - 35),
            Date(timeIntervalSince1970: 1_000 - 35),
            Date(timeIntervalSince1970: 1_000),
        ])
    }

    @Test func singleLegEndsAtArrival() {
        #expect(Ship.legEndDates(seconds: [265], arrivesAt: arrival) == [arrival])
    }

    /// A leg with no duration makes the whole walk meaningless — the renderer
    /// already falls back to a straight segment in exactly this case.
    @Test func anyMissingDurationYieldsNoDates() {
        #expect(Ship.legEndDates(seconds: [45, nil, 35], arrivesAt: arrival) == nil)
    }

    @Test func noLegsYieldsNoDates() {
        #expect(Ship.legEndDates(seconds: [], arrivesAt: arrival) == nil)
    }
}

/// The reported bug, end to end across the two pure layers that caused it: a route
/// naming a bare system designation used to anchor its riser on the star, because
/// `OrreryLayout` resolves a system code to the centre. Normalizing the proxy
/// against the code the same payload supplies moves it to the entry point.
///
/// Built from a real `travel` payload rather than hand-assembled values, so the
/// parse and the normalization are both exercised.
struct BareSystemRouteAnchorTests {
    private func planet(_ id: String, semi: Double, lagrange: [LagrangePoint]) -> OrreryPlanet {
        OrreryPlanet(
            designation: id, name: nil, type: nil, planetType: .unknown(""), estimated: false,
            tags: [], surfaceTempC: nil, atmosphere: Atmosphere(apiValue: nil), appearanceSeed: 0,
            orbitalDistanceAu: 1, inHabitableZone: false, scanned: true, moonCount: 0, lifeStage: nil,
            inventory: [], semiMajorScene: semi, periodDays: 100, phase0Deg: 0,
            displayRadius: 1, colorHex: "#ffffff", rings: nil, indicators: [],
            hasInterestingMoon: false, moons: [], lagrange: lagrange)
    }

    /// ASTELLIO's orrery, with planet 1 carrying the L4 the backend uses as the
    /// system's entry point.
    private var layout: OrreryLayout {
        let model = SystemModel(
            star: StarDetail(designation: "ASTELLIO", name: nil, spectralType: nil, color: nil,
                             position: Position(x: 0, y: 0, z: 0), temperatureK: nil, massSolar: nil,
                             luminositySolar: nil, ageMy: nil, habitableZone: nil, miningBonusPct: nil),
            hzInnerScene: nil, hzOuterScene: nil,
            planets: [planet("ASTELLIO-1", semi: 10,
                             lagrange: [LagrangePoint(designation: "ASTELLIO-1-L4", point: 4)])],
            belts: [], hazards: [], structures: [], kuiperScene: nil,
            frameScene: 20, deviceCount: 0, vesselCount: 0)
        return OrreryLayout(model: model, center: .zero, scale: 1, reveal: 1, time: 0)
    }

    /// The live block for a device surging to "ASTELLIO": the leg names the proxy,
    /// `final_destination` names the entry point.
    private var snapshot: TravelSnapshot {
        TravelSnapshot(travelObject: .object([
            "origin": .string("ALKALUROP-3-L4"),
            "destination": .string("ASTELLIO"),
            "final_destination": .string("ASTELLIO-1-L4"),
            "route": .array([
                .object([
                    "leg": .number(1),
                    "from": .string("ALKALUROP-3-L4"),
                    "to": .string("ASTELLIO"),
                    "type": .string("surge"),
                    "time_seconds": .number(265),
                    "active": .bool(true),
                ])
            ]),
        ]))!
    }

    /// `Ship.orderedCodes`' input: the route's location codes, origin → each leg's
    /// destination.
    private func orderedCodes(_ s: TravelSnapshot) -> [String] {
        let pairs = s.legs.compactMap { leg -> (String, String)? in
            guard let f = leg.from, let t = leg.to else { return nil }
            return (f, t)
        }
        guard let first = pairs.first else { return [] }
        return [first.0] + pairs.map(\.1)
    }

    @Test func rawProxyCodeAnchorsOnTheStar() {
        // The bug: "ASTELLIO" resolves to the layer's centre.
        #expect(layout.position(ofLocation: "ASTELLIO") == .zero)

        let r = SystemTransit.resolve(
            orderedCodes: orderedCodes(snapshot), deviceCode: "F2908E6E",
            resolves: { layout.position(ofLocation: $0) != nil })

        #expect(r.boundaries.map(\.anchorCode) == ["ASTELLIO"])
        #expect(layout.position(ofLocation: r.boundaries[0].anchorCode) == .zero)  // the sun
    }

    @Test func normalizedRouteAnchorsOnTheEntryPoint() {
        let codes = orderedCodes(snapshot.resolvingSystemProxies)
        #expect(codes == ["ALKALUROP-3-L4", "ASTELLIO-1-L4"])

        let r = SystemTransit.resolve(
            orderedCodes: codes, deviceCode: "F2908E6E",
            resolves: { layout.position(ofLocation: $0) != nil })

        #expect(r.boundaries.map(\.anchorCode) == ["ASTELLIO-1-L4"])
        #expect(r.boundaries.map(\.direction) == [.inbound])
        #expect(r.boundaries.map(\.anchorIndex) == [1])
        // The riser now sits off-centre, on the planet's leading Lagrange point.
        let anchor = layout.position(ofLocation: "ASTELLIO-1-L4")
        #expect(anchor != nil)
        #expect(anchor != .zero)
    }
}

// MARK: - Body spin (axial tilt, rotation, tidal lock)

// Values below are real, probed from `locations/SOL-{2,5,6,7}` — the live account's
// own data — so these tests pin behaviour against the game rather than an invention.

struct BodySpinTests {
    @Test func obliquityAndSignMatchRealBodies() {
        // Venus: nearly upside-down AND an explicitly negative period.
        let venus = BodySpin(tiltDeg: 177.4, rotationHours: -5832.5)
        #expect(abs(venus.obliquityDeg - 177.4) < 1e-9)
        #expect(venus.sign == -1)

        // Uranus: rolled onto its side, also an explicit negative period.
        let uranus = BodySpin(tiltDeg: 97.77, rotationHours: -17.24)
        #expect(abs(uranus.obliquityDeg - 97.77) < 1e-9)
        #expect(uranus.sign == -1)

        // Jupiter / Saturn: upright and prograde.
        #expect(BodySpin(tiltDeg: 3.13, rotationHours: 9.92).sign == 1)
        #expect(BodySpin(tiltDeg: 26.73, rotationHours: 10.66).sign == 1)
    }

    @Test func obliquityPastNinetyIsRetrogradeGeometrically() {
        // The convention is "obliquity > 90 means retrograde", and that is the
        // GEOMETRY, not a branch: past 90 the pole tips below the orbital plane, so
        // a body spinning right-handed about it reads backwards from above.
        #expect(BodySpin(tiltDeg: 97.77).isRetrograde)
        #expect(BodySpin(tiltDeg: 177.4).isRetrograde)
        #expect(!BodySpin(tiltDeg: 26.73).isRetrograde)

        // The pole tipping below the plane is what produces it — no sign flip needed.
        #expect(BodySpin(tiltDeg: 97.77).pole(seed: 0.3).y < 0)
        #expect(BodySpin(tiltDeg: 26.73).pole(seed: 0.3).y > 0)

        // So `sign` must stay +1 for a high obliquity: flipping it too would
        // double-count and cancel the geometry back to prograde.
        #expect(BodySpin(tiltDeg: 97.77).sign == 1)
        #expect(BodySpin(tiltDeg: 177.4).sign == 1)
    }

    @Test func outOfRangeTiltNormalizes() {
        // Defensive only — the backend reports 0…180. A stray value must still land
        // on a sane obliquity rather than aiming the pole somewhere absurd.
        #expect(abs(BodySpin(tiltDeg: 200).obliquityDeg - 160) < 1e-9)
        #expect(abs(BodySpin(tiltDeg: 380).obliquityDeg - 20) < 1e-9)
        #expect(abs(BodySpin(tiltDeg: -30).obliquityDeg - 30) < 1e-9)
    }

    @Test func unknownTiltIsUpright() {
        #expect(BodySpin.unknown.obliquityDeg == 0)
        #expect(BodySpin.unknown.sign == 1)
        #expect(!BodySpin.unknown.isRetrograde)
        let p = BodySpin.unknown.pole(seed: 0.4)
        #expect(abs(p.y - 1) < 1e-6)
    }

    @Test func poleTiltsByObliquityAndStaysUnit() {
        let upright = BodySpin(tiltDeg: 0).pole(seed: 0.3)
        #expect(abs(upright.y - 1) < 1e-6)

        // 90 degrees lays the pole into the orbital plane — the RAW geometry, so
        // disable the render compression (Task 7) with tiltCapDeg: 90 to exercise it
        // directly rather than the compressed default.
        let sideways = BodySpin(tiltDeg: 90, tiltCapDeg: 90).pole(seed: 0.3)
        #expect(abs(sideways.y) < 1e-6)
        #expect(abs(simd_length(sideways) - 1) < 1e-6)

        // Same tilt, different seed => different lean direction, so two worlds
        // sharing an obliquity don't all lean the same way.
        let a = BodySpin(tiltDeg: 45).pole(seed: 0.1)
        let b = BodySpin(tiltDeg: 45).pole(seed: 0.8)
        #expect(simd_length(a - b) > 1e-3)
        #expect(abs(a.y - b.y) < 1e-6)   // same obliquity => same height
    }

    @Test func spinRateAnchorsOnAGlobalReferenceDay() {
        // A 24-hour world turns at the base rate — the flat speed EVERY planet span
        // at before rotation periods were wired in, so a typical world keeps its
        // familiar pace instead of being dragged below it.
        #expect(abs(BodySpin(rotationHours: 24).spinRate() - 0.06) < 1e-6)
        // Four times slower than the reference => half rate at falloff 0.5.
        #expect(abs(BodySpin(rotationHours: 96).spinRate() - 0.03) < 1e-6)
        // Faster than a day reads faster on screen. SOL-5 (9.92 h) now OUTPACES the
        // old flat rate rather than being pinned to it.
        #expect(BodySpin(rotationHours: 9.92).spinRate() > 0.06)
        // No reading => the historical fixed rate, prograde.
        #expect(BodySpin.unknown.spinRate() == 0.06)
    }

    @Test func spinRateNeverDependsOnNeighbouringBodies() {
        // The anchor is a global constant, so scanning a fast rotator can no longer
        // silently slow every other planet in its system. A body's rate is a pure
        // function of its OWN period — the whole point of dropping the per-layer
        // "fastest rotator" anchor.
        let earth = BodySpin(rotationHours: 24).spinRate()
        for _ in 0..<3 { #expect(BodySpin(rotationHours: 24).spinRate() == earth) }
        #expect(abs(earth - 0.06) < 1e-6)
    }

    @Test func everySolPeriodLandsInThePerceptibleBand() {
        // The real SOL spread, 9.92 h … 5832.5 h (588x).
        for h in [9.92, 10.66, 16.11, -17.24, 24, 24.6, 1407.6, -5832.5] {
            let r = abs(BodySpin(rotationHours: h).spinRate())
            #expect(r >= BodySpin.minRate)
            #expect(r <= BodySpin.maxRate)
        }
        // SOL-1 and SOL-2 are so slow they clamp to the floor: uncompressed they
        // would take ~13 and ~27 minutes per turn and read as frozen.
        #expect(abs(BodySpin(rotationHours: 1407.6).spinRate()) == BodySpin.minRate)
        #expect(abs(BodySpin(rotationHours: -5832.5).spinRate()) == BodySpin.minRate)
        // …and the clamp preserves the retrograde sign.
        #expect(BodySpin(rotationHours: -5832.5).spinRate() < 0)
    }

    @Test func fasterRotatorsOutpaceSlowerOnesWithinTheBand() {
        let jupiter = abs(BodySpin(rotationHours: 9.92).spinRate())   // SOL-5
        let neptune = abs(BodySpin(rotationHours: 16.11).spinRate())  // SOL-8
        let earth = abs(BodySpin(rotationHours: 24).spinRate())       // SOL-3
        #expect(jupiter > neptune)
        #expect(neptune > earth)
    }

    @Test func bodyFrameIsRightHanded() {
        // The texturing basis MUST be a rotation, not a reflection. Building z as
        // cross(pole, x) instead of cross(x, pole) gives determinant -1, which mirrors
        // the sphere and makes every planet appear to spin BACKWARDS. That shipped
        // once; this test is why it cannot ship again unnoticed.
        // SYNC POINT: orrery_body_fragment builds the same basis on the GPU.
        for spin in [BodySpin.unknown,
                     BodySpin(tiltDeg: 26.73),      // SOL-6
                     BodySpin(tiltDeg: 97.77),      // SOL-7, past 90
                     BodySpin(tiltDeg: 177.4),      // SOL-2, near-inverted
                     BodySpin(tiltDeg: 90)] {       // pole in the orbital plane
            for seed in [Float(0), 0.37, 0.81] {
                let f = spin.frame(seed: seed)
                let det = simd_dot(f.x, simd_cross(f.pole, f.z))
                #expect(abs(det - 1) < 1e-4)
                // Orthonormal, too.
                #expect(abs(simd_length(f.x) - 1) < 1e-5)
                #expect(abs(simd_length(f.z) - 1) < 1e-5)
                #expect(abs(simd_dot(f.x, f.pole)) < 1e-5)
                #expect(abs(simd_dot(f.x, f.z)) < 1e-5)
                #expect(abs(simd_dot(f.pole, f.z)) < 1e-5)
            }
        }
    }

    @Test func tidallyLockedIsCarriedThrough() {
        #expect(BodySpin(tidallyLocked: true).tidallyLocked)
        #expect(!BodySpin.unknown.tidallyLocked)
    }

    @Test func tidallyLockedBodyKeepsOneFaceTowardItsParent() {
        // A faithful mirror of the two conventions that compose here.
        //
        // `orrery_body_fragment` rotates the texture LOOKUP direction by
        //   S(spin) = (x·cos − z·sin, y, x·sin + z·cos)
        // so a FIXED surface feature appears at S(−spin) applied to that feature.
        func featureWorldDirection(spin: Float) -> SIMD3<Float> {
            let s = -spin
            let f = SIMD3<Float>(1, 0, 0)          // an arbitrary fixed surface feature
            return SIMD3(f.x * cos(s) - f.z * sin(s), f.y, f.x * sin(s) + f.z * cos(s))
        }
        // `OrreryLayout` places the body at (cos a, 0, sin a); the parent sits at the
        // centre, so the direction from body back to parent is the negation.
        func parentDirection(orbitAngle a: Float) -> SIMD3<Float> {
            -SIMD3<Float>(cos(a), 0, sin(a))
        }

        // Orbit angle DECREASES with time (see OrbitTiming.angle).
        let orbitAngles: [Float] = (0..<8).map { 0.9 - Float($0) * 0.31 }

        for a in orbitAngles {
            let spin = BodySpin.lockedSpinPhase(orbitAngle: a)
            let alignment = simd_dot(featureWorldDirection(spin: spin), parentDirection(orbitAngle: a))
            // −1 means that face points EXACTLY at the parent, at every point of the
            // orbit. That is what tidal lock means.
            #expect(abs(alignment - (-1)) < 1e-4)
        }

        // Negative control: feeding the orbit angle UNNEGATED — the bug that made
        // SOL-3-1 read as retrograde — sweeps the face right around instead.
        let unnegated = orbitAngles.map {
            simd_dot(featureWorldDirection(spin: $0), parentDirection(orbitAngle: $0))
        }
        #expect(unnegated.contains { abs($0 - unnegated[0]) > 0.5 })
    }

    @Test func lockedSpinPhaseOpposesTheOrbitAngle() {
        #expect(BodySpin.lockedSpinPhase(orbitAngle: 1.2) == -1.2)
        // As the orbit angle decreases with time, the locked spin phase must increase.
        #expect(BodySpin.lockedSpinPhase(orbitAngle: 0.2)
                > BodySpin.lockedSpinPhase(orbitAngle: 0.5))
    }

    @Test func reportedObliquityIsUnaffectedByTheRenderCap() {
        // `obliquityDeg` is what the scan said; `renderObliquityDeg` is what we draw.
        // Keeping them separate is what lets the dossier stay truthful.
        let uranus = BodySpin(tiltDeg: 97.77)
        #expect(abs(uranus.obliquityDeg - 97.77) < 1e-9)
        #expect(uranus.renderObliquityDeg != uranus.obliquityDeg)
    }
}

struct BodySpinPlaneTests {
    /// The live SOL values, which are the whole justification for the curve.
    @Test func compressionLeavesEverythingButExtremesAlone() {
        #expect(abs(BodySpin(tiltDeg: 3.13).renderObliquityDeg - 3.13) < 1e-6)    // Jupiter
        #expect(abs(BodySpin(tiltDeg: 26.73).renderObliquityDeg - 26.73) < 1e-6)  // Saturn
        #expect(abs(BodySpin(tiltDeg: 177.4).renderObliquityDeg - 177.4) < 1e-6)  // Venus
        #expect(abs(BodySpin(tiltDeg: 20.7).renderObliquityDeg - 20.7) < 1e-6)    // ALASII-4
    }

    @Test func extremeTiltsCompressToTheCap() {
        // SOL-7 Uranus: a true plane tilt of 82.23° would sit near-perpendicular to the
        // orbital plane and read edge-on at the camera's default 29° elevation.
        let uranus = BodySpin(tiltDeg: 97.77).renderObliquityDeg
        #expect(uranus > 90)                                   // still past 90 — see below
        #expect(abs((180 - uranus) - 38) < 1.0)                // plane tilt ≈ the cap
        // POLARISON-6: 66.1° with 59 moons, the worst combined case.
        let polarison = BodySpin(tiltDeg: 66.1).renderObliquityDeg
        #expect(polarison < 66.1 && polarison > 30)
    }

    /// The load-bearing invariant. `orrery-physical-fidelity` records that retrograde
    /// falls out of the pole tipping BELOW the orbital plane and that `sign` must not
    /// flip as well. Folding an obliquity past 90° down under it would put the pole back
    /// above the plane and silently turn a retrograde world prograde.
    @Test func compressionNeverCrossesNinetyDegrees() {
        for t in stride(from: 0.0, through: 180.0, by: 0.5) {
            let r = BodySpin(tiltDeg: t).renderObliquityDeg
            if t <= 90 { #expect(r <= 90, "θ=\(t) → \(r) crossed above 90") }
            else { #expect(r > 90, "θ=\(t) → \(r) crossed below 90") }
        }
    }

    @Test func retrogradePolesStillPointBelowThePlane() {
        #expect(BodySpin(tiltDeg: 97.77).pole(seed: 0.3).y < 0)
        #expect(BodySpin(tiltDeg: 177.4).pole(seed: 0.3).y < 0)
        #expect(BodySpin(tiltDeg: 26.73).pole(seed: 0.3).y > 0)
        // And the reported values — which the dossier label reads — are untouched.
        #expect(BodySpin(tiltDeg: 97.77).isRetrograde)
        #expect(abs(BodySpin(tiltDeg: 97.77).obliquityDeg - 97.77) < 1e-9)
    }

    @Test func capOfNinetyDisablesCompressionAndZeroFlattens() {
        let physical = BodySpin(tiltDeg: 97.77, tiltCapDeg: 90)
        #expect(abs(physical.renderObliquityDeg - 97.77) < 1e-6)
        let flat = BodySpin(tiltDeg: 97.77, tiltCapDeg: 0)
        #expect(abs(flat.renderObliquityDeg - 180) < 1e-6)   // pole straight down: flat plane
        #expect(abs(BodySpin(tiltDeg: 26.73, tiltCapDeg: 0).renderObliquityDeg) < 1e-6)
    }

    @Test func planeBasisIsRightHanded() {
        // Same hazard as `bodyFrameIsRightHanded`: a basis assembled from two cross
        // products has a 50% chance of being a reflection, which is invisible in a
        // still frame and makes motion run backwards.
        for tilt in [0.0, 26.73, 66.1, 97.77, 177.4] {
            let pole = BodySpin(tiltDeg: tilt).pole(seed: 0.42)
            let b = BodySpin.planeBasis(pole: pole)
            let det = simd_determinant(simd_float3x3(b.x, b.normal, b.z))
            #expect(abs(det - 1) < 1e-4, "tilt \(tilt) basis det = \(det)")
        }
    }

    @Test func planeBasisAgreesWithTheTexturingFrame() {
        // One construction, so the ring plane, the moon plane, and the surface frame
        // cannot disagree. `frame(seed:)` must delegate to `planeBasis`.
        let spin = BodySpin(tiltDeg: 66.1)
        let f = spin.frame(seed: 0.42)
        let b = BodySpin.planeBasis(pole: spin.pole(seed: 0.42))
        #expect(simd_distance(f.x, b.x) < 1e-5)
        #expect(simd_distance(f.pole, b.normal) < 1e-5)
        #expect(simd_distance(f.z, b.z) < 1e-5)
    }
}

struct RingSystemTests {
    @Test func onlyRingedBodiesGetARing() {
        #expect(PlanetMaterial.ringSystem(hasRings: false, type: .gasGiant, seed: 0.5) == nil)
        #expect(PlanetMaterial.ringSystem(hasRings: true, type: .gasGiant, seed: 0.5) != nil)
    }

    @Test func ringBandClearsTheBodyAndIsOrdered() throws {
        for type in [PlanetType.gasGiant, .iceGiant, .barren, .terrestrial] {
            let r = try #require(PlanetMaterial.ringSystem(hasRings: true, type: type, seed: 0.5))
            #expect(r.innerFrac > 1)              // never inside the body
            #expect(r.outerFrac > r.innerFrac)
            #expect(r.outerFrac <= 3)             // stays inside the pip/label budget
        }
    }

    @Test func ringSeedIsCarriedSoGapsAreStable() throws {
        let r = try #require(PlanetMaterial.ringSystem(hasRings: true, type: .gasGiant, seed: 0.375))
        #expect(r.seed == 0.375)
    }

    @Test func giantsGetBroaderRingsThanRockyWorlds() throws {
        let giant = try #require(PlanetMaterial.ringSystem(hasRings: true, type: .gasGiant, seed: 0.5))
        let rocky = try #require(PlanetMaterial.ringSystem(hasRings: true, type: .barren, seed: 0.5))
        #expect(giant.outerFrac - giant.innerFrac > rocky.outerFrac - rocky.innerFrac)
    }
}

// MARK: - Physical facts on the orrery model

struct OrreryPhysicalFactsTests {
    /// A scanned, ringed, tilted gas giant modelled on the live SOL-6.
    private func saturnLikeSystem() -> StarSystem {
        StarSystem(
            designation: "SOL",
            planets: [Planet(
                designation: "SOL-6", type: "Gas Giant", orbitalDistanceAu: 9.537,
                recon: .scanned,
                physical: BodyPhysical(
                    radiusEarth: 9.45, surfaceTempC: -139, rings: true,
                    rotationPeriodHours: 10.66, orbitalPeriodDays: 10747,
                    axialTiltDeg: 26.73))])
    }

    @Test func planetCarriesSpinAndRings() throws {
        let model = OrreryMapping.systemModel(from: saturnLikeSystem())
        let p = try #require(model.planets.first)
        #expect(p.spin.tiltDeg == 26.73)
        #expect(p.spin.rotationHours == 10.66)
        #expect(!p.spin.tidallyLocked)
        #expect(p.rings != nil)
        #expect(p.periodDays == 10747)
    }

    @Test func unringedPlanetHasNoRingSystem() throws {
        var system = saturnLikeSystem()
        system.planets[0].physical?.rings = false
        let model = OrreryMapping.systemModel(from: system)
        #expect(try #require(model.planets.first).rings == nil)
    }

    @Test func unscannedPlanetSpinsUpright() throws {
        var system = saturnLikeSystem()
        system.planets[0].physical = nil
        let model = OrreryMapping.systemModel(from: system)
        let p = try #require(model.planets.first)
        #expect(p.spin.obliquityDeg == 0)
        #expect(p.spin.rotationHours == nil)
        #expect(p.rings == nil)
    }

    @Test func moonCarriesTidalLockOceanAndDistance() throws {
        // Modelled on the live SOL-5-2 (Europa): locked, subsurface ocean, airless.
        let planet = Planet(
            designation: "SOL-5", type: "Gas Giant", orbitalDistanceAu: 5.203,
            recon: .scanned,
            physical: BodyPhysical(rings: false, rotationPeriodHours: 9.92,
                                   orbitalPeriodDays: 4331, axialTiltDeg: 3.13),
            moons: [Moon(
                designation: "SOL-5-2", type: "Icy", recon: .scanned,
                physical: BodyPhysical(
                    radiusEarth: 0.245, surfaceTempC: -160,
                    orbitalPeriodHours: 85.23, tidallyLocked: true,
                    orbitalDistanceKm: 671100,
                    hasSubsurfaceOcean: true, hasAtmosphere: false))])
        let model = OrreryMapping.bodyModel(planet: planet)
        let moon = try #require(model.planets.first)
        #expect(moon.spin.tidallyLocked)
        #expect(moon.hasSubsurfaceOcean)
        #expect(moon.orbitalDistanceKm == 671100)
        #expect(model.centralBody?.spin.tiltDeg == 3.13)
    }
}

// MARK: - Volcanism scale

struct VolcanismScaleTests {
    @Test func lavaAmountStaysBelowTheOldCeiling() {
        // Old range was 0.6 … 1.7; scaled down so a tag-stacked hellworld can't push
        // coverage past a crust-with-seams read.
        #expect(PlanetMaterial.lavaAmount(tempC: 400) <= 0.6)
        #expect(PlanetMaterial.lavaAmount(tempC: 2000) <= 1.5)
    }

    @Test func lavaAmountStillRisesWithTemperature() {
        let cool = PlanetMaterial.lavaAmount(tempC: 600)
        let mid = PlanetMaterial.lavaAmount(tempC: 1000)
        let hot = PlanetMaterial.lavaAmount(tempC: 1400)
        #expect(cool < mid)
        #expect(mid < hot)
    }

    @Test func hottestTaggedWorldStaysWithinTheShaderClamp() {
        // `hellworld` multiplies by 1.8 and the shader clamps lavaAmt to 1.8, so the
        // product must not sail so far past the clamp that temperature stops mattering.
        let mods = PlanetMaterial.modifiers(tags: ["hellworld", "volcanic"])
        let combined = mods.lava * PlanetMaterial.lavaAmount(tempC: 1400)
        #expect(combined <= 2.8)
    }
}

// MARK: - Ring draw list

struct RingDrawListTests {
    @Test func onlyRingedBodiesEnterTheDrawList() {
        // SOL-5 reports rings: false, SOL-6 reports true — both live values.
        let system = StarSystem(
            designation: "SOL",
            planets: [
                Planet(designation: "SOL-5", type: "Gas Giant", orbitalDistanceAu: 5.203,
                       recon: .scanned,
                       physical: BodyPhysical(rings: false, axialTiltDeg: 3.13)),
                Planet(designation: "SOL-6", type: "Gas Giant", orbitalDistanceAu: 9.537,
                       recon: .scanned,
                       physical: BodyPhysical(rings: true, axialTiltDeg: 26.73)),
            ])
        let model = OrreryMapping.systemModel(from: system)
        let ringed = model.planets.filter { $0.rings != nil }.map(\.designation)
        #expect(ringed == ["SOL-6"])
    }

    @Test func ringWorldRadiiScaleWithTheBody() throws {
        let r = try #require(PlanetMaterial.ringSystem(hasRings: true, type: .gasGiant, seed: 0.5))
        let bodyRadius: Float = 2.0
        #expect(r.innerFrac * bodyRadius > bodyRadius)          // clears the limb
        #expect(r.outerFrac * bodyRadius > r.innerFrac * bodyRadius)
    }
}

// MARK: - Moon orbit fidelity

struct MoonOrbitFidelityTests {
    /// Modelled on the live SOL-5 and two of its moons.
    private func jupiterLike() -> Planet {
        Planet(
            designation: "SOL-5", type: "Gas Giant", orbitalDistanceAu: 5.203,
            recon: .scanned,
            physical: BodyPhysical(rings: false, rotationPeriodHours: 9.92,
                                   orbitalPeriodDays: 4331, axialTiltDeg: 3.13),
            moons: [
                // Io: nearest and fastest.
                Moon(designation: "SOL-5-1", type: "Volcanic", recon: .scanned,
                     physical: BodyPhysical(radiusEarth: 0.286, orbitalPeriodHours: 42.46,
                                            tidallyLocked: true, orbitalDistanceKm: 421700,
                                            hasSubsurfaceOcean: false, hasAtmosphere: false)),
                // Europa: farther and slower.
                Moon(designation: "SOL-5-2", type: "Icy", recon: .scanned,
                     physical: BodyPhysical(radiusEarth: 0.245, orbitalPeriodHours: 85.23,
                                            tidallyLocked: true, orbitalDistanceKm: 671100,
                                            hasSubsurfaceOcean: true, hasAtmosphere: false)),
            ])
    }

    @Test func moonPeriodComesFromHours() throws {
        let model = OrreryMapping.bodyModel(planet: jupiterLike())
        let io = try #require(model.planets.first { $0.designation == "SOL-5-1" })
        let europa = try #require(model.planets.first { $0.designation == "SOL-5-2" })
        #expect(abs(io.periodDays - 42.46 / 24) < 1e-9)
        #expect(abs(europa.periodDays - 85.23 / 24) < 1e-9)
        #expect(io.periodDays < europa.periodDays)     // the nearer moon is faster
    }

    @Test func moonOrbitsOrderByRealDistanceAndNeverOverlap() throws {
        let model = OrreryMapping.bodyModel(planet: jupiterLike())
        let io = try #require(model.planets.first { $0.designation == "SOL-5-1" })
        let europa = try #require(model.planets.first { $0.designation == "SOL-5-2" })
        #expect(io.semiMajorScene < europa.semiMajorScene)
        // Both clear the central body, and each other.
        let central = try #require(model.centralBody).displayRadius
        #expect(io.semiMajorScene - io.displayRadius > central)
        #expect(europa.semiMajorScene - europa.displayRadius
                > io.semiMajorScene + io.displayRadius)
    }

    @Test func moonsWithoutDistanceKeepTheIndexFallback() throws {
        var planet = jupiterLike()
        planet.moons[0].physical?.orbitalDistanceKm = nil
        planet.moons[1].physical?.orbitalDistanceKm = nil
        let model = OrreryMapping.bodyModel(planet: planet)
        let radii = model.planets.map(\.semiMajorScene)
        #expect(radii.count == 2)
        #expect(radii[0] < radii[1])       // still ordered, still non-overlapping
    }

    @Test func moonSceneRadiusIsMonotonicAndCompressed() {
        let near = OrreryMapping.moonSceneRadius(km: 421_700)
        let far = OrreryMapping.moonSceneRadius(km: 1_221_870)
        #expect(near < far)
        // sqrt compression: tripling the distance must not triple the radius.
        #expect(far / near < 3)
    }

    @Test func moonAtmosphereComesFromTheBoolean() throws {
        // SOL-6-1 (Titan): has_atmosphere true plus a thick_atmosphere tag.
        let planet = Planet(
            designation: "SOL-6", type: "Gas Giant", orbitalDistanceAu: 9.537,
            recon: .scanned,
            physical: BodyPhysical(rings: true, axialTiltDeg: 26.73),
            moons: [
                Moon(designation: "SOL-6-1", type: "Icy", recon: .scanned,
                     physical: BodyPhysical(orbitalPeriodHours: 382.69,
                                            tags: ["thick_atmosphere"], tidallyLocked: true,
                                            orbitalDistanceKm: 1221870,
                                            hasSubsurfaceOcean: false, hasAtmosphere: true)),
                Moon(designation: "SOL-6-9", type: "Rocky", recon: .scanned,
                     physical: BodyPhysical(orbitalPeriodHours: 1000, tidallyLocked: true,
                                            orbitalDistanceKm: 12952000,
                                            hasSubsurfaceOcean: false, hasAtmosphere: false)),
            ])
        let model = OrreryMapping.bodyModel(planet: planet)
        let titan = try #require(model.planets.first { $0.designation == "SOL-6-1" })
        let airless = try #require(model.planets.first { $0.designation == "SOL-6-9" })
        #expect(titan.atmosphere != .unknown)
        #expect(titan.atmosphere != .none)
        // A scanned moon that reports no air is airless, not merely unknown — the
        // difference decides whether a halo is drawn at all.
        #expect(airless.atmosphere == .none)
    }

    @Test func unscannedMoonAtmosphereStaysUnknown() throws {
        let planet = Planet(
            designation: "SOL-4", type: "Desert World", orbitalDistanceAu: 1.52,
            recon: .scanned,
            moons: [Moon(designation: "SOL-4-1", type: "Rocky", recon: .visited)])
        let model = OrreryMapping.bodyModel(planet: planet)
        let moon = try #require(model.planets.first)
        #expect(moon.atmosphere == .unknown)
    }

    @Test func subsurfaceOceanBecomesASurfaceModifier() {
        let plain = PlanetMaterial.surface(for: .frozen, lifeStage: nil, estimated: false)
        #expect(plain.mods.ocean == 0)
        let ocean = PlanetMaterial.surface(for: .frozen, lifeStage: nil, estimated: false,
                                           hasSubsurfaceOcean: true)
        #expect(ocean.mods.ocean > 0)
    }
}

// MARK: - Camera translation (body-level orbit tracking)

struct CameraTranslationTests {
    @Test func translateMovesTargetAndEyeTogether() {
        var cam = TurntableCamera()
        cam.target = SIMD3(1, 2, 3)
        let eyeBefore = cam.eye
        let delta = SIMD3<Float>(0.5, 0, -0.25)
        cam.translate(by: delta)
        #expect(simd_length(cam.target - SIMD3<Float>(1.5, 2, 2.75)) < 1e-6)
        // The eye rides along, so the view does not swing.
        #expect(simd_length((cam.eye - eyeBefore) - delta) < 1e-4)
    }

    @Test func translateCarriesAnInFlightFraming() {
        var cam = TurntableCamera()
        cam.target = .zero
        cam.dive(on: SIMD3(10, 0, 0), radius: 5, now: 0, duration: 1)
        cam.translate(by: SIMD3(0, 0, 2))
        // Once the dive lands, it must sit on the MOVED body — otherwise a drill-in
        // toward an orbiting planet would arrive where the planet used to be.
        _ = cam.step(now: 1.0)
        #expect(simd_length(cam.target - SIMD3<Float>(10, 0, 2)) < 1e-4)
    }

    @Test func translateByZeroIsInert() {
        var cam = TurntableCamera()
        cam.target = SIMD3(4, 5, 6)
        let before = cam.eye
        cam.translate(by: .zero)
        #expect(simd_length(cam.eye - before) < 1e-6)
        #expect(simd_length(cam.target - SIMD3<Float>(4, 5, 6)) < 1e-6)
    }
}

// MARK: - Dossier fact formatting

struct BodyFactFormatTests {
    @Test func rotationSwitchesFromHoursToDays() {
        // SOL-6 turns in 10.66 h — hours read naturally.
        #expect(BodyFactFormat.hours(10.66) == "10.7 h")
        // SOL-2 takes 5832.5 h; "5832 h" is unreadable, "243 d" is not.
        #expect(BodyFactFormat.hours(5832.5) == "243 d")
        #expect(BodyFactFormat.hours(47.9).hasSuffix(" h"))
        #expect(BodyFactFormat.hours(48).hasSuffix(" d"))
    }

    @Test func orbitalPeriodSwitchesFromDaysToYears() {
        #expect(BodyFactFormat.days(224.7) == "224.7 d")       // SOL-2
        #expect(BodyFactFormat.days(10747).hasSuffix(" y"))     // SOL-6
        #expect(BodyFactFormat.days(30589).hasSuffix(" y"))     // SOL-7
        #expect(BodyFactFormat.days(899.9).hasSuffix(" d"))
        #expect(BodyFactFormat.days(900).hasSuffix(" y"))
    }

    @Test func moonDistanceSwitchesToMillions() {
        #expect(BodyFactFormat.km(384_400) == "384400 km")      // SOL-3-1
        #expect(BodyFactFormat.km(1_221_870) == "1.22 M km")    // SOL-6-1
        #expect(BodyFactFormat.km(999_999).hasSuffix(" km"))
        #expect(BodyFactFormat.km(1_000_000).hasSuffix("M km"))
    }

    @Test func unscannedAtmosphereHasNoLabel() {
        // An unscanned body must show NO atmosphere row, not the word "Unknown".
        #expect(Atmosphere.unknown.label == nil)
        #expect(Atmosphere.none.label == "None")
        #expect(Atmosphere.crushing.label == "Crushing")
    }
}

// MARK: - Ring clearance (rings claim space from neighbours and moons)

struct RingClearanceTests {
    private func giant(_ id: String, au: Double, rings: Bool, radiusEarth: Double = 9.45) -> Planet {
        Planet(designation: id, type: "Gas Giant", orbitalDistanceAu: au, recon: .scanned,
               physical: BodyPhysical(radiusEarth: radiusEarth, rings: rings, axialTiltDeg: 26.73))
    }

    @Test func aRingedPlanetPushesItsNeighbourClearOfTheRings() throws {
        // Two identical adjacent giants; only the inner one is ringed. Its rings must
        // not reach the outer planet's orbit.
        func gapAfterInner(ringed: Bool) throws -> (gap: Double, ringOuter: Double) {
            let m = OrreryMapping.systemModel(from: StarSystem(
                designation: "RNG",
                planets: [giant("RNG-1", au: 5.0, rings: ringed),
                          giant("RNG-2", au: 6.0, rings: false)]))
            let inner = try #require(m.planets.first { $0.id == "RNG-1" })
            let outer = try #require(m.planets.first { $0.id == "RNG-2" })
            let ringOuter = inner.displayRadius * Double(inner.rings?.outerFrac ?? 1)
            return (outer.semiMajorScene - outer.displayRadius - inner.semiMajorScene, ringOuter)
        }

        let ringed = try gapAfterInner(ringed: true)
        // The outer planet's inner edge must sit beyond the inner planet's ring edge.
        #expect(ringed.gap > ringed.ringOuter)
        // And a ringed planet genuinely claims MORE room than the same planet unringed.
        let plain = try gapAfterInner(ringed: false)
        #expect(ringed.gap > plain.gap)
    }

    @Test func unringedSystemLayoutIsUnchanged() throws {
        // Regression guard: clearance == displayRadius when there are no rings, so an
        // ordinary system must space exactly as it did before rings existed.
        let system = StarSystem(
            designation: "PLAIN",
            planets: [giant("PLAIN-1", au: 0.4, rings: false),
                      giant("PLAIN-2", au: 0.5, rings: false),
                      giant("PLAIN-3", au: 0.6, rings: false)])
        let m = OrreryMapping.systemModel(from: system)
        // Still strictly ordered and non-overlapping.
        for (a, b) in zip(m.planets, m.planets.dropFirst()) {
            #expect(b.semiMajorScene - b.displayRadius > a.semiMajorScene + a.displayRadius)
        }
        #expect(m.planets.allSatisfy { $0.rings == nil })
    }

    @Test func moonsClearTheCentralPlanetsRings() throws {
        func innerMoonGap(rings: Bool) throws -> (clearance: Double, ringOuter: Double) {
            var p = giant("RNG-1", au: 9.5, rings: rings)
            p.moons = [Moon(designation: "RNG-1-1", type: "Rocky", recon: .scanned,
                            physical: BodyPhysical(radiusEarth: 0.27, orbitalPeriodHours: 40,
                                                   tidallyLocked: true, orbitalDistanceKm: 180_000))]
            let m = OrreryMapping.bodyModel(planet: p)
            let central = try #require(m.centralBody)
            let moon = try #require(m.planets.first)
            let ringOuter = central.displayRadius * Double(central.rings?.outerFrac ?? 1)
            return (moon.semiMajorScene - moon.displayRadius, ringOuter)
        }

        // Ringed: the innermost moon's inner edge clears the ring's outer edge.
        let ringed = try innerMoonGap(rings: true)
        #expect(ringed.clearance > ringed.ringOuter)
        // And it is pushed further out than it would be around an unringed planet.
        let plain = try innerMoonGap(rings: false)
        #expect(ringed.clearance > plain.clearance)
    }

    @Test func unringedMoonBaseOrbitIsUnchanged() throws {
        // The gap beyond the limb stays proportional to the BODY, so an unringed
        // planet keeps its historical centralScene * 1.7 first-moon distance.
        var p = giant("PLAIN-1", au: 5.2, rings: false)
        p.moons = [Moon(designation: "PLAIN-1-1", type: "Rocky", recon: .visited)]
        let m = OrreryMapping.bodyModel(planet: p)
        let central = try #require(m.centralBody).displayRadius
        let moon = try #require(m.planets.first)
        #expect(abs(moon.semiMajorScene - central * 1.7) < 1e-9)
    }

    @Test func frameNeverClipsARingedPlanetsRings() throws {
        // A ringed planet with no moons at all must still be framed outside its rings.
        let m = OrreryMapping.bodyModel(planet: giant("RNG-1", au: 9.5, rings: true))
        let central = try #require(m.centralBody)
        let ringOuter = central.displayRadius * Double(central.rings?.outerFrac ?? 1)
        #expect(m.frameScene > ringOuter)
    }

    @Test func systemFrameEnclosesAnOutermostRingedPlanet() throws {
        let m = OrreryMapping.systemModel(from: StarSystem(
            designation: "RNG", planets: [giant("RNG-1", au: 9.5, rings: true)]))
        let p = try #require(m.planets.first)
        let ringOuter = p.semiMajorScene + p.displayRadius * Double(p.rings?.outerFrac ?? 1)
        #expect(m.frameScene >= ringOuter)
    }

    @Test func clearanceRadiusIsTheRingOuterEdge() {
        #expect(OrreryMapping.clearanceRadius(3, nil) == 3)
        let ring = RingSystem(innerFrac: 1.35, outerFrac: 2.3, seed: 0.5, tint: .zero)
        // Tolerance is Float-sized: outerFrac is a Float (2.3 stores as 2.29999995),
        // so the widened product lands ~1.4e-7 off the decimal value.
        #expect(abs(OrreryMapping.clearanceRadius(3, ring) - 6.9) < 1e-6)
    }
}

struct MoonTieringTests {
    /// A moon with no physical block and nothing interesting — the common case.
    private func plain(_ n: Int) -> Moon { Moon(designation: "P-6-\(n)", recon: .visited) }

    private func sized(_ n: Int, _ radiusEarth: Double) -> Moon {
        Moon(designation: "P-6-\(n)", recon: .scanned,
             physical: BodyPhysical(radiusEarth: radiusEarth))
    }

    @Test func smallRostersPromoteEveryMoon() {
        for count in 0...8 {
            let moons = (0..<count).map(plain)
            let t = MoonTiering.split(moons)
            #expect(t.promoted.count == count)
            #expect(t.swarm.isEmpty)
        }
    }

    @Test func largeRosterWithNoSizeDataPromotesTheInnermostFew() {
        // POLARISON-6: 59 moons, zero physical blocks. Promoting NOTHING here — the
        // original rule — renders the planet plus a dot cloud with not one lit moon,
        // which is what SAFANA-7 (21 moons, zero physical) actually did on live data.
        // With no radii we cannot know which moons are biggest, but index order IS
        // orbital order, so the innermost `topBySize` promote.
        let moons = (0..<59).map(plain)
        let t = MoonTiering.split(moons)
        #expect(t.promoted.map(\.designation) == ["P-6-0", "P-6-1", "P-6-2", "P-6-3"])
        #expect(t.swarm.count == 55)
        #expect(t.promoted.count + t.swarm.count == 59)
    }

    @Test func rosterJustOverTheThresholdWithNoSizeDataStillLightsSomeMoons() {
        // The boundary: 9 moons is one past `promoteAllAtOrBelow`, so the swarm engages
        // for the first time. It must not engage for the WHOLE roster — a planet does
        // not go from nine sphere moons to nine dots because it gained a tenth.
        let moons = (0..<9).map(plain)
        let t = MoonTiering.split(moons)
        #expect(t.promoted.map(\.designation) == ["P-6-0", "P-6-1", "P-6-2", "P-6-3"])
        #expect(t.swarm.count == 5)
        #expect(t.promoted.count + t.swarm.count == 9)
    }

    @Test func onePartlyMeasuredRosterStillRanksBySizeNotOrder() {
        // ALASII-4's shape: 48 moons, exactly one measured. Size data existing at all
        // means we DO know something, so the roster-order fallback must stay off — the
        // one measured moon promotes and nothing else does on size.
        let moons = [sized(0, 0.3)] + (1..<48).map(plain)
        let t = MoonTiering.split(moons)
        #expect(t.promoted.map(\.designation) == ["P-6-0"])
        #expect(t.swarm.count == 47)
    }

    @Test func interestingMoonsAlwaysPromote() {
        // 30 moons hosting a device, plus 30 dull ones. Every device-bearing moon must
        // promote: a device must never lack an exact anchor.
        let interesting = (0..<30).map { i in
            Moon(designation: "P-6-i\(i)", recon: .scanned,
                 devices: [LocatedDevice(deviceCode: "D\(i)", deviceType: "mining_drone")])
        }
        let dull = (0..<30).map { Moon(designation: "P-6-d\($0)", recon: .visited) }
        let t = MoonTiering.split(interesting + dull)
        #expect(t.promoted.count == 30)
        #expect(t.promoted.allSatisfy { !$0.devices.isEmpty })
        #expect(t.swarm.count == 30)
        // The safety invariant the whole design rests on.
        #expect(t.swarm.allSatisfy { !OrreryMapping.moonIsInteresting($0) })
    }

    @Test func sizePromotionTakesTopKAboveTheRelativeFloor() {
        // Largest is 0.40 R⊕, floor is 0.5× that = 0.20. Only the three at/above 0.20
        // qualify, even though topBySize allows four.
        let moons = [sized(1, 0.40), sized(2, 0.30), sized(3, 0.22),
                     sized(4, 0.12), sized(5, 0.05)] + (6..<40).map(plain)
        let t = MoonTiering.split(moons)
        #expect(t.promoted.count == 3)
        #expect(Set(t.promoted.map(\.designation)) == ["P-6-1", "P-6-2", "P-6-3"])
    }

    @Test func uniformlySizedRosterPromotesNoMoreThanTopK() {
        // 40 moons all the same radius: every one clears the relative floor, so the
        // topBySize cap is what stops this promoting all 40.
        let moons = (0..<40).map { sized($0, 0.25) }
        let t = MoonTiering.split(moons)
        #expect(t.promoted.count == 4)
        #expect(t.swarm.count == 36)
    }

    @Test func splitIsAPartitionAndPreservesInputOrder() {
        let moons = (0..<20).map(plain) + [sized(99, 0.5)]
        let t = MoonTiering.split(moons)
        #expect(t.promoted.count + t.swarm.count == moons.count)
        let all = Set(t.promoted.map(\.designation)).union(t.swarm.map(\.designation))
        #expect(all == Set(moons.map(\.designation)))
        // Each side keeps the roster's relative order (callers rely on it for stable
        // index-anchored placement).
        #expect(t.swarm.map(\.designation) == moons.map(\.designation).filter { d in
            t.swarm.contains { $0.designation == d }
        })
    }
}

struct MoonSwarmLayoutTests {
    private func roster(_ count: Int, prefix: String = "POLARISON-6") -> [Moon] {
        (0..<count).map { Moon(designation: "\(prefix)-\($0 + 1)", recon: .visited) }
    }

    private func planet(_ moons: [Moon], designation: String = "POLARISON-6") -> Planet {
        Planet(designation: designation, type: "Gas Giant", orbitalDistanceAu: 6,
               recon: .scanned, moons: moons)
    }

    @Test func everyMoonIsRepresented() {
        // The old `maxMoons` cap dropped 35 of 59 moons entirely. Nothing is dropped now.
        let m = OrreryMapping.bodyModel(planet: planet(roster(59)))
        #expect(m.planets.count + m.swarm.count == 59)
        // No size data anywhere, so the innermost four promote on roster order (which is
        // orbital order) and the remaining 55 swarm. Every one is still represented.
        #expect(m.planets.count == 4)
        #expect(m.swarm.count == 55)
    }

    @Test func frameSceneIsFlatInMoonCount() {
        // The core regression. Before this work, 59 moons pushed `frameScene` to ~91
        // scene units against ~15 for 8 moons, shrinking the drilled planet to a dot.
        let small = OrreryMapping.bodyModel(planet: planet(roster(8), designation: "SOL-6"))
        let huge = OrreryMapping.bodyModel(planet: planet(roster(59)))
        #expect(huge.frameScene < small.frameScene * 2)
        // And the central body keeps real presence at 59 moons.
        let central = try! #require(huge.centralBody).displayRadius
        #expect(central / huge.frameScene > 0.10)
    }

    @Test func smallRosterKeepsEveryMoonAsAnOrbiter() {
        let m = OrreryMapping.bodyModel(planet: planet(roster(8), designation: "SOL-6"))
        #expect(m.planets.count == 8)
        #expect(m.swarm.isEmpty)
    }

    @Test func swarmClearsThePlanetAndThePromotedMoons() {
        // One moon hosting a device promotes; the rest swarm outside it.
        var moons = roster(40)
        moons[0] = Moon(designation: "POLARISON-6-1", recon: .scanned,
                        devices: [LocatedDevice(deviceCode: "D1", deviceType: "mining_drone")])
        let m = OrreryMapping.bodyModel(planet: planet(moons))
        let promoted = try! #require(m.planets.first)
        let promotedOuter = promoted.semiMajorScene + promoted.displayRadius
        let central = try! #require(m.centralBody).displayRadius
        #expect(m.swarm.allSatisfy { $0.orbitScene > promotedOuter })
        #expect(m.swarm.allSatisfy { $0.orbitScene > central })
    }

    @Test func bandEdgesIgnoreMemberPositions() {
        // The stability rule: band extent comes from roster size + budget, never from
        // where its members sit. So one moon gaining a real orbital distance must not
        // move the band — only itself.
        let before = OrreryMapping.bodyModel(planet: planet(roster(40)))
        var moons = roster(40)
        moons[7] = Moon(designation: "POLARISON-6-8", recon: .scanned,
                        physical: BodyPhysical(orbitalDistanceKm: 2_000_000))
        let after = OrreryMapping.bodyModel(planet: planet(moons))

        #expect(before.swarm.count == after.swarm.count)
        #expect(abs(before.frameScene - after.frameScene) < 1e-9)
        let movedID = "POLARISON-6-8"
        for (b, a) in zip(before.swarm, after.swarm) where b.designation != movedID {
            #expect(abs(b.orbitScene - a.orbitScene) < 1e-9, "\(b.designation) moved")
            #expect(abs(b.offsetScene - a.offsetScene) < 1e-9)
        }
        let moved = try! #require(after.swarm.first { $0.designation == movedID })
        let wasAt = try! #require(before.swarm.first { $0.designation == movedID })
        #expect(moved.orbitScene != wasAt.orbitScene)
    }

    @Test func swarmPlacementIsDeterministic() {
        let a = OrreryMapping.bodyModel(planet: planet(roster(30)))
        let b = OrreryMapping.bodyModel(planet: planet(roster(30)))
        #expect(a.swarm == b.swarm)
    }

    @Test func realDistancesOrderTheBandAndKeepFamilyGaps() {
        // SOL-5's real roster: 4 Galileans, 3 inner moons, 5 far irregulars. The gap
        // between the inner cluster (≤1.9e6 km) and the outer one (≥7.1e6 km) must
        // survive into the band, with nothing clustering code.
        let km: [Double] = [421_700, 671_100, 1_070_400, 1_882_700, 181_400, 128_000,
                            221_900, 11_461_000, 11_741_000, 7_154_000, 7_284_000, 23_624_000]
        let moons = km.enumerated().map { i, d in
            Moon(designation: "SOL-5-\(i + 1)", recon: .scanned,
                 physical: BodyPhysical(orbitalDistanceKm: d))
        }
        // Exceeding the promote-all threshold with no radii puts everything but the
        // innermost four (by roster order) into the swarm.
        let m = OrreryMapping.bodyModel(planet: planet(moons, designation: "SOL-5"))
        #expect(m.planets.count == 4)
        #expect(m.swarm.count == 8)
        func orbit(_ n: Int) -> Double {
            m.swarm.first { $0.designation == "SOL-5-\(n)" }!.orbitScene
        }
        // Radial order follows real distance, not designation order.
        #expect(orbit(6) < orbit(5))          // 128,000 km inside 181,400 km
        #expect(orbit(7) < orbit(10))         // 221,900 km inside 7.15e6 km
        // The family gap is wider than any gap inside the inner cluster.
        let innerSpan = orbit(5) - orbit(6)
        #expect(orbit(10) - orbit(5) > innerSpan)
    }

    @Test func swarmSeparatesMeasuredFactsFromRenderFallbacks() throws {
        // A swarm member's `periodDays` is a Kepler-ish guess off a SYNTHESIZED band
        // radius when nothing was reported, so the dossier cannot read it. The measured
        // numbers travel separately, and are nil exactly when the scan stayed silent.
        // (Index 6, so the roster-order promotion of the innermost four leaves it in
        // the swarm.)
        var moons = roster(12)
        moons[6] = Moon(designation: "POLARISON-6-7", recon: .scanned,
                        physical: BodyPhysical(orbitalPeriodHours: 96,
                                               orbitalDistanceKm: 1_070_400))
        let m = OrreryMapping.bodyModel(planet: planet(moons))

        let measured = try #require(m.swarm.first { $0.designation == "POLARISON-6-7" })
        #expect(measured.orbitalDistanceKm == 1_070_400)
        #expect(measured.reportedPeriodDays == 96.0 / 24)
        #expect(measured.periodDays == 96.0 / 24)          // render value tracks the fact

        let silent = try #require(m.swarm.first { $0.designation == "POLARISON-6-9" })
        #expect(silent.orbitalDistanceKm == nil)
        #expect(silent.reportedPeriodDays == nil)
        #expect(silent.periodDays > 0)                     // …but the band still animates
    }

    @Test func promotedMoonsSeparateReportedPeriodsFromTheIndexLadder() throws {
        var moons = roster(12)
        moons[0] = Moon(designation: "POLARISON-6-1", recon: .scanned,
                        physical: BodyPhysical(orbitalPeriodHours: 42))
        let m = OrreryMapping.bodyModel(planet: planet(moons))
        let reported = try #require(m.planets.first { $0.designation == "POLARISON-6-1" })
        #expect(reported.reportedPeriodDays == 42.0 / 24)
        let ladder = try #require(m.planets.first { $0.designation == "POLARISON-6-2" })
        #expect(ladder.reportedPeriodDays == nil)
        #expect(ladder.periodDays > 0)
    }

    @Test func capturedAsteroidsScatterWiderThanRegularMoons() {
        let regular = (0..<30).map { Moon(designation: "R-1-\($0)", type: "Icy", recon: .visited) }
        let captured = (0..<30).map { Moon(designation: "R-2-\($0)", type: "Captured Asteroid", recon: .visited) }
        let a = OrreryMapping.bodyModel(planet: planet(regular, designation: "R-1"))
        let b = OrreryMapping.bodyModel(planet: planet(captured, designation: "R-2"))
        func spread(_ s: [SwarmMoon]) -> Double { s.map { abs($0.offsetScene) }.max() ?? 0 }
        #expect(spread(b.swarm) > spread(a.swarm))
        #expect(b.swarm.allSatisfy { $0.isCapturedAsteroid })
        #expect(a.swarm.allSatisfy { !$0.isCapturedAsteroid })
    }
}

struct SwarmLayoutTests {
    private func swarmMoon(_ id: String, orbit: Double, offset: Double,
                           period: Double, phase: Double) -> SwarmMoon {
        SwarmMoon(designation: id, name: nil, type: "Icy", orbitScene: orbit,
                  offsetScene: offset, periodDays: period, phase0Deg: phase,
                  displayRadius: 0.2, colorHex: "#cdd6e6", scanned: false,
                  isCapturedAsteroid: false)
    }

    private func model(swarm: [SwarmMoon], planets: [OrreryPlanet] = []) -> SystemModel {
        SystemModel(
            star: StarDetail(designation: "SOL-5", name: nil, spectralType: nil, color: nil,
                             position: Position(x: 0, y: 0, z: 0), temperatureK: nil,
                             massSolar: nil, luminositySolar: nil, ageMy: nil,
                             habitableZone: nil, miningBonusPct: nil),
            hzInnerScene: nil, hzOuterScene: nil, planets: planets, swarm: swarm,
            belts: [], hazards: [], kuiperScene: nil, frameScene: 20,
            deviceCount: 0, vesselCount: 0)
    }

    @Test func swarmMemberSitsAtItsRadiusAndVerticalOffset() {
        let m = swarmMoon("SOL-5-9", orbit: 10, offset: 1.5, period: 8, phase: 0)
        let layout = OrreryLayout(model: model(swarm: [m]), center: .zero, scale: 1,
                                  reveal: 1, time: 0)
        let p = layout.swarmPosition(m)
        #expect(abs(p.y - 1.5) < 1e-5)
        #expect(abs(simd_length(SIMD2(p.x, p.z)) - 10) < 1e-4)
    }

    @Test func swarmRevealIsAppliedExactlyOnceAndLinearly() {
        // Reveal must scale the band LINEARLY, because that is what keeps it in lockstep
        // with the promoted moons and their orbit rings (`orbiterPosition` is likewise
        // `semiMajorScene * scale * reveal`). Squaring it — which happens if a caller
        // bakes reveal in here AND lets `orrery_swarm_vertex` apply it again — parks the
        // band at 25% of its radius while the rings sit at 50%, so the cloud stays
        // bunched against the planet and then snaps outward. Invisible at rest (1² = 1),
        // which is exactly why this needs pinning.
        let m = swarmMoon("SOL-5-9", orbit: 10, offset: 2, period: 8, phase: 0)
        func at(_ reveal: Float) -> SIMD3<Float> {
            OrreryLayout(model: model(swarm: [m]), center: .zero, scale: 1,
                         reveal: reveal, time: 0).swarmPosition(m)
        }
        let half = at(0.5)
        #expect(abs(simd_length(SIMD2(half.x, half.z)) - 5) < 1e-4)   // 5, never 2.5
        #expect(abs(half.y - 1) < 1e-4)                               // 1, never 0.5
        let full = at(1)
        #expect(abs(simd_length(SIMD2(full.x, full.z)) - 10) < 1e-4)
        #expect(abs(full.y - 2) < 1e-4)
    }

    @Test func swarmMemberOrbitsOverTime() {
        let m = swarmMoon("SOL-5-9", orbit: 10, offset: 0, period: 8, phase: 0)
        let at0 = OrreryLayout(model: model(swarm: [m]), center: .zero, scale: 1,
                               reveal: 1, time: 0).swarmPosition(m)
        let at30 = OrreryLayout(model: model(swarm: [m]), center: .zero, scale: 1,
                                reveal: 1, time: 30).swarmPosition(m)
        #expect(simd_distance(at0, at30) > 0.1)
        // Radius is preserved — it orbits, it does not drift.
        #expect(abs(simd_length(SIMD2(at0.x, at0.z)) - simd_length(SIMD2(at30.x, at30.z))) < 1e-4)
    }

    @Test func revealCollapsesTheSwarmIntoTheCentre() {
        // The swarm must emerge from the centre on drill-in exactly as orbiters do,
        // vertical offset included, or the band pops in instead of growing out.
        let m = swarmMoon("SOL-5-9", orbit: 10, offset: 2, period: 8, phase: 0)
        let layout = OrreryLayout(model: model(swarm: [m]), center: SIMD3(5, 0, 5),
                                  scale: 1, reveal: 0, time: 0)
        #expect(simd_distance(layout.swarmPosition(m), SIMD3(5, 0, 5)) < 1e-5)
    }

    @Test func timingAnchorFoldsInTheSwarm() {
        // `minPeriodDays` anchors every on-screen period. If it ignored the swarm, a
        // swarm faster than any promoted moon would be timed against a different
        // anchor than its neighbours and the two populations would visibly disagree.
        let fast = swarmMoon("SOL-5-9", orbit: 10, offset: 0, period: 1, phase: 0)
        let slowPlanet = OrreryPlanet(
            designation: "SOL-5-1", name: nil, type: "Icy", planetType: .frozen,
            estimated: false, tags: [], surfaceTempC: nil, atmosphere: .unknown,
            appearanceSeed: 0.5, orbitalDistanceAu: 0, inHabitableZone: false,
            scanned: true, moonCount: 0, lifeStage: nil, inventory: [],
            semiMajorScene: 5, periodDays: 40, phase0Deg: 0, displayRadius: 0.3,
            colorHex: "#cdd6e6", indicators: [], hasInterestingMoon: false, moons: [])
        let layout = OrreryLayout(model: model(swarm: [fast], planets: [slowPlanet]),
                                  center: .zero, scale: 1, reveal: 1, time: 0)
        #expect(layout.minPeriodDays == 1)
    }
}

struct SwarmGeometryTests {
    private func bodyModelWithSwarm() -> SystemModel {
        let moons = (0..<40).map { Moon(designation: "POLARISON-6-\($0 + 1)", recon: .visited) }
        return OrreryMapping.bodyModel(planet:
            Planet(designation: "POLARISON-6", type: "Gas Giant", orbitalDistanceAu: 6,
                   recon: .scanned, moons: moons))
    }

    @Test func swarmPointsAreOnePerMemberAndTinted() {
        let model = bodyModelWithSwarm()
        let layout = OrreryLayout(model: model, center: .zero, scale: 1, reveal: 1, time: 0)
        let pts = OrreryGeometry.swarmPoints(layout: layout)
        #expect(pts.count == model.swarm.count)
        #expect(pts.allSatisfy { $0.positionSize.w > 0 })
        #expect(pts.allSatisfy { simd_length($0.color.xyz) > 0 })
    }

    @Test func swarmPointsTrackTheLayoutCentreAndScale() {
        let model = bodyModelWithSwarm()
        let here = OrreryGeometry.swarmPoints(
            layout: OrreryLayout(model: model, center: .zero, scale: 1, reveal: 1, time: 0))
        let there = OrreryGeometry.swarmPoints(
            layout: OrreryLayout(model: model, center: SIMD3(100, 0, 0), scale: 1,
                                 reveal: 1, time: 0))
        for (a, b) in zip(here, there) {
            #expect(abs((b.positionSize.x - a.positionSize.x) - 100) < 1e-3)
        }
    }

    @Test func swarmPointsAreEmptyWithoutASwarm() {
        // A system-level model has no swarm, so the pass costs nothing there.
        let model = SystemModel(
            star: StarDetail(designation: "SOL", name: nil, spectralType: nil, color: nil,
                             position: Position(x: 0, y: 0, z: 0), temperatureK: nil,
                             massSolar: nil, luminositySolar: nil, ageMy: nil,
                             habitableZone: nil, miningBonusPct: nil),
            hzInnerScene: nil, hzOuterScene: nil, planets: [], belts: [], hazards: [],
            kuiperScene: nil, frameScene: 20, deviceCount: 0, vesselCount: 0)
        let layout = OrreryLayout(model: model, center: .zero, scale: 1, reveal: 1, time: 0)
        #expect(OrreryGeometry.swarmPoints(layout: layout).isEmpty)
    }
}

// MARK: - Moon size honesty (size must carry real information)

struct MoonSizeHonestyTests {
    private func moon(_ radiusEarth: Double?) -> Moon {
        Moon(designation: "SOL-5-1", recon: radiusEarth == nil ? .visited : .scanned,
             physical: radiusEarth.map { BodyPhysical(radiusEarth: $0) })
    }

    @Test func sizeRangeIsWideEnoughToReadAsDifferentKindsOfBody() {
        // SOL-5's real moons span 0.0004 → 0.413 R⊕ (a 1000× ratio). The old curve
        // compressed that to 1.49× on screen, so every moon looked the same size.
        let tiny = OrreryMapping.moonSizeFraction(moon(0.0004))
        let large = OrreryMapping.moonSizeFraction(moon(0.413))
        #expect(large / tiny > 4)
        #expect(tiny < 0.06)
        #expect(large <= 0.30)
    }

    @Test func unscannedMoonSitsAtTheLowEndNotTheMiddle() {
        // The old default (0.14) out-sized most KNOWN moons, so an uncharted rock
        // rendered larger than a real one. It must now sit near the floor.
        let unknown = OrreryMapping.moonSizeFraction(moon(nil))
        #expect(unknown < OrreryMapping.moonSizeFraction(moon(0.1)))
        #expect(unknown <= 0.07)
    }

    @Test func sizeIsMonotonicInRadius() {
        let radii: [Double] = [0.0004, 0.001, 0.01, 0.05, 0.1, 0.2, 0.3, 0.413, 2.0]
        let sizes = radii.map { OrreryMapping.moonSizeFraction(moon($0)) }
        for (a, b) in zip(sizes, sizes.dropFirst()) { #expect(b >= a) }
    }

    @Test func sizeIsCappedSoAMoonNeverRivalsItsPlanet() {
        #expect(OrreryMapping.moonSizeFraction(moon(50)) <= 0.30)
    }
}

// MARK: - Moon orbits follow the shared plane (Task 8)

struct OrbitPlaneTests {
    private func tiltedPlanet(_ tilt: Double, moons: Int = 3) -> Planet {
        Planet(designation: "SOL-7", type: "Ice Giant", orbitalDistanceAu: 19,
               recon: .scanned, physical: BodyPhysical(radiusEarth: 4, rings: true,
                                                       axialTiltDeg: tilt),
               moons: (0..<moons).map { Moon(designation: "SOL-7-\($0 + 1)", recon: .scanned) })
    }

    @Test func moonsLeaveTheOrbitalPlaneOnATiltedPlanet() {
        let m = OrreryMapping.bodyModel(planet: tiltedPlanet(97.77))
        let layout = OrreryLayout(model: m, center: .zero, scale: 1, reveal: 1, time: 0)
        // At a strong tilt at least one moon must sit measurably off y = 0 at some
        // point in its orbit, or the plane is not being applied at all.
        let offPlane = (0..<8).contains { step in
            let l = OrreryLayout(model: m, center: .zero, scale: 1, reveal: 1,
                                 time: Float(step) * 12)
            return m.planets.contains { abs(l.orbiterPosition($0).y) > 0.2 }
        }
        #expect(offPlane)
        #expect(layout.plane != .flat)
    }

    @Test func nearlyUprightPlanetsStayEffectivelyPlanar() {
        // ASTELLIO-1 is 1.7° and carries 55 moons — the big-roster case must not be
        // gratuitously tipped.
        let m = OrreryMapping.bodyModel(planet: tiltedPlanet(1.7))
        let layout = OrreryLayout(model: m, center: .zero, scale: 1, reveal: 1, time: 5)
        #expect(m.planets.allSatisfy { abs(layout.orbiterPosition($0).y) < 0.5 })
    }

    @Test func decoupleKnobKeepsMoonsPlanar() {
        let opts = OrreryMapping.OrreryPlaneOptions(tiltCapDeg: 38, decoupleMoonPlane: true)
        let m = OrreryMapping.bodyModel(planet: tiltedPlanet(97.77), options: opts)
        #expect(m.centralBody?.orbitPole == nil)
        let layout = OrreryLayout(model: m, center: .zero, scale: 1, reveal: 1, time: 5)
        #expect(layout.plane == .flat)
        #expect(m.planets.allSatisfy { abs(layout.orbiterPosition($0).y) < 1e-5 })
        // The RINGS still tilt — that is the accepted mismatch this knob buys.
        #expect(m.centralBody?.rings != nil)
    }

    @Test func systemLevelStaysFlat() {
        // A system layer has no central body, so its plane is the orbital plane and
        // planets, belts, Lagrange points and structures are unaffected.
        let system = StarSystem(
            designation: "SOL",
            star: SystemStar(designation: "SOL", stellarClass: "G2", color: "Yellow"),
            recon: .scanned, systemScanned: true,
            planets: [Planet(designation: "SOL-3", type: "Terran", orbitalDistanceAu: 1,
                             recon: .scanned)])
        let m = OrreryMapping.systemModel(from: system)
        let layout = OrreryLayout(model: m, center: .zero, scale: 1, reveal: 1, time: 7)
        #expect(layout.plane == .flat)
        #expect(m.planets.allSatisfy { abs(layout.orbiterPosition($0).y) < 1e-5 })
    }

    @Test func theTiltCapKnobReachesTheSystemLevelToo() throws {
        // Both layers are encoded in the SAME frame during a drill transition, so a
        // planet built at two different tilt caps pops as the crossfade runs. The knob
        // used to reach `bodyModel` only, leaving `systemModel` pinned at the default.
        let system = StarSystem(designation: "SOL", planets: [tiltedPlanet(97.77)])
        let physicalOpts = OrreryMapping.OrreryPlaneOptions(tiltCapDeg: 90)

        let defaulted = try #require(OrreryMapping.systemModel(from: system).planets.first)
        let swept = try #require(
            OrreryMapping.systemModel(from: system, options: physicalOpts).planets.first)
        #expect(defaulted.spin.tiltCapDeg == 38)
        #expect(swept.spin.tiltCapDeg == 90)
        // The knob has to actually move the rendered plane, or the two agree by accident.
        #expect(defaulted.spin.renderObliquityDeg != swept.spin.renderObliquityDeg)

        // …and the drilled copy of the same planet must land on the same rendered pole.
        let drilled = try #require(
            OrreryMapping.bodyModel(planet: tiltedPlanet(97.77), options: physicalOpts).centralBody)
        #expect(abs(drilled.spin.renderObliquityDeg - swept.spin.renderObliquityDeg) < 1e-9)
    }

    @Test func orbitRingsTiltWithTheirMoons() {
        // A moon leaving its ring behind would be worse than either plane alone.
        let m = OrreryMapping.bodyModel(planet: tiltedPlanet(97.77))
        let layout = OrreryLayout(model: m, center: .zero, scale: 1, reveal: 1, time: 0)
        let verts = OrreryGeometry.scaffoldLines(model: m, center: .zero, scale: 1,
                                                plane: layout.plane)
        #expect(verts.contains { abs($0.position.y) > 0.2 })
    }

    @Test func swarmScatterIsRelativeToTheTiltedPlane() {
        let moons = (0..<40).map { Moon(designation: "SOL-7-\($0 + 1)", recon: .visited) }
        let planet = Planet(designation: "SOL-7", type: "Ice Giant", orbitalDistanceAu: 19,
                            recon: .scanned,
                            physical: BodyPhysical(radiusEarth: 4, axialTiltDeg: 97.77),
                            moons: moons)
        let m = OrreryMapping.bodyModel(planet: planet)
        let layout = OrreryLayout(model: m, center: .zero, scale: 1, reveal: 1, time: 3)
        // Distance from the tilted plane must stay bounded by the scatter — the band is
        // a disc around the equator, not a sphere.
        let n = layout.plane.normal
        let maxOffset = Float(m.swarm.map { abs($0.offsetScene) }.max() ?? 0)
        for s in m.swarm {
            let d = abs(simd_dot(layout.swarmPosition(s), n))
            #expect(d <= maxOffset + 1e-3, "\(s.designation) sits \(d) off the plane")
        }
    }
}

// MARK: - OrreryPlaneOptions defaults + appStorage keys (pinned so a typo silently
// disabling a knob would fail a test rather than ship unnoticed)

struct OrreryPlaneOptionsTests {
    @Test func defaultsMatchTheDocumentedValues() {
        let opts = OrreryMapping.OrreryPlaneOptions.default
        #expect(opts.tiltCapDeg == 38)
        #expect(opts.decoupleMoonPlane == false)
    }

    @Test func appStorageKeysArePinned() {
        #expect(OrreryMapping.OrreryPlaneOptions.tiltCapKey == "orreryMoonPlaneTiltCapDeg")
        #expect(OrreryMapping.OrreryPlaneOptions.decoupleKey == "orreryDecoupleMoonPlane")
    }
}

// MARK: - Irregular impostor + tumble (Task 9)

struct IrregularBodyTests {
    @Test func capturedAsteroidsAreIrregularAndOtherMoonsAreNot() {
        #expect(PlanetMaterial.irregularity(type: "Captured Asteroid") > 0.3)
        #expect(PlanetMaterial.irregularity(type: "captured asteroid") > 0.3)
        #expect(PlanetMaterial.irregularity(type: "Icy") == 0)
        #expect(PlanetMaterial.irregularity(type: "Rocky") == 0)
        #expect(PlanetMaterial.irregularity(type: "Gas Giant") == 0)
        #expect(PlanetMaterial.irregularity(type: nil) == 0)
    }

    @Test func irregularityStaysInTheUnitRange() {
        for t in ["Captured Asteroid", "Icy", "Rocky", "Subsurface Ocean", nil] {
            let v = PlanetMaterial.irregularity(type: t)
            #expect(v >= 0 && v <= 1)
        }
    }

    @Test func tumbleAxisIsUnitStableAndSeedVaried() {
        let a = BodySpin.tumbleAxis(seed: 0.2)
        #expect(abs(simd_length(a) - 1) < 1e-5)
        #expect(simd_distance(a, BodySpin.tumbleAxis(seed: 0.2)) < 1e-6)   // stable
        #expect(simd_distance(a, BodySpin.tumbleAxis(seed: 0.8)) > 0.01)   // varied
    }

    @Test func tumbleAxisIgnoresTheOrbitalPlane() {
        // An irregular satellite is a non-principal-axis rotator, and these moons
        // report no pole at all. A tumble axis that always pointed near +Y would just
        // look like a small upright planet.
        let axes = (0..<12).map { BodySpin.tumbleAxis(seed: Float($0) / 12) }
        #expect(axes.contains { abs($0.y) < 0.7 })
    }

    // The renderer's actual spin-axis selection (an irregular, free-tumbling body gets
    // the tumble axis; everything else keeps its pole) factored out to a pure function
    // so this exact rule — including the tidal-lock exception — is unit-testable
    // without a live StarFieldRenderer/Metal device.
    @Test func renderSpinAxisUsesTheTumbleAxisForAnIrregularFreeBody() {
        let pole = SIMD3<Float>(0, 1, 0)
        let axis = BodySpin.renderSpinAxis(irregularity: 0.45, locked: false,
                                           pole: pole, tumbleSeed: 0.3)
        #expect(axis == BodySpin.tumbleAxis(seed: 0.3))
        #expect(axis != pole)
    }

    @Test func renderSpinAxisKeepsThePoleForATidallyLockedIrregularBody() {
        // A tidally locked body is by definition no longer a chaotic non-principal-axis
        // rotator, AND `lockedSpinPhase` assumes the spin axis tracks the orbital
        // normal (the pole) — substituting the tumble axis here would visibly break the
        // "one face toward the parent" lock. Captured asteroids are ~18% of moons and
        // `tidallyLocked` is read independently of type, so this combination is real
        // (Triton is the textbook example), not a corner case.
        let pole = SIMD3<Float>(0.3, 0.9, 0.1)
        let axis = BodySpin.renderSpinAxis(irregularity: 0.45, locked: true,
                                           pole: pole, tumbleSeed: 0.3)
        #expect(axis == pole)
    }

    @Test func renderSpinAxisKeepsThePoleForARegularBody() {
        let pole = SIMD3<Float>(0, 1, 0)
        let axis = BodySpin.renderSpinAxis(irregularity: 0, locked: false,
                                           pole: pole, tumbleSeed: 0.3)
        #expect(axis == pole)
    }
}
