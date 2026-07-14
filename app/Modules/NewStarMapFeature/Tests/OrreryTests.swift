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
        #expect(ice(.terrestrial, 15) > 0.15)                  // a mild-cold world shows a clear cap
        #expect(ice(.terrestrial, 15) < ice(.desertWorld, -30)) // colder → larger cap
        #expect(ice(.oceanWorld, -20) > 0.5)
        #expect(ice(.desertWorld, -40) == 1)                   // full extent by −40°C
        #expect(ice(.desertWorld, -100) == 1)                  // and clamps there
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
        #expect(Set(ls.map(\.point)) == [1, 4])
        #expect(ls.first { $0.designation == "SOL-5-L4" }?.point == 4)
        // Structures with an orbital distance become positioned anchors.
        #expect(Set(m.structures.map(\.designation)) == ["SOL-KUIPER", "SOL-OBJ-1"])
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
}
