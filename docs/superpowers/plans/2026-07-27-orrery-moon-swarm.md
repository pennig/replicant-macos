# Orrery Many-Moon Rendering Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the body-level orrery read clearly for planets with 1 to 60+ moons, without dropping any moon, by promoting only significant moons to their own orbit ring and rendering the rest as an animated swarm in a single band.

**Architecture:** Four independent layers. (1) `OrreryMapping` splits a moon roster into *promoted* moons (which stay `OrreryPlanet` orbiters) and a *swarm* (a new lightweight `SwarmMoon` collection on `SystemModel`), so the existing ring/picking loops exclude swarm members structurally rather than by flag. (2) `OrreryLayout` gains swarm positioning and an orbit-plane basis. (3) `OrreryGeometry` emits swarm points through the existing additive point pipeline. (4) `BodySpin` compresses obliquity so rings, surface, and moon orbits share one plane without going edge-on.

**Tech Stack:** Swift 6, Swift Testing (`@Test`/`#expect`), SwiftUI, Metal, simd. SPM package rooted at `app/Modules`.

## Global Constraints

- Target macOS 26+. Package root for all commands: `app/Modules`.
- **Never hard-code colors, spacing, or font sizes in SwiftUI.** Use `DesignSystem.swift` tokens (`.rcTextPrimary`, `Space.m`, `Font.rcCaption`, …). Shader/geometry colors are the documented exception — they live as `SIMD3`/`SIMD4` constants in `OrreryGeometry` because Metal cannot read the asset catalog.
- **System and location designations always render in a mono font token** (`.rcMono`, `.rcMonoSmall`).
- **Read `swift test` results from the JSON event stream**, never by scraping console text. Use the `swift-test-event-stream` skill for the invocation.
- Commits go directly to this worktree branch. **Do not create PRs and do not push to origin.**
- `os.Logger` only, never `print`.
- After the first build in this worktree, run `Modules/scripts/link-index-store.sh` once so SourceKit-LSP reference queries work.
- Test command used throughout: `swift test --package-path app/Modules --filter <TestName>`.
- Test fixtures use the **memberwise** initializers of `Moon`, `Planet`, and `BodyPhysical` from `UniverseModels`, so argument order must match each type's property declaration order. If the compiler reports an argument-order error, reorder the call to match the declaration — do **not** add new initializers to `UniverseModels` to make a fixture compile.

## File Structure

| File | Responsibility | Change |
| --- | --- | --- |
| `app/Modules/NewStarMapFeature/Sources/MoonTiering.swift` | Pure promotion rules: split `[Moon]` into promoted + swarm | **Create** |
| `app/Modules/NewStarMapFeature/Sources/OrreryModels.swift` | Presentation model | Add `SwarmMoon`, `SystemModel.swarm`, `CentralBody.orbitPole` |
| `app/Modules/NewStarMapFeature/Sources/OrreryMapping.swift` | API → presentation model | Rewrite the moon path in `bodyModel`; widen `moonSizeFraction`; add `OrreryPlaneOptions` |
| `app/Modules/NewStarMapFeature/Sources/OrreryLayout.swift` | World position of anything, at an instant | Add `swarmPosition`, `OrbitPlane`; fold swarm into the timing anchor |
| `app/Modules/NewStarMapFeature/Sources/BodySpin.swift` | Pole + spin rate | Add `renderObliquityDeg`, `tiltCapDeg`, `planeBasis` |
| `app/Modules/NewStarMapFeature/Sources/OrreryGeometry.swift` | CPU vertex generation | Add `swarmPoints`; plane-aware `scaffoldLines` |
| `app/Modules/NewStarMapFeature/Sources/StarFieldRenderer.swift` | Draw encoding | Swarm buffer per layer, per-frame rewrite, encode |
| `app/Modules/NewStarMapFeature/Sources/NewStarMapView.swift` | HUD | `bodiesCard` → scrollable, grouped, selectable roster |
| `app/Modules/NewStarMapFeature/Sources/NewStarMapFeature.swift` | Reducer | Read the two appStorage knobs, pass to `bodyModel` |
| `app/Modules/NewStarMapFeature/Sources/CShaderTypes/…/ShaderTypes.h` | GPU structs | Document `surfaceExtras.y` as irregularity |
| `app/Modules/NewStarMapFeature/Sources/Orrery.metal` | Shaders | Irregular impostor branch |
| `app/Modules/NewStarMapFeature/Tests/OrreryTests.swift` | Tests | New suites + update two obliquity tests |

**Why `MoonTiering` is its own file:** the promotion rules are the one piece of this work with genuinely independent behavior worth reading on its own, and `OrreryMapping.swift` is already 537 lines. Everything else belongs where it already lives.

---

## Phase 1 — Tiering, band layout, roster card

### Task 1: Moon tiering rules

**Files:**
- Create: `app/Modules/NewStarMapFeature/Sources/MoonTiering.swift`
- Test: `app/Modules/NewStarMapFeature/Tests/OrreryTests.swift`

**Interfaces:**
- Consumes: `Moon` (from `UniverseModels`), `OrreryMapping.moonIsInteresting(_:)`
- Produces: `MoonTiering.split(_ moons: [Moon], rules: MoonTiering.Rules = .default) -> (promoted: [Moon], swarm: [Moon])` and `MoonTiering.Rules(promoteAllAtOrBelow: Int, topBySize: Int, relativeSizeFloor: Double)`

- [ ] **Step 1: Write the failing tests**

Append this suite to the end of `app/Modules/NewStarMapFeature/Tests/OrreryTests.swift`:

```swift
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

    @Test func largeRosterWithNoSizeDataPromotesNothingOnSize() {
        // POLARISON-6: 59 moons, zero physical blocks. We do not know which are
        // major, so none is promoted on size — asserting otherwise would be a guess.
        let moons = (0..<59).map(plain)
        let t = MoonTiering.split(moons)
        #expect(t.promoted.isEmpty)
        #expect(t.swarm.count == 59)
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
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
swift test --package-path app/Modules --filter MoonTieringTests
```

Expected: FAIL — `cannot find 'MoonTiering' in scope`.

- [ ] **Step 3: Create `MoonTiering.swift`**

```swift
//
//  MoonTiering.swift
//  NewStarMapFeature
//
//  Splits a planet's moon roster into the moons that earn their own orbit ring and
//  the ones that become a swarm. Pure + deterministic, so the rules are unit-tested
//  rather than eyeballed on the GPU.
//
//  The point of the split is screen budget: the body-level orrery spends ~1.33 scene
//  units of radius per ringed moon, so a 59-moon roster pushes the outermost orbit
//  past 90 units and shrinks the drilled planet to ~3% of the frame radius. Promoted
//  moons keep the old per-moon treatment; the swarm costs one band regardless of
//  count (see `OrreryMapping.bodyModel`).
//

import UniverseModels

enum MoonTiering {

    /// The promotion thresholds. Values are the shipped defaults; tests override them.
    struct Rules: Equatable, Sendable {
        /// A roster this size or smaller promotes EVERY moon, so the overwhelming
        /// majority of planets (all but five in the live census) render exactly as
        /// they did before this work.
        var promoteAllAtOrBelow: Int = 8
        /// At most this many moons promote on size alone.
        var topBySize: Int = 4
        /// A moon must be at least this fraction of the largest KNOWN radius to
        /// promote on size. Without it, a roster of similarly-sized moons would
        /// promote `topBySize` of them arbitrarily.
        var relativeSizeFloor: Double = 0.5

        static let `default` = Rules()
    }

    /// Split a roster into (promoted, swarm), each preserving the input order.
    ///
    /// A moon promotes when it is *interesting* (hosts a device, a live salvage site, a
    /// mining site, or stored inventory) or when it is among the largest few by known
    /// radius. Interest is checked first and is never overridden: everything that needs
    /// an exact anchor from `OrreryLayout` must be a full orbiter, which is what makes
    /// the swarm's coarser treatment safe.
    ///
    /// A roster with no `radiusEarth` readings promotes nothing on size — with no data
    /// we genuinely do not know which moons are major, and inventing an answer would
    /// put arbitrary moons on rings.
    static func split(_ moons: [Moon], rules: Rules = .default) -> (promoted: [Moon], swarm: [Moon]) {
        guard moons.count > rules.promoteAllAtOrBelow else { return (moons, []) }

        var promotedIDs = Set(moons.lazy.filter(OrreryMapping.moonIsInteresting).map(\.designation))

        let radii = moons.compactMap { m -> (id: String, r: Double)? in
            guard let r = m.physical?.radiusEarth, r > 0 else { return nil }
            return (m.designation, r)
        }
        if let largest = radii.map(\.r).max() {
            let floor = largest * rules.relativeSizeFloor
            let bySize = radii
                .filter { $0.r >= floor }
                .sorted { $0.r > $1.r }
                .prefix(rules.topBySize)
            promotedIDs.formUnion(bySize.map(\.id))
        }

        return (moons.filter { promotedIDs.contains($0.designation) },
                moons.filter { !promotedIDs.contains($0.designation) })
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
swift test --package-path app/Modules --filter MoonTieringTests
```

Expected: PASS, 6 tests.

- [ ] **Step 5: Commit**

```bash
git add app/Modules/NewStarMapFeature/Sources/MoonTiering.swift \
        app/Modules/NewStarMapFeature/Tests/OrreryTests.swift
git commit -m "Add moon tiering rules for many-moon rosters"
```

---

### Task 2: `SwarmMoon` model and band placement

