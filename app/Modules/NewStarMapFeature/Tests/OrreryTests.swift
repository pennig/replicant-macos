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

    @Test func moonCapForceIncludesEveryInterestingMoon() {
        // 30 moons that each host a device — all must survive the cap (a device must never
        // lack an anchor), even though the default cap trims boring moons at 24.
        let moons = (0..<30).map { i in
            Moon(designation: "SOL-5-\(i)", recon: .scanned,
                 devices: [LocatedDevice(deviceCode: "D\(i)", deviceType: "mining_drone")])
        }
        let planet = Planet(designation: "SOL-5", type: "Gas Giant",
                            orbitalDistanceAu: 5.2, recon: .scanned, moons: moons)
        let m = OrreryMapping.bodyModel(planet: planet)
        #expect(m.planets.count == 30)
        #expect(m.planets.allSatisfy { $0.indicators.contains(.device) })

        // Boring moons beyond the cap ARE trimmed.
        let boring = (0..<30).map { Moon(designation: "SOL-6-\($0)", recon: .scanned) }
        let m2 = OrreryMapping.bodyModel(planet:
            Planet(designation: "SOL-6", type: "Gas Giant", orbitalDistanceAu: 6, recon: .scanned, moons: boring))
        #expect(m2.planets.count == 24)
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
        #expect(m.centralBody?.hasRing == true)
        #expect(m.planets.count == 2)                       // moons became orbiters
        // The interesting moon (a live salvage site) sorts to the front.
        #expect(m.planets.first?.designation == "SHERATANON-6-b")
        #expect(m.planets.first?.indicators.contains(.salvage) == true)
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
            displayRadius: radius, colorHex: "#ffffff", hasRing: false, indicators: [],
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
            displayRadius: 1, colorHex: "#ffffff", hasRing: false, indicators: [],
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

        // 90 degrees lays the pole into the orbital plane.
        let sideways = BodySpin(tiltDeg: 90).pole(seed: 0.3)
        #expect(abs(sideways.y) < 1e-6)
        #expect(abs(simd_length(sideways) - 1) < 1e-6)

        // Same tilt, different seed => different lean direction, so two worlds
        // sharing an obliquity don't all lean the same way.
        let a = BodySpin(tiltDeg: 45).pole(seed: 0.1)
        let b = BodySpin(tiltDeg: 45).pole(seed: 0.8)
        #expect(simd_length(a - b) > 1e-3)
        #expect(abs(a.y - b.y) < 1e-6)   // same obliquity => same height
    }

    @Test func spinRateAnchorsFastestAndCompressesTheSpread() {
        // The fastest rotator in the layer turns at the base rate.
        let fast = BodySpin(tiltDeg: 3.13, rotationHours: 9.92)
        #expect(abs(fast.spinRate(fastestHours: 9.92) - 0.06) < 1e-6)

        // Four times slower => half the rate at falloff 0.5, not a quarter.
        let slow = BodySpin(rotationHours: 39.68)
        #expect(abs(slow.spinRate(fastestHours: 9.92) - 0.03) < 1e-6)

        // Venus is 588x slower than Jupiter but must not be visually frozen.
        let venus = BodySpin(tiltDeg: 177.4, rotationHours: -5832.5)
        let rate = venus.spinRate(fastestHours: 9.92)
        #expect(rate < 0)                       // explicit retrograde
        #expect(abs(rate) > 0.06 / 100)         // compressed, not crushed

        // No reading => the historical fixed rate, prograde.
        #expect(BodySpin.unknown.spinRate(fastestHours: 9.92) == 0.06)
    }

    @Test func tidallyLockedIsCarriedThrough() {
        #expect(BodySpin(tidallyLocked: true).tidallyLocked)
        #expect(!BodySpin.unknown.tidallyLocked)
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