**Files:**
- Modify: `app/Modules/NewStarMapFeature/Sources/OrreryModels.swift`
- Modify: `app/Modules/NewStarMapFeature/Sources/OrreryMapping.swift:396-513` (`bodyModel`)
- Test: `app/Modules/NewStarMapFeature/Tests/OrreryTests.swift`

**Interfaces:**
- Consumes: `MoonTiering.split(_:rules:)` from Task 1.
- Produces: `SwarmMoon` (fields `designation`, `name`, `type`, `orbitScene`, `offsetScene`, `periodDays`, `phase0Deg`, `displayRadius`, `colorHex`, `scanned`, `isCapturedAsteroid`); `SystemModel.swarm: [SwarmMoon]`; `OrreryMapping.swarmBand(promotedOuter:centralClearance:swarmCount:) -> (inner: Double, outer: Double)`. `bodyModel(planet:)` no longer takes `maxMoons`.

- [ ] **Step 1: Write the failing tests**

Append to `OrreryTests.swift`:

```swift
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
        #expect(m.swarm.count == 59)          // none promoted: no size data, nothing interesting
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
        #expect(moved.orbitScene != before.swarm[7].orbitScene)
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
        // Force everything into the swarm by exceeding the promote-all threshold with
        // no radii and no interest.
        let m = OrreryMapping.bodyModel(planet: planet(moons, designation: "SOL-5"))
        #expect(m.swarm.count == 12)
        func orbit(_ n: Int) -> Double {
            m.swarm.first { $0.designation == "SOL-5-\(n)" }!.orbitScene
        }
        // Radial order follows real distance, not designation order.
        #expect(orbit(6) < orbit(5))          // 128,000 km inside 181,400 km
        #expect(orbit(4) < orbit(10))         // 1.88e6 km inside 7.15e6 km
        // The family gap is wider than any gap inside the inner cluster.
        let innerSpan = orbit(4) - orbit(6)
        #expect(orbit(10) - orbit(4) > innerSpan)
    }

    @Test func capturedAsteroidsScatterWiderThanRegularMoons() {
        let regular = (0..<30).map { Moon(designation: "R-1-\($0)", type: "Icy", recon: .visited) }
        let captured = (0..<30).map { Moon(designation: "R-2-\($0)", type: "Captured Asteroid", recon: .visited) }
        let a = OrreryMapping.bodyModel(planet: planet(regular, designation: "R-1"))
        let b = OrreryMapping.bodyModel(planet: planet(captured, designation: "R-2"))
        func spread(_ s: [SwarmMoon]) -> Double { s.map { abs($0.offsetScene) }.max() ?? 0 }
        #expect(spread(b) > spread(a))
        #expect(b.swarm.allSatisfy(\.isCapturedAsteroid))
        #expect(a.swarm.allSatisfy { !$0.isCapturedAsteroid })
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
swift test --package-path app/Modules --filter MoonSwarmLayoutTests
```

Expected: FAIL — `cannot find type 'SwarmMoon' in scope`, `value of type 'SystemModel' has no member 'swarm'`.

- [ ] **Step 3: Add `SwarmMoon` and `SystemModel.swarm`**

In `OrreryModels.swift`, insert immediately after the `OrreryMoon` struct (which ends at line 78):

```swift
/// A moon that did not earn its own orbit ring — one member of the swarm band drawn
/// around a planet with a large roster. Deliberately much lighter than `OrreryPlanet`:
/// a swarm member is never picked in 3D, never labelled, never carries indicators, and
/// never hosts a device (`MoonTiering` promotes anything interesting), so it needs only
/// enough to be positioned, tinted, and listed in the HUD roster.
///
/// It is a SEPARATE collection from `SystemModel.planets` rather than a flag on
/// `OrreryPlanet` so the exclusions are structural: `OrreryGeometry.scaffoldLines`
/// iterates `planets` to emit orbit rings, and picking iterates `planets`, so a swarm
/// member gets neither by construction instead of by every consumer remembering a check.
struct SwarmMoon: Identifiable, Equatable, Sendable {
    var designation: String
    var name: String?
    var type: String?
    /// Orbit radius within the swarm band (scene units).
    var orbitScene: Double
    /// Signed offset off the orbital plane (scene units) — the inclination scatter that
    /// makes the band read as a cloud of rocks rather than a ring of dots.
    var offsetScene: Double
    var periodDays: Double
    var phase0Deg: Double
    var displayRadius: Double
    var colorHex: String
    var scanned: Bool
    /// An irregular satellite (`type` contains "captured"). Scatters wider, and later
    /// drives the irregular impostor.
    var isCapturedAsteroid: Bool
    var id: String { designation }
}
```

In the same file, add to `SystemModel` immediately after the `planets` property (line 193):

```swift
    /// Moons that did not earn an orbit ring — drawn as an animated point band. Empty
    /// at system level and for any planet whose roster is small enough that every moon
    /// promotes. See `MoonTiering`.
    var swarm: [SwarmMoon] = []
```

- [ ] **Step 4: Add the band helper to `OrreryMapping`**

Insert into `OrreryMapping` just above the `// MARK: - Body level` comment (currently line 353):

```swift
    /// The swarm band's radial extent (scene units) for a body-level layer.
    ///
    /// Deliberately a function of the ROSTER SIZE and the central body's scale only —
    /// never of where the swarm's members happen to sit. That is what makes late
    /// physical data harmless: when a scan finally reports a moon's real
    /// `orbital_distance_km`, that moon settles into its true radius *within* a band
    /// whose edges did not move, so nothing else on screen shifts. Deriving the edges
    /// from member positions instead would make every arriving scan reshuffle the view.
    static func swarmBand(promotedOuter: Double, centralClearance: Double,
                          swarmCount: Int) -> (inner: Double, outer: Double) {
        let pad = max(0.6, centralClearance * 0.15)
        let inner = max(promotedOuter, centralClearance) + pad
        // Widen a little with the roster so a 60-body cloud reads deeper than a 12-body
        // one, but cap it: the band must stay O(1) in count or it reintroduces exactly
        // the frame-budget blowout the swarm exists to fix.
        let width = min(centralScene * 4.0, centralScene * (2.0 + 0.02 * Double(swarmCount)))
        return (inner, inner + width)
    }

    /// The drilled planet's rendered radius at body level — a fixed, prominent centre
    /// (the body-level analogue of the field star), with everything else proportional.
    static let centralScene: Double = 2.6

    /// How far swarm members scatter off the orbital plane, as a fraction of the band
    /// width. Irregular satellites really do carry high inclinations, and the scatter
    /// doubles as visual de-overlap. Set to 0 for a strictly planar band.
    static let swarmInclinationSpread: Double = 0.12
    /// Captured asteroids scatter this much wider than regular moons.
    static let capturedInclinationFactor: Double = 2.2
```

- [ ] **Step 5: Rewrite the moon path in `bodyModel`**

In `OrreryMapping.swift`, change the signature at line 396 from:

```swift
    static func bodyModel(planet: Planet, maxMoons: Int = 24) -> SystemModel {
        // The drilled planet is the body-level "sun": a consistent, prominent centre
        // (like the field star at system level), with its moons proportional to it.
        let centralScene = 2.6
```

to:

```swift
    static func bodyModel(planet: Planet) -> SystemModel {
```

(The local `centralScene` constant is gone — the type-level `centralScene` added in Step 4 replaces it, and every existing reference in the function body resolves to it unchanged.)

Then replace the whole block from `let ordered = planet.moons.sorted { a, b in` (line 425) through the closing `}` of the `moons` map (line 495) with:

```swift
        // Split the roster: moons that earn a ring, and the rest. See `MoonTiering` for
        // why interest always wins and why a roster with no radii promotes nothing.
        let (promotedMoons, swarmMoons) = MoonTiering.split(planet.moons)

        // Promoted moons keep the historical treatment exactly: nearest-first, real
        // orbit radii where the scan gives them, and the same non-overlap pass the
        // planets get. Interest-first ordering is gone — the cap it existed to serve
        // is gone too, and `spacedLayout` sorts by raw radius internally anyway.
        let ordered = promotedMoons.sorted { a, b in
            let ad = a.physical?.orbitalDistanceKm ?? .greatestFiniteMagnitude
            let bd = b.physical?.orbitalDistanceKm ?? .greatestFiniteMagnitude
            if ad != bd { return ad < bd }
            return a.designation < b.designation
        }
        // First moon clears the planet — and its rings — plus a gap. The gap stays
        // proportional to the BODY, not the ring extent, so an unringed planet keeps
        // exactly its historical `centralScene * 1.7`.
        let base = centralClearance + centralScene * 0.7
        let step = centralScene * 0.5
        let rawMoonOrbits = ordered.enumerated().map { i, m -> Double in
            if let km = m.physical?.orbitalDistanceKm, km > 0 {
                return max(moonSceneRadius(km: km), base)
            }
            return base + Double(i) * step
        }
        let moonRadii = ordered.map { centralScene * moonSizeFraction($0) }
        let moonOrbits = spacedLayout(
            planetOrbits: rawMoonOrbits, planetRadii: moonRadii,
            beltInner: [], beltOuter: [], sunScene: centralClearance).orbits
        let moons: [OrreryPlanet] = ordered.enumerated().map { i, m in
            var indicators: BodyIndicators = []
            if !m.devices.isEmpty { indicators.insert(.device) }
            if m.salvage.contains(where: { !$0.depleted }) { indicators.insert(.salvage) }
            if !m.sites.isEmpty { indicators.insert(.miningSite) }
            if !m.inventory.isEmpty { indicators.insert(.inventory) }
            return OrreryPlanet(
                designation: m.designation, name: m.name, type: m.type,
                planetType: PlanetType(apiType: m.type), estimated: m.recon != .scanned,
                tags: m.physical?.tags ?? [],
                surfaceTempC: m.physical?.surfaceTempC,
                atmosphere: moonAtmosphere(m),
                appearanceSeed: appearanceSeed(designation: m.designation,
                                               rotationPeriodHours: m.physical?.rotationPeriodHours),
                orbitalDistanceAu: 0, inHabitableZone: false,
                scanned: m.recon == .scanned, moonCount: 0, lifeStage: nil,
                inventory: m.inventory,
                semiMajorScene: moonOrbits[i],
                // A moon's real speed is `orbital_period_hours`; it never reports days.
                // The index ladder is only a last resort for an unscanned roster.
                periodDays: m.physical?.orbitalPeriodHours.map { $0 / 24 }
                    ?? m.physical?.orbitalPeriodDays
                    ?? (8 + Double(i) * 3),
                phase0Deg: phaseDeg(m.designation),
                displayRadius: centralScene * moonSizeFraction(m),
                colorHex: moonColor(type: m.type),
                rings: nil,
                spin: BodySpin(tiltDeg: m.physical?.axialTiltDeg,
                               rotationHours: m.physical?.rotationPeriodHours,
                               tidallyLocked: m.physical?.tidallyLocked ?? false),
                hasSubsurfaceOcean: m.physical?.hasSubsurfaceOcean ?? false,
                orbitalDistanceKm: m.physical?.orbitalDistanceKm,
                indicators: indicators,
                hasInterestingMoon: false, moons: [])
        }

        // The swarm: one band, members placed by real distance where known and by a
        // stable designation hash anchored to their index otherwise.
        let promotedOuter = moons.map { $0.semiMajorScene + $0.displayRadius }.max() ?? 0
        let band = swarmBand(promotedOuter: promotedOuter,
                            centralClearance: centralClearance,
                            swarmCount: swarmMoons.count)
        let bandWidth = band.outer - band.inner
        // Map real km into the band by the same sqrt compression the planets get, then
        // normalize against THIS roster's span so the band is filled edge to edge and
        // genuine family gaps (SOL-5's inner moons vs its far irregulars) survive.
        let knownKm = swarmMoons.compactMap { m -> Double? in
            guard let km = m.physical?.orbitalDistanceKm, km > 0 else { return nil }
            return moonSceneRadius(km: km)
        }
        let kmLo = knownKm.min() ?? 0, kmHi = knownKm.max() ?? 0
        let swarm: [SwarmMoon] = swarmMoons.enumerated().map { i, m in
            // Two placement sources, and which one applies must depend ONLY on this
            // moon's own data — never on the roster's — or a scan landing anywhere
            // would move everything.
            let fraction: Double
            if let km = m.physical?.orbitalDistanceKm, km > 0, kmHi > kmLo {
                fraction = (moonSceneRadius(km: km) - kmLo) / (kmHi - kmLo)
            } else if swarmMoons.count > 1 {
                // No reading: sit at the index fraction, jittered by a stable hash so
                // the band does not read as a regular ladder. Index order IS orbital
                // order in generated systems (verified on ASTELLIO-1 and ABEEMIM-6).
                let idx = Double(i) / Double(swarmMoons.count - 1)
                let jitter = (phaseDeg(m.designation + "-R") / 360 - 0.5) * 0.06
                fraction = min(max(idx + jitter, 0), 1)
            } else {
                fraction = 0.5
            }
            let captured = (m.type ?? "").lowercased().contains("captured")
            // Inclination: a stable signed hash, widened for irregular satellites.
            let incHash = phaseDeg(m.designation + "-INC") / 360 - 0.5
            let spread = swarmInclinationSpread * (captured ? capturedInclinationFactor : 1)
            let orbit = band.inner + fraction * bandWidth
            return SwarmMoon(
                designation: m.designation, name: m.name, type: m.type,
                orbitScene: orbit,
                offsetScene: incHash * 2 * spread * bandWidth,
                // Real period where known, else Kepler-ish from the band radius so the
                // cloud shows differential rotation instead of turning rigidly.
                periodDays: m.physical?.orbitalPeriodHours.map { $0 / 24 }
                    ?? m.physical?.orbitalPeriodDays
                    ?? max(2, 6 * pow(orbit / max(centralClearance, 0.001), 1.5)),
                phase0Deg: phaseDeg(m.designation),
                displayRadius: centralScene * moonSizeFraction(m),
                colorHex: moonColor(type: m.type),
                scanned: m.recon == .scanned,
                isCapturedAsteroid: captured)
        }
```

Then replace the framing + return block (lines 496-512) with:

```swift
        // Frame to the outer edge of everything drawn: promoted moons, the swarm band,
        // and never inside the central body's own ring system (a ringed planet with no
        // moons would otherwise be framed tighter than its rings and clip them).
        let moonReach = moons.map { $0.semiMajorScene + $0.displayRadius }.max()
        let swarmReach = swarm.isEmpty ? 0 : band.outer
        let frame = max(moonReach ?? (centralScene + 2), swarmReach, centralClearance) * 1.12
        let deviceCount = planet.devices.count + planet.moons.reduce(0) { $0 + $1.devices.count }

        return SystemModel(
            star: StarDetail(
                designation: planet.designation, name: planet.name,
                spectralType: planet.type, color: nil,
                position: Position(x: 0, y: 0, z: 0),
                temperatureK: nil, massSolar: nil, luminositySolar: nil, ageMy: nil,
                habitableZone: nil, miningBonusPct: nil),
            centralBody: central, hzInnerScene: nil, hzOuterScene: nil,
            planets: moons, swarm: swarm, belts: [], hazards: [], kuiperScene: nil,
            frameScene: frame, deviceCount: deviceCount, vesselCount: 0)
    }
```

- [ ] **Step 6: Delete the obsolete cap test**

The old `moonCapForceIncludesEveryInterestingMoon` test (`OrreryTests.swift:392-410`) asserts `m2.planets.count == 24`, which encodes the cap this task removes. Delete that whole `@Test func` — `MoonTieringTests.interestingMoonsAlwaysPromote` and `MoonSwarmLayoutTests.everyMoonIsRepresented` cover its intent (the anchor invariant and no-silent-drops) more directly.

- [ ] **Step 7: Run the tests**

```bash
swift test --package-path app/Modules --filter "MoonSwarmLayoutTests|OrreryMappingTests"
```

Expected: PASS. `bodyModelBuildsCentralPlanetAndMoons` must still pass unchanged — it uses a 2-moon roster, which promotes wholly.

- [ ] **Step 8: Commit**

```bash
git add app/Modules/NewStarMapFeature/Sources/OrreryModels.swift \
        app/Modules/NewStarMapFeature/Sources/OrreryMapping.swift \
        app/Modules/NewStarMapFeature/Tests/OrreryTests.swift
git commit -m "Place non-promoted moons in a swarm band instead of a per-moon ring"
```

---

### Task 3: Swarm positioning in `OrreryLayout`

**Files:**
- Modify: `app/Modules/NewStarMapFeature/Sources/OrreryLayout.swift:71` (`minPeriodDays`) and add `swarmPosition`
- Test: `app/Modules/NewStarMapFeature/Tests/OrreryTests.swift`

**Interfaces:**
- Consumes: `SwarmMoon`, `SystemModel.swarm` from Task 2.
- Produces: `OrreryLayout.swarmPosition(_ m: SwarmMoon) -> SIMD3<Float>`, `OrreryLayout.swarmAngle(_ m: SwarmMoon) -> Float`.

- [ ] **Step 1: Write the failing tests**

Append to `OrreryTests.swift`:

```swift
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
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
swift test --package-path app/Modules --filter SwarmLayoutTests
```

Expected: FAIL — `value of type 'OrreryLayout' has no member 'swarmPosition'`.

- [ ] **Step 3: Fold the swarm into the timing anchor**

In `OrreryLayout.swift`, replace lines 69-71:

```swift
    /// The shortest orbital period (days) among this layer's orbiters — the "fastest"
    /// orbit the on-screen timing is anchored to. 1 for an empty model.
    var minPeriodDays: Double { model.planets.map(\.periodDays).min() ?? 1 }
```

with:

```swift
    /// The shortest orbital period (days) among this layer's orbiters — the "fastest"
    /// orbit the on-screen timing is anchored to. 1 for an empty model.
    ///
    /// The SWARM is folded in deliberately. Swarm members are not `planets`, but they
    /// are timed by the same `OrbitTiming`, so leaving them out would anchor the two
    /// populations on different values and the band would visibly run at a different
    /// rate than the promoted moons beside it.
    var minPeriodDays: Double {
        let periods = model.planets.map(\.periodDays) + model.swarm.map(\.periodDays)
        return periods.min() ?? 1
    }
```

- [ ] **Step 4: Add swarm positioning**

In `OrreryLayout.swift`, insert after `orbiterPosition(id:)` (line 89), before `// MARK: Lagrange points`:

```swift
    // MARK: Swarm

    /// A swarm member's orbit angle (radians) at the layer's `time`. Timed by the same
    /// `OrbitTiming` and anchor as the promoted moons, so the whole layer runs together.
    func swarmAngle(_ m: SwarmMoon) -> Float {
        timing.angle(phase0Deg: m.phase0Deg, periodDays: m.periodDays,
                     minPeriodDays: minPeriodDays, time: time)
    }

    /// A swarm member's world position at the layer's `time`, with `reveal` applied.
    ///
    /// Unlike every other anchor this is NOT confined to the orbital plane: the signed
    /// `offsetScene` lifts it off the plane so the band reads as a cloud of rocks. The
    /// offset is scaled by `reveal` along with the radius, so the swarm emerges from the
    /// centre on drill-in exactly as the orbiters do rather than popping into place.
    func swarmPosition(_ m: SwarmMoon) -> SIMD3<Float> {
        let a = swarmAngle(m)
        let r = Float(m.orbitScene) * scale * reveal
        let y = Float(m.offsetScene) * scale * reveal
        return center + SIMD3<Float>(cos(a) * r, y, sin(a) * r)
    }
```

- [ ] **Step 5: Run the tests**

```bash
swift test --package-path app/Modules --filter "SwarmLayoutTests|OrreryLayoutTests"
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add app/Modules/NewStarMapFeature/Sources/OrreryLayout.swift \
        app/Modules/NewStarMapFeature/Tests/OrreryTests.swift
git commit -m "Position swarm moons and fold them into the orbit timing anchor"
```

---

### Task 4: Render the swarm

**Files:**
- Modify: `app/Modules/NewStarMapFeature/Sources/OrreryGeometry.swift`
- Modify: `app/Modules/NewStarMapFeature/Sources/StarFieldRenderer.swift`
- Test: `app/Modules/NewStarMapFeature/Tests/OrreryTests.swift`

**Interfaces:**
- Consumes: `OrreryLayout.swarmPosition(_:)` from Task 3.
- Produces: `OrreryGeometry.swarmPoints(layout: OrreryLayout) -> [AmbientVertex]`.

- [ ] **Step 1: Write the failing test**

Append to `OrreryTests.swift`:

```swift
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
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
swift test --package-path app/Modules --filter SwarmGeometryTests
```

Expected: FAIL — `type 'OrreryGeometry' has no member 'swarmPoints'`.

- [ ] **Step 3: Add `swarmPoints` to `OrreryGeometry`**

Insert into `OrreryGeometry.swift` after `beltPoints` (which ends at line 172):

```swift
    /// Swarm-moon tint: the moon's own schematic colour, dimmed. A swarm member is
    /// scenery, so it must not compete with the promoted moons' lit impostors.
    private static let swarmBrightness: Float = 0.55
    /// Screen-space point size (px). Deliberately small — legibility for these bodies
    /// comes from the HUD roster, not from inflating them (see the spec's size-honesty
    /// section), and a swarm member is never individually picked.
    private static let swarmPointSize: Float = 2.0

    /// The moon swarm as additive world-space points, one per member, at their live
    /// orbital positions. Reuses `AmbientVertex` and the same point pipeline the
    /// asteroid belt draws through.
    ///
    /// Takes the whole `OrreryLayout` rather than loose parameters so the swarm is
    /// positioned by the SAME resolver that places bodies, pips, and picking — there is
    /// no second copy of the orbit math to drift out of sync.
    ///
    /// IMPORTANT: build the layout around the centre the other orrery buffers were baked
    /// at (`orreryBuildCenter`), NOT the live `orreryCenter`. The point vertex shader
    /// rebases every vertex by `orreryCenter − orreryBuildCenter`, so positions generated
    /// around the live centre would be offset twice and the swarm would slide off the
    /// planet as it orbits.
    static func swarmPoints(layout: OrreryLayout) -> [AmbientVertex] {
        let swarm = layout.model.swarm
        guard !swarm.isEmpty else { return [] }
        var pts: [AmbientVertex] = []
        pts.reserveCapacity(swarm.count)
        for m in swarm {
            let p = layout.swarmPosition(m)
            let tint = rgb(hex: m.colorHex)
            // An unscanned member reads dimmer: the band should look partly charted
            // rather than assert detail the scan has not delivered.
            let brightness = swarmBrightness * (m.scanned ? 1.0 : 0.75)
            pts.append(AmbientVertex(positionSize: SIMD4(p, swarmPointSize),
                                     color: SIMD4(tint, brightness)))
        }
        return pts
    }
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
swift test --package-path app/Modules --filter SwarmGeometryTests
```

Expected: PASS, 3 tests.

- [ ] **Step 5: Add the swarm buffer to the renderer**

In `StarFieldRenderer.swift`, add next to the belt buffer declarations (after line 88):

```swift
    /// Swarm-moon points. Unlike the belt (baked once), these are rewritten every frame
    /// from `OrreryGeometry.swarmPoints` because the swarm ORBITS. The buffer is
    /// allocated once per model at the roster's capacity, so the per-frame cost is a
    /// memcpy of at most a few KB — no allocation on the render thread (which is what
    /// the drill-in fly hitch was about).
    private var orrerySwarmBuffer: MTLBuffer?
    private var orrerySwarmCapacity = 0
    private var orrerySwarmCount = 0
```

In `setOrreryModel` (line 1560), append after the belt buffer block (line 1582):

```swift
        // Allocate (not fill) the swarm buffer at this roster's capacity. `draw`
        // rewrites the contents each frame at the layer's live orbit time.
        orrerySwarmCount = model.swarm.count
        if orrerySwarmCount > orrerySwarmCapacity {
            orrerySwarmCapacity = orrerySwarmCount
            orrerySwarmBuffer = device.makeBuffer(
                length: max(orrerySwarmCapacity, 1) * MemoryLayout<AmbientVertex>.stride,
                options: .storageModeShared)
        }
```

- [ ] **Step 6: Encode the swarm draw**

In `encodeOrreryLayer`, add two parameters to the signature (after `beltBuffer: MTLBuffer?, beltCount: Int,`):

```swift
                                   swarmBuffer: MTLBuffer?, swarmCount: Int,
```

Then, immediately after the belt draw block (the `if let beltBuf = beltBuffer, beltCount > 0 { … }` block), insert:

```swift
        // Swarm moons: the same additive point pass as the belt, but refilled here
        // because they orbit. Positions are generated around `buildCenter` so the
        // shader's `orreryCenter − orreryBuildCenter` rebase lands them correctly on a
        // body-level centre that tracks its planet.
        if let swarmBuf = swarmBuffer, swarmCount > 0 {
            let layout = orreryLayout(model: model, center: buildCenter, scale: scale,
                                      reveal: emergeReveal, time: time)
            let pts = OrreryGeometry.swarmPoints(layout: layout)
            if !pts.isEmpty {
                pts.withUnsafeBytes { src in
                    swarmBuf.contents().copyMemory(from: src.baseAddress!, byteCount: src.count)
                }
                enc.setRenderPipelineState(orreryPointPipeline)
                enc.setDepthStencilState(readDepthState)
                enc.setVertexBuffer(swarmBuf, offset: 0, index: 0)
                enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
                enc.drawPrimitives(type: .point, vertexStart: 0, vertexCount: pts.count)
            }
        }
```

- [ ] **Step 7: Pass the buffer at both call sites**

In `draw`, add `swarmBuffer:`/`swarmCount:` arguments after the existing `beltBuffer:`/`beltCount:` arguments.

For the ACTIVE layer (line 922):

```swift
                        beltBuffer: orreryBeltBuffer, beltCount: orreryBeltCount,
                        swarmBuffer: orrerySwarmBuffer, swarmCount: orrerySwarmCount,
```

For the DEPARTING layer (line 910), pass `nil`/`0`:

```swift
                        beltBuffer: dep.beltBuffer, beltCount: dep.beltCount,
                        // A departing layer draws no swarm: the two layers would need
                        // separate buffers (each rewritten per frame at its own centre)
                        // to avoid clobbering one another, and the band is faint scenery
                        // that is fading out over well under a second. Revisit only if
                        // the swarm visibly pops on zoom-out.
                        swarmBuffer: nil, swarmCount: 0,
```

Lines 280-282 are the *departing-layer snapshot* construction (`lineBuffer:`/`hzBuffer:`/`beltBuffer:` stored into the snapshot struct), not an `encodeOrreryLayer` call. **Leave it unchanged** — the departing layer draws no swarm, so the snapshot needs no swarm buffer.

- [ ] **Step 8: Build and verify**

```bash
swift build --package-path app/Modules --build-tests 2>&1 | tail -20
swift test --package-path app/Modules --filter "Swarm|Orrery"
```

Expected: clean build, all tests pass.

- [ ] **Step 9: Commit**

```bash
git add app/Modules/NewStarMapFeature/Sources/OrreryGeometry.swift \
        app/Modules/NewStarMapFeature/Sources/StarFieldRenderer.swift \
        app/Modules/NewStarMapFeature/Tests/OrreryTests.swift
git commit -m "Draw the moon swarm as an animated additive point band"
```

---

### Task 5: The Moons roster becomes the interaction surface

**Files:**
- Modify: `app/Modules/NewStarMapFeature/Sources/NewStarMapView.swift:1018-1040` (`SystemHUD` properties), `:409-421` (call site), `:1342-1399` (`bodiesCard`, `bodyRow`)

**Interfaces:**
- Consumes: `SystemModel.swarm` from Task 2; the existing `NewStarMapFeature.Action.locationSelected(String)`.
- Produces: `SystemHUD.onSelectLocation: (String) -> Void`.

Swarm members are deliberately not pickable in the 3D view — at ~2 px, clicking the right one of 57 near-identical bodies is frustrating even when it works. Selection therefore flows list → 3D, which is what makes that a design choice rather than a gap.

- [ ] **Step 1: Add the selection callback to `SystemHUD`**

In `NewStarMapView.swift`, add to `SystemHUD`'s properties after `onDrillBody` (line 1031):

```swift
    /// Select a location from the roster list. This is the ONLY way to reach a swarm
    /// moon: swarm members are not pickable in the 3D view, so the list is their
    /// interaction surface (see the many-moon spec).
    let onSelectLocation: (String) -> Void
```

- [ ] **Step 2: Wire it at the call site**

In the `SystemHUD(` initializer at line 409, add after the `onDrillBody:` argument:

```swift
                        onSelectLocation: { store.send(.locationSelected($0)) },
```

- [ ] **Step 3: Rewrite `bodiesCard`**

Replace `bodiesCard` (lines 1342-1368) with:

```swift
    /// Max height for the roster list before it scrolls. A 59-moon roster would
    /// otherwise grow the card past the window.
    private static let rosterMaxHeight: CGFloat = 280

    private var bodiesCard: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            RCSectionHeader(isBody ? "Moons" : "Bodies")
            ScrollView {
                VStack(alignment: .leading, spacing: Space.s) {
                    ForEach(model.planets) { planet in
                        bodyRow(planet)
                    }
                    if !model.swarm.isEmpty {
                        Divider().overlay(.rcSeparator)
                        HStack {
                            Text("Minor bodies")
                                .font(.rcCaption).foregroundStyle(.rcTextSecondary)
                            Spacer()
                            Text("\(model.swarm.count)")
                                .font(.rcMonoSmall).foregroundStyle(.rcTextTertiary)
                        }
                        ForEach(model.swarm) { moon in
                            swarmRow(moon)
                        }
                    }
                }
            }
            .frame(maxHeight: Self.rosterMaxHeight)
            if let hazard = model.hazards.first {
                Divider().overlay(.rcSeparator)
                HStack(spacing: Space.s) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: IconSize.s)).foregroundStyle(.rcError)
                    Text(hazard.title ?? hazard.objectType.replacingOccurrences(of: "_", with: " ").capitalized)
                        .font(.rcCaption).foregroundStyle(.rcTextSecondary)
                    Spacer()
                    if let d = hazard.deadline {
                        Text(d, format: .relative(presentation: .named))
                            .font(.rcMonoSmall).foregroundStyle(.rcError)
                    }
                }
            }
            Divider().overlay(.rcSeparator)
            fact("Devices", "\(model.deviceCount)")
        }
        .padding(Space.m)
        .frame(maxWidth: 240, alignment: .leading)
        .hudGlass()
    }

    /// One swarm-moon row. Selecting it drives the shared location dossier (and, via
    /// `selectedLocation`, the renderer's highlight) — the swarm's only entry point.
    @ViewBuilder private func swarmRow(_ moon: SwarmMoon) -> some View {
        let selected = selectedLocation == moon.designation
        Button { onSelectLocation(moon.designation) } label: {
            HStack(spacing: Space.s) {
                Circle()
                    .fill(selected ? .rcAccent : .rcTextTertiary)
                    .frame(width: 5, height: 5)
                Text(moon.name.map { "\(moon.designation) · \($0)" } ?? moon.designation)
                    .font(.rcMonoSmall)
                    .foregroundStyle(selected ? .rcTextPrimary : .rcTextSecondary)
                Spacer()
                Text(moon.type ?? "—").font(.rcCaption).foregroundStyle(.rcTextTertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
```

- [ ] **Step 4: Make promoted moon rows selectable at body level**

Replace the tail of `bodyRow` (lines 1392-1398) — currently `if isBody { content } else { Button … }` — with:

```swift
        if isBody {
            // At body level a row selects the moon (there is nothing deeper to drill
            // into), driving the same dossier a 3D pick would.
            Button { onSelectLocation(planet.designation) } label: { content }
                .buttonStyle(.plain)
        } else {
            Button { onDrillBody(planet.designation) } label: { content }
                .buttonStyle(.plain)
                .disabled(isTransitioning)
        }
```

- [ ] **Step 5: Build and verify**

```bash
swift build --package-path app/Modules 2>&1 | tail -20
swift test --package-path app/Modules --filter NewStarMapFeatureTests
```

Expected: clean build, tests pass. If `RCSectionHeader`, `IconSize`, or `hudGlass()` resolve unexpectedly, they are pre-existing symbols in this file — do not redefine them.

- [ ] **Step 6: Commit**

```bash
git add app/Modules/NewStarMapFeature/Sources/NewStarMapView.swift
git commit -m "Make the body-level moon roster scrollable and selectable"
```

---

## Phase 2 — Size honesty

### Task 6: Widen the moon size range

**Files:**
- Modify: `app/Modules/NewStarMapFeature/Sources/OrreryMapping.swift:355-361` (`moonSizeFraction`)
- Test: `app/Modules/NewStarMapFeature/Tests/OrreryTests.swift`

**Interfaces:**
- Produces: `OrreryMapping.moonSizeFraction(_ m: Moon) -> Double` (same signature, new range).

- [ ] **Step 1: Write the failing tests**

Append to `OrreryTests.swift`:

```swift
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
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
swift test --package-path app/Modules --filter MoonSizeHonestyTests
```

Expected: FAIL — `sizeRangeIsWideEnoughToReadAsDifferentKindsOfBody` (ratio is 1.49, not > 4) and `unscannedMoonSitsAtTheLowEndNotTheMiddle` (0.14 > 0.07).

- [ ] **Step 3: Widen the curve**

Replace `moonSizeFraction` (lines 355-361) with:

```swift
    /// Moon display radius as a *fraction of the central planet's* rendered radius —
    /// from real `radiusEarth` when scanned, else a small default. The scene radius is
    /// `centralScene · fraction`.
    ///
    /// The span is deliberately wide. Real moon radii inside ONE system cover a 1000×
    /// range (SOL-5: 0.0004 → 0.413 R⊕); the previous curve
    /// (`min(0.30, 0.10 + 0.08·√rₑ)`) compressed that to 1.49× on screen, so a captured
    /// rock rendered as a sphere barely smaller than a major moon. A body's SIZE now
    /// carries real information; legibility is the job of the label/pip overlays, which
    /// have a minimum screen size, and of the HUD roster.
    static func moonSizeFraction(_ m: Moon) -> Double {
        guard let re = m.physical?.radiusEarth, re > 0 else { return unscannedMoonSizeFraction }
        return min(0.30, 0.022 + 0.42 * pow(re, 0.62))
    }

    /// An unscanned moon's size. Near the FLOOR of the range, not the middle: the old
    /// mid-range default out-sized most known moons, so an uncharted body looked more
    /// substantial than a measured one — the exact inversion of what it should convey.
    static let unscannedMoonSizeFraction: Double = 0.045
```

Check the intended values: `rₑ = 0.0004` → `0.022 + 0.42 · 0.0004^0.62 ≈ 0.0295`; `rₑ = 0.413` → `0.022 + 0.42 · 0.413^0.62 ≈ 0.256`. Ratio ≈ 8.7×, both inside the asserted bounds.

- [ ] **Step 4: Run the tests to verify they pass**

```bash
swift test --package-path app/Modules --filter "MoonSizeHonestyTests|MoonSwarmLayoutTests|OrreryMappingTests"
```

Expected: PASS. If `bodyModelBuildsCentralPlanetAndMoons` now fails its clearance assertion, that is a genuine signal: smaller moons should only make clearance *easier*, so investigate rather than loosen the assertion.

- [ ] **Step 5: Commit**

```bash
git add app/Modules/NewStarMapFeature/Sources/OrreryMapping.swift \
        app/Modules/NewStarMapFeature/Tests/OrreryTests.swift
git commit -m "Widen moon size range and drop the unscanned default to the floor"
```

---

## Phase 3 — One shared orbital plane

Everything from here needs a visual pass: it changes what ringed and tilted planets look like at *both* focus levels, and shader/renderer output cannot be verified from a background job (the Keychain login wall blocks launching a scratch build). Land Phase 1–2 first and get eyes on this phase before Phase 4.

### Task 7: Compressed obliquity and the two knobs

**Files:**
- Modify: `app/Modules/NewStarMapFeature/Sources/BodySpin.swift`
- Test: `app/Modules/NewStarMapFeature/Tests/OrreryTests.swift:776-880` (`BodySpinTests`)

**Interfaces:**
- Produces: `BodySpin.tiltCapDeg: Double` (stored, default 38, 90 disables compression); `BodySpin.renderObliquityDeg: Double`; `BodySpin.compress(_ planeTilt: Double, capDeg: Double) -> Double`; `BodySpin.planeBasis(pole:) -> (x:, normal:, z:)`; `OrreryPlaneOptions`.

- [ ] **Step 1: Write the failing tests**

Append to `OrreryTests.swift`:

```swift
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
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
swift test --package-path app/Modules --filter BodySpinPlaneTests
```

Expected: FAIL — `BodySpin has no member 'renderObliquityDeg'`, no `tiltCapDeg:` parameter, no `planeBasis`.

- [ ] **Step 3: Add the cap, the curve, and the shared basis**

In `BodySpin.swift`, add the stored property after `tidallyLocked` (line 30):

```swift
    /// Cap (degrees) on how much of a body's obliquity the RENDERED plane expresses —
    /// the plane its rings, its surface frame, and its moon orbits all share.
    ///
    /// A cap is needed because `TurntableCamera` frames at ~29° elevation and clamps at
    /// ±80°: against SOL-7's 97.77° the shared plane sits near-perpendicular to the
    /// orbital plane and every orbit collapses toward a line. Compressing the range is
    /// the same move `spinRate` already makes for a 588× rotation-period spread.
    ///
    /// `90` disables compression (fully physical); `0` flattens every plane into the
    /// orbital plane. Only extremes are affected at the default — Saturn's 26.73° is
    /// untouched.
    var tiltCapDeg: Double = 38
```

Add after `obliquityDeg` (line 43):

```swift
    /// The obliquity the RENDERER uses — `obliquityDeg` with its plane tilt compressed
    /// toward `tiltCapDeg`. Every visual consumer reads this (via `pole`), which is what
    /// makes it structurally impossible for the ring plane, the surface bands, and the
    /// moon orbits to disagree about where this body's equator is.
    ///
    /// `obliquityDeg` itself is left alone: `isRetrograde` and the dossier report what
    /// the scan actually said.
    var renderObliquityDeg: Double {
        let theta = obliquityDeg
        let planeTilt = min(theta, 180 - theta)          // a plane has no normal sign
        let compressed = Self.compress(planeTilt, capDeg: tiltCapDeg)
        // Preserve the HEMISPHERE. Mapping a past-90° obliquity down below 90 would put
        // the pole back above the orbital plane and cancel the body's retrograde spin —
        // the double-count `sign`'s doc comment warns about. This branch is why the
        // compression can never introduce that bug.
        return theta <= 90 ? compressed : 180 - compressed
    }

    /// Identity below a knee, then asymptotic to `capDeg`. `capDeg >= 90` is the
    /// identity (nothing to compress); `capDeg == 0` flattens.
    static func compress(_ planeTilt: Double, capDeg: Double) -> Double {
        guard capDeg < 90 else { return planeTilt }
        guard capDeg > 0 else { return 0 }
        let knee = min(capDeg * 0.8, 30)
        guard planeTilt > knee else { return planeTilt }
        let room = capDeg - knee
        guard room > 0 else { return capDeg }
        return knee + room * (1 - exp(-(planeTilt - knee) / room))
    }
```

Change `pole(seed:)` (line 63-67) to read the compressed value:

```swift
    /// The body's north pole as a unit vector: +Y tilted by `renderObliquityDeg` about
    /// an azimuth taken from the body's stable appearance seed, so two worlds sharing a
    /// tilt don't lean the same way. Reads the COMPRESSED obliquity — this is the single
    /// pole the rings, the surface frame, and the moon orbits are all built from.
    func pole(seed: Float) -> SIMD3<Float> {
        let obl = Float(renderObliquityDeg) * .pi / 180
        let az = seed * 2 * .pi
        return SIMD3(sin(obl) * cos(az), cos(obl), sin(obl) * sin(az))
    }
```

Replace `frame(seed:)` (lines 126-131) so the basis has exactly one construction:

```swift
    /// The orthonormal basis around a pole, as (x, normal, z) columns.
    ///
    /// SYNC POINT: `orrery_body_fragment` and `orrery_ring_vertex` build this exact
    /// basis on the GPU. It MUST be right-handed (determinant +1): building `z` as
    /// `cross(pole, x)` instead of `cross(x, pole)` yields a reflection, which mirrors
    /// the sphere and makes every planet appear to spin backwards. That shipped once;
    /// `planeBasisIsRightHanded` and `bodyFrameIsRightHanded` exist so it cannot ship
    /// again unnoticed.
    static func planeBasis(pole: SIMD3<Float>) -> (x: SIMD3<Float>, normal: SIMD3<Float>, z: SIMD3<Float>) {
        let p = simd_normalize(pole)
        let ref: SIMD3<Float> = abs(p.y) > 0.99 ? SIMD3(1, 0, 0) : SIMD3(0, 1, 0)
        let x = simd_normalize(simd_cross(ref, p))
        return (x, p, simd_cross(x, p))
    }

    /// The body's orthonormal texturing frame as (x, pole, z) columns — the frame the
    /// surface shader transforms into so every latitude feature tilts with the body.
    /// Delegates to `planeBasis` so the moon orbit plane and the ring plane are built
    /// from the identical construction.
    func frame(seed: Float) -> (x: SIMD3<Float>, pole: SIMD3<Float>, z: SIMD3<Float>) {
        let b = Self.planeBasis(pole: pole(seed: seed))
        return (b.x, b.normal, b.z)
    }
```

- [ ] **Step 4: Update the two existing obliquity tests that encoded uncompressed behavior**

`BodySpinTests.obliquityNormalizesOutOfRangeTilt` (line 814) asserts on `obliquityDeg`, which this task does not change — leave it as is.

Add one test beside it so the distinction is explicit:

```swift
    @Test func reportedObliquityIsUnaffectedByTheRenderCap() {
        // `obliquityDeg` is what the scan said; `renderObliquityDeg` is what we draw.
        // Keeping them separate is what lets the dossier stay truthful.
        let uranus = BodySpin(tiltDeg: 97.77)
        #expect(abs(uranus.obliquityDeg - 97.77) < 1e-9)
        #expect(uranus.renderObliquityDeg != uranus.obliquityDeg)
    }
```

- [ ] **Step 5: Add `OrreryPlaneOptions`**

In `OrreryMapping.swift`, insert just above `static func bodyModel` :

```swift
    /// The user-facing plane knobs, passed in rather than read from storage so
    /// `bodyModel` stays a pure function (and the compression stays unit-testable).
    /// `NewStarMapFeature` supplies the live values from `@Shared(.appStorage(...))`.
    struct OrreryPlaneOptions: Equatable, Sendable {
        /// See `BodySpin.tiltCapDeg`. 90 = fully physical, 0 = fully planar.
        var tiltCapDeg: Double = 38
        /// Escape hatch: moons stay in the orbital plane regardless of the planet's
        /// tilt, while its rings keep the tilt. Reproduces the pre-coupling look.
        var decoupleMoonPlane: Bool = false

        static let `default` = OrreryPlaneOptions()

        static let tiltCapKey = "orreryMoonPlaneTiltCapDeg"
        static let decoupleKey = "orreryDecoupleMoonPlane"
    }
```

- [ ] **Step 6: Run the tests**

```bash
swift test --package-path app/Modules --filter BodySpin
```

Expected: PASS — both `BodySpinTests` and `BodySpinPlaneTests`.

- [ ] **Step 7: Commit**

```bash
git add app/Modules/NewStarMapFeature/Sources/BodySpin.swift \
        app/Modules/NewStarMapFeature/Sources/OrreryMapping.swift \
        app/Modules/NewStarMapFeature/Tests/OrreryTests.swift
git commit -m "Compress rendered obliquity so rings, surface, and moons share one plane"
```

---

### Task 8: Moon orbits follow the shared plane

**Files:**
- Modify: `app/Modules/NewStarMapFeature/Sources/OrreryModels.swift` (`CentralBody.orbitPole`)
- Modify: `app/Modules/NewStarMapFeature/Sources/OrreryMapping.swift` (`bodyModel` sets it)
- Modify: `app/Modules/NewStarMapFeature/Sources/OrreryLayout.swift` (`OrbitPlane`, plane-aware `radial`)
- Modify: `app/Modules/NewStarMapFeature/Sources/OrreryGeometry.swift` (`scaffoldLines` tilts rings)
- Modify: `app/Modules/NewStarMapFeature/Sources/StarFieldRenderer.swift` (pass the plane to `scaffoldLines`)
- Modify: `app/Modules/NewStarMapFeature/Sources/NewStarMapFeature.swift` (read the knobs)
- Test: `app/Modules/NewStarMapFeature/Tests/OrreryTests.swift`

**Interfaces:**
- Consumes: `BodySpin.planeBasis(pole:)`, `OrreryPlaneOptions` from Task 7.
- Produces: `CentralBody.orbitPole: SIMD3<Float>?` (nil = flat); a file-scope `OrbitPlane` in `OrreryLayout.swift` (NOT nested in `OrreryLayout`) with `.flat`, `init(pole:)`, and `point(angle:radius:offset:)`; `OrreryLayout.plane` (derived from the model); `bodyModel(planet:options:)`.

- [ ] **Step 1: Write the failing tests**

Append to `OrreryTests.swift`:

```swift
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
        let maxOffset = m.swarm.map { abs($0.offsetScene) }.max() ?? 0
        for s in m.swarm {
            let d = abs(simd_dot(layout.swarmPosition(s), n))
            #expect(d <= maxOffset + 1e-3, "\(s.designation) sits \(d) off the plane")
        }
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
swift test --package-path app/Modules --filter OrbitPlaneTests
```

Expected: FAIL — no `OrreryLayout.plane`, no `orbitPole`, `scaffoldLines` has no `plane:` parameter.

- [ ] **Step 3: Add `CentralBody.orbitPole`**

In `OrreryModels.swift`, add to `CentralBody` after `spin` (line 172):

```swift
    /// The pole the drilled planet's MOON ORBITS are built around — the same compressed
    /// pole its rings and surface use, so all three agree about where its equator is.
    /// `nil` means the moon plane is decoupled and stays in the orbital plane (the
    /// `decoupleMoonPlane` escape hatch), which is also what a system-level layer has.
    var orbitPole: SIMD3<Float>? = nil
```

- [ ] **Step 4: Add `OrbitPlane` and make `radial` plane-aware**

In `OrreryLayout.swift`, add above `struct OrreryLayout` (line 43):

```swift
/// The plane a layer's orbits lie in. At system level this is the flat orbital plane;
/// at body level it is the drilled planet's equatorial plane, so its moons are coplanar
/// with its rings and its surface banding instead of contradicting them.
struct OrbitPlane: Equatable, Sendable {
    var x: SIMD3<Float>
    var normal: SIMD3<Float>
    var z: SIMD3<Float>

    /// The orbital plane (world XZ), normal +Y.
    static let flat = OrbitPlane(x: SIMD3(1, 0, 0), normal: SIMD3(0, 1, 0), z: SIMD3(0, 0, 1))

    /// The plane perpendicular to `pole`. Built through `BodySpin.planeBasis` — the one
    /// construction the surface frame and the ring pass also use — so the three cannot
    /// drift apart, and so its right-handedness is covered by one test.
    init(pole: SIMD3<Float>) {
        let b = BodySpin.planeBasis(pole: pole)
        self.init(x: b.x, normal: b.normal, z: b.z)
    }

    init(x: SIMD3<Float>, normal: SIMD3<Float>, z: SIMD3<Float>) {
        self.x = x
        self.normal = normal
        self.z = z
    }

    /// A point at `angle` and `radius` in this plane, `offset` along its normal.
    func point(angle: Float, radius: Float, offset: Float = 0) -> SIMD3<Float> {
        x * (cos(angle) * radius) + z * (sin(angle) * radius) + normal * offset
    }
}
```

Add to `OrreryLayout` after the `timing` property (line 57):

```swift
    /// The plane this layer's orbits lie in — the drilled planet's equatorial plane at
    /// body level, the flat orbital plane otherwise. Derived from the model so no caller
    /// has to thread it through.
    var plane: OrbitPlane {
        guard let pole = model.centralBody?.orbitPole else { return .flat }
        return OrbitPlane(pole: pole)
    }
```

Replace `radial` (lines 181-183):

```swift
    private func radial(_ angle: Float, _ radius: Float) -> SIMD3<Float> {
        center + plane.point(angle: angle, radius: radius)
    }
```

Replace the body of `swarmPosition` (added in Task 3) so the scatter is off the tilted plane rather than off world Y:

```swift
    func swarmPosition(_ m: SwarmMoon) -> SIMD3<Float> {
        let a = swarmAngle(m)
        let r = Float(m.orbitScene) * scale * reveal
        let off = Float(m.offsetScene) * scale * reveal
        return center + plane.point(angle: a, radius: r, offset: off)
    }
```

Note: `lagrangePosition` and `beltAnchor` call `radial` and therefore inherit the plane. That is correct — they only exist on system-level layers, where the plane is `.flat`.

- [ ] **Step 5: Set the pole in `bodyModel`**

Change the signature to accept options:

```swift
    static func bodyModel(planet: Planet, options: OrreryPlaneOptions = .default) -> SystemModel {
```

Where `BodySpin` is constructed for the central body (currently lines 413-415), thread the cap through and capture the pole:

```swift
        let centralSpin = BodySpin(tiltDeg: planet.physical?.axialTiltDeg,
                                   rotationHours: planet.physical?.rotationPeriodHours,
                                   tidallyLocked: planet.physical?.tidallyLocked ?? false,
                                   tiltCapDeg: options.tiltCapDeg)
        let centralSeed = appearanceSeed(designation: planet.designation,
                                        rotationPeriodHours: planet.physical?.rotationPeriodHours)
```

Then in the `CentralBody(...)` initializer, replace the inline `spin:` argument with `spin: centralSpin`, replace the inline `appearanceSeed:` argument with `appearanceSeed: centralSeed`, and add:

```swift
            // One pole for rings, surface, and moon orbits — unless the escape hatch
            // says keep the moons planar.
            orbitPole: options.decoupleMoonPlane ? nil : centralSpin.pole(seed: centralSeed),
```

Also thread the cap into each moon's own spin, so a moon's surface obeys the same rule (find the `spin: BodySpin(tiltDeg: m.physical?.axialTiltDeg, …)` line inside the `moons` map and add `tiltCapDeg: options.tiltCapDeg`).

- [ ] **Step 6: Make `scaffoldLines` plane-aware**

In `OrreryGeometry.swift`, change the signature (line 91) and the ring helper:

```swift
    static func scaffoldLines(model: SystemModel, center: SIMD3<Float>, scale: Float,
                              plane: OrbitPlane = .flat, segments: Int = 128) -> [OrreryLineVertex] {
        var verts: [OrreryLineVertex] = []

        func addRing(radius sceneRadius: Double, color: SIMD4<Float>) {
            let radius = Float(sceneRadius) * scale
            // Rings lie in the LAYER's plane, so a tilted planet's moons never leave the
            // rings they orbit on.
            var prev = center + plane.point(angle: 0, radius: radius)
            for i in 1...segments {
                let a = 2 * Float.pi * Float(i) / Float(segments)
                let p = center + plane.point(angle: a, radius: radius)
                verts.append(OrreryLineVertex(position: SIMD4(prev, 1), color: color))
                verts.append(OrreryLineVertex(position: SIMD4(p, 1), color: color))
                prev = p
            }
        }
```

Leave the kuiper ring, the HZ fill, and the hazard vectors flat — they are system-level features and the plane is `.flat` there anyway.

- [ ] **Step 7: Pass the plane from the renderer**

In `StarFieldRenderer.setOrreryModel` (line 1566), replace the `scaffoldLines` call:

```swift
        let plane = OrreryLayout(model: model, center: orreryCenter, scale: orreryScale,
                                 reveal: 1, time: 0).plane
        let lines = OrreryGeometry.scaffoldLines(model: model, center: orreryCenter,
                                                scale: orreryScale, plane: plane)
```

- [ ] **Step 8: Read the knobs in the reducer**

In `NewStarMapFeature.swift`, add to `State` beside the existing `@Shared` property (line 68):

```swift
        /// Orrery plane knobs. No Preferences UI yet — set via `defaults write` while
        /// the look is being dialled in; promote `decoupleMoonPlane` into the
        /// AccountFeature Settings sheet only if it turns out to be toggled in practice.
        @Shared(.appStorage(OrreryMapping.OrreryPlaneOptions.tiltCapKey))
        var moonPlaneTiltCapDeg: Double = 38
        @Shared(.appStorage(OrreryMapping.OrreryPlaneOptions.decoupleKey))
        var decoupleMoonPlane: Bool = false

        var planeOptions: OrreryMapping.OrreryPlaneOptions {
            .init(tiltCapDeg: moonPlaneTiltCapDeg, decoupleMoonPlane: decoupleMoonPlane)
        }
```

Then find every `OrreryMapping.bodyModel(planet:` call site and pass `options: state.planeOptions` (or `options: planeOptions` where `self` is the state):

```bash
grep -rn "bodyModel(planet:" app/Modules/NewStarMapFeature/Sources
```

- [ ] **Step 9: Run the tests**

```bash
swift build --package-path app/Modules --build-tests 2>&1 | tail -20
swift test --package-path app/Modules --filter "OrbitPlaneTests|OrreryLayoutTests|SwarmLayoutTests|OrreryGeometryTests"
```

Expected: PASS.

- [ ] **Step 10: Commit**

```bash
git add app/Modules/NewStarMapFeature/Sources/OrreryModels.swift \
        app/Modules/NewStarMapFeature/Sources/OrreryMapping.swift \
        app/Modules/NewStarMapFeature/Sources/OrreryLayout.swift \
        app/Modules/NewStarMapFeature/Sources/OrreryGeometry.swift \
        app/Modules/NewStarMapFeature/Sources/StarFieldRenderer.swift \
        app/Modules/NewStarMapFeature/Sources/NewStarMapFeature.swift \
        app/Modules/NewStarMapFeature/Tests/OrreryTests.swift
git commit -m "Put moon orbits in the planet's equatorial plane, with a planar escape hatch"
```

---

## Phase 4 — Irregular bodies

### Task 9: Irregular impostor and tumble for captured asteroids

**Files:**
- Modify: `app/Modules/NewStarMapFeature/CShaderTypes/include/ShaderTypes.h` (document `surfaceExtras.y`)
- Modify: `app/Modules/NewStarMapFeature/Sources/StarFieldRenderer.swift` (`PlacedBody.irregularity`, `bodyUniform`)
- Modify: `app/Modules/NewStarMapFeature/Sources/PlanetMaterial.swift` (classification helper)
- Modify: `app/Modules/NewStarMapFeature/Sources/Orrery.metal` (`orrery_body_fragment`)
- Test: `app/Modules/NewStarMapFeature/Tests/OrreryTests.swift`

**Interfaces:**
- Consumes: `SwarmMoon.isCapturedAsteroid`, `OrreryPlanet.type` from Task 2.
- Produces: `PlanetMaterial.irregularity(type:) -> Float`, `BodySpin.tumbleAxis(seed:) -> SIMD3<Float>`.

Shader output cannot be verified here — the app builds but cannot be launched past the Keychain wall. Everything below is compile-verified and unit-tested on the CPU side only; the visual result needs the user's eyes.

- [ ] **Step 1: Write the failing tests**

Append to `OrreryTests.swift`:

```swift
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
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
swift test --package-path app/Modules --filter IrregularBodyTests
```

Expected: FAIL — no `PlanetMaterial.irregularity`, no `BodySpin.tumbleAxis`.

- [ ] **Step 3: Add the CPU-side helpers**

In `PlanetMaterial.swift`, add to the `PlanetMaterial` namespace:

```swift
    /// How lumpy a body's silhouette and shading should be (0 = a smooth sphere).
    /// Driven off the raw API type rather than `PlanetType` because "Captured Asteroid"
    /// is a MOON type with no `PlanetType` case, and it is 18% of every moon in the
    /// live census — the single population that most needs to stop reading as a world.
    static func irregularity(type: String?) -> Float {
        (type ?? "").lowercased().contains("captured") ? 0.45 : 0
    }
```

In `BodySpin.swift`, add:

```swift
    /// A stable, non-axis-aligned tumble axis for a body with no reported pole.
    ///
    /// Irregular satellites are largely non-principal-axis rotators, and captured
    /// asteroids report no `axial_tilt_deg` at all — so routing them through `pole` gives
    /// every one of them an upright axis and they read as tiny planets. Spreading the
    /// axis over the sphere is what makes them read as tumbling rock.
    static func tumbleAxis(seed: Float) -> SIMD3<Float> {
        // Two decorrelated angles from one seed: a full azimuth and a polar angle
        // covering the sphere (not clustered at the poles).
        let az = seed * 2 * .pi
        let polar = acos(1 - 2 * fmod(seed * 7.331 + 0.137, 1))
        return SIMD3(sin(polar) * cos(az), cos(polar), sin(polar) * sin(az))
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
swift test --package-path app/Modules --filter IrregularBodyTests
```

Expected: PASS, 4 tests.

- [ ] **Step 5: Plumb irregularity into the body uniform**

In `ShaderTypes.h`, update the `surfaceExtras` comment in `OrreryBodyUniform`:

```c
    // x = subsurface-ocean cryo-fracture amount (0…1), y = silhouette irregularity
    // (0 = smooth sphere; >0 lumps the limb AND the shading normal from ONE noise
    // sample, so the outline and the terminator agree), zw reserved.
    simd_float4 surfaceExtras;
```

In `StarFieldRenderer.swift`, add to `PlacedBody` after `ocean` (line 1824):

```swift
        /// Silhouette irregularity (0 = smooth sphere). See `PlanetMaterial.irregularity`.
        var irregularity: Float
```

In `placedOrreryBodies`, add `irregularity: 0` to the CENTRAL body's initializer (a drilled planet is never an asteroid), and to the orbiter initializer add:

```swift
                irregularity: PlanetMaterial.irregularity(type: planet.type),
```

For an irregular body, replace the pole with a tumble axis in the same initializer — change the `spinAxis:` argument to:

```swift
                spinAxis: PlanetMaterial.irregularity(type: planet.type) > 0
                    ? BodySpin.tumbleAxis(seed: planet.appearanceSeed)
                    : planet.spin.pole(seed: planet.appearanceSeed),
```

In `bodyUniform` (line 1911), change the last argument:

```swift
            surfaceExtras: SIMD4(p.ocean, p.irregularity, 0, 0))
```

- [ ] **Step 6: Add the shader branch**

In `Orrery.metal`, add to the `OrreryBodyVaryings` struct (after `float ocean;`, line 237):

```metal
    float  irregular;    // silhouette irregularity (0 = smooth sphere)
```

In `orrery_body_vertex`, after `out.ocean = b.surfaceExtras.x;`:

```metal
    out.irregular = b.surfaceExtras.y;
```

In `orrery_body_fragment`, replace the opening block (from `float d = length(in.uv);` through the `coverage` line) with:

```metal
    float d = length(in.uv);
    if (d > 1.0) discard_fragment();
    float nz = sqrt(saturate(1.0 - d * d));          // hemisphere z → sphere normal
    float3 nView = float3(in.uv, nz);
    float coverage = smoothstep(1.0, 1.0 - fwidth(d) - 0.01, d);   // soft AA limb

    // Reconstruct the real surface direction from the billboard: back-transform the
    // view-space hemisphere by the inverse (transpose) view rotation.
    float3x3 viewRot = float3x3(u.view[0].xyz, u.view[1].xyz, u.view[2].xyz);
    float3 dirWorld = normalize(transpose(viewRot) * nView);

    // --- Irregular bodies (captured asteroids) -----------------------------------
    // ONE 3D noise sample, used twice: it displaces the surface radius (so the shading
    // normal tilts as if the rock were lumpy) and it cuts the silhouette (so the
    // outline is lumpy too). Sharing the sample is what makes the two agree — an
    // alpha-cut against a different field than the normals reads as a sphere behind a
    // ragged hole. No iteration: at the 3–20 px these bodies occupy, displacing the
    // bounding-sphere hit is indistinguishable from tracing the real surface.
    //
    // Deliberately sampled on `dirWorld` (a direction), NOT on a longitude — see the
    // beach-ball note above: anything driven by `atan2(dir.z, dir.x)` pinches at both
    // poles and seams down one meridian.
    if (in.irregular > 0.001) {
        float amp = in.irregular;
        float lump = fbm(dirWorld * 2.7 + in.vseed * 13.0) - 0.5;   // −0.5…0.5
        // Silhouette: push the effective limb in or out with the same field.
        float limb = 1.0 + amp * lump;
        if (d > limb) discard_fragment();
        coverage = smoothstep(limb, limb - fwidth(d) - 0.01, d);
        // Shading: tilt the normal by the field's gradient (finite differences on the
        // sphere — cheap, and only needs to be approximately right at this size).
        const float e = 0.06;
        float3 tx = normalize(cross(fabs(dirWorld.y) > 0.99 ? float3(1,0,0) : float3(0,1,0), dirWorld));
        float3 tz = cross(tx, dirWorld);        // right-handed, same rule as planeBasis
        float gx = fbm(normalize(dirWorld + tx * e) * 2.7 + in.vseed * 13.0) - 0.5 - lump;
        float gz = fbm(normalize(dirWorld + tz * e) * 2.7 + in.vseed * 13.0) - 0.5 - lump;
        float3 bumped = normalize(dirWorld - (tx * gx + tz * gz) * amp * 4.0);
        // Facet the result: snapping toward a coarse quantization reads as flat-shaded
        // chunks, which is the strongest "asteroid" cue at a few pixels across.
        float3 faceted = normalize(round(bumped * 3.0) / 3.0 + bumped * 0.35);
        dirWorld = normalize(mix(bumped, faceted, 0.55));
        nView = normalize(viewRot * dirWorld);
    }
```

Everything downstream already reads `dirWorld` and `nView`, so the surface styles, lighting, and depth write inherit the irregular shape with no further change.

- [ ] **Step 7: Build and verify**

```bash
swift build --package-path app/Modules 2>&1 | tail -30
swift test --package-path app/Modules 2>&1 | tail -10
```

Expected: clean build (the `.metal` file compiles as part of the target's resources) and a green suite. A Metal compile error surfaces as a build failure here — read it carefully, as `fbm` is `static inline` per translation unit and is already available in `Orrery.metal` via `ShaderCommon.h`.

- [ ] **Step 8: Commit**

```bash
git add app/Modules/NewStarMapFeature/CShaderTypes/include/ShaderTypes.h \
        app/Modules/NewStarMapFeature/Sources/PlanetMaterial.swift \
        app/Modules/NewStarMapFeature/Sources/BodySpin.swift \
        app/Modules/NewStarMapFeature/Sources/StarFieldRenderer.swift \
        app/Modules/NewStarMapFeature/Sources/Orrery.metal \
        app/Modules/NewStarMapFeature/Tests/OrreryTests.swift
git commit -m "Render captured asteroids as tumbling irregular impostors"
```

---

## Final verification

- [ ] **Step 1: Full suite via the event stream**

Follow the `swift-test-event-stream` skill (do not scrape console text):

```bash
swift test --package-path app/Modules \
  --event-stream-version 0 \
  --event-stream-output-path /tmp/moon-swarm-tests.jsonl
jq -r 'select(.kind=="test" and .payload.testCase) | .payload' /tmp/moon-swarm-tests.jsonl | head
jq -r 'select(.kind=="issueRecorded")' /tmp/moon-swarm-tests.jsonl
```

Expected: no `issueRecorded` entries. Note the skill's multi-target truncation trap — this package has several test targets sharing one output path.

- [ ] **Step 2: Confirm the index store symlink**

```bash
ls -la app/Modules/.build/index-store || app/Modules/scripts/link-index-store.sh
```

- [ ] **Step 3: Report what still needs eyes**

State explicitly in the handoff that Phases 3 and 4 are compile-verified and unit-tested only, and list what to look at: the swarm band's density and brightness, the inclination scatter, the compressed tilt on SOL-6 / SOL-7 / POLARISON-6, and the irregular asteroid silhouette. Offer the two knobs (`orreryMoonPlaneTiltCapDeg` at 0 / 38 / 90, and `orreryDecoupleMoonPlane`) as the comparison levers:

```bash
defaults write name.pennig.replicould orreryMoonPlaneTiltCapDeg -float 0
defaults write name.pennig.replicould orreryDecoupleMoonPlane -bool YES
```

## Self-Review Notes

Spec coverage check — every section maps to a task:

| Spec section | Task |
| --- | --- |
| §1 Tiering (interest, top-K, ≤8 passthrough, anchor safety) | 1, 2 |
| §2 Swarm band (one annulus, size-derived extent, radius/phase/inclination, emergent gaps, belt point pass, motion) | 2, 3, 4 |
| §3 Size honesty (widened range, low unscanned default) | 6 |
| §3 Irregular impostor + tumble | 9 |
| §4 Coupled plane, compressed obliquity, `θ ≤ 90` invariant, one pole | 7, 8 |
| §5 Two knobs, appStorage, no UI | 7, 8 |
| §6 Roster card (scroll, select, group, highlight) | 5 |
| Testing: `frameScene` O(1), small-roster identity, promotion rules, anchor safety, band stability, obliquity table | 1, 2, 6, 7 |

Two deliberate deviations from the spec, both noted at the point of decision:

1. **The departing orrery layer draws no swarm** (Task 4, Step 7). Two layers rendering in one frame would each need their own per-frame-rewritten buffer. The band is faint scenery fading out over well under a second, so the cost is not worth the complexity. Flagged in a code comment as the thing to revisit if it pops.
2. **Swarm animation is a per-frame CPU rewrite**, not GPU-side animation from `u.time`. GPU animation would need a new vertex struct and a new shader — and shader changes cannot be visually verified from this environment. At ≤60 points the memcpy is free. Noted as a future option if profiling ever disagrees.
