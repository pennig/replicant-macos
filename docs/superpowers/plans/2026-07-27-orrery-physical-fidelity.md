# Orrery Physical Fidelity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the orrery use the physical data the backend already sends (rings, axial tilt, rotation and orbital periods, and the moon block), fix the volcanic beach-ball artifact and overscaled volcanism, and remove the body-level orbit freeze so the orrery never pauses.

**Architecture:** Physical facts enter through `UniverseModels` (one decoding gap to close), are folded into two new value types on the orrery model (`BodySpin`, `RingSystem`), and reach the GPU through additional `OrreryBodyUniform` fields plus one new render pass for rings. The pause is removed by making the body-level orrery centre track the drilled planet's live orbital position each frame, which makes the zoom-out seamless by construction rather than by reconciliation.

**Tech Stack:** Swift 6 / SwiftPM, Metal (raw renderer, not SceneKit), Swift Testing, TCA for the feature reducer.

**Spec:** `docs/superpowers/specs/2026-07-27-orrery-physical-fidelity-design.md`

## Global Constraints

- macOS 26+ target. Latest SwiftUI/SDK APIs are fine.
- Never hard-code colors, spacing, or font sizes in SwiftUI — use `DesignSystem.swift` tokens (`.rcTextPrimary`, `Space.m`, `Font.rcCaption`, …). The Metal renderer is the documented exception: it cannot read the asset catalog, so orrery colours live as hexes in `PlanetMaterial`/`OrreryGeometry`.
- Any system or location designation rendered in SwiftUI uses a mono token (`.rcMono`, `.rcMonoSmall`, `.rcHeadlineMono`).
- Logging is `os.Logger` only, never `print`.
- Commits go directly to the working branch. **Do not create a PR and do not push to a remote.**
- `swift` commands run from `app/Modules` (where `Package.swift` lives).
- Test results are read from the Swift Testing JSON event stream, never by grepping console text.
- The persisted `systemDetails.systemJSON` blob is a re-encoded `StarSystem`. New optional fields are additive and need **no** database migration.

## Standard test invocation

Every test step in this plan uses this shape. `--test-product` collapses the run to one process, which is required: under the default `swiftbuild` engine each test target is its own binary and they all truncate the same event-stream file.

```bash
cd app/Modules
swift test --disable-xctest \
  --test-product <Product> \
  --filter '<Regex>' \
  --event-stream-version 0 \
  --event-stream-output-path .build/events.jsonl
```

Then read the result — **never** grep the console:

```bash
# Summary counts
jq -s '
  map(select(.kind=="event").payload) as $e
  | ($e | map(select(.kind=="issueRecorded" and .issue.isFailure != false).testID) | unique) as $failed
  | { total:    ($e | map(select(.kind=="testStarted")) | length),
      failed:   ($failed | length),
      passed:   (($e | map(select(.kind=="testEnded")) | length) - ($failed | length)) }
' .build/events.jsonl

# Failures with source locations
jq -r 'select(.kind=="event").payload
       | select(.kind=="issueRecorded" and .issue.isFailure != false)
       | "\(.issue.sourceLocation.filePath):\(.issue.sourceLocation.line): \(.testID)\n    \(.messages[0].text)"' \
  .build/events.jsonl
```

A `total` of `0` means the `--filter` regex matched nothing — that is a failure, not a pass.

## Shader verification

Metal shaders have no unit-test path. After each shader task:

```bash
cd app
xcodebuild -project Replicould.xcodeproj -scheme Replicould -destination 'platform=macOS' build 2>&1 | tail -20
```

A clean build is the gate. Metal compiles as part of the app target, so a shader syntax error fails the build. Visual confirmation is by screenshot against the SOL bodies listed per task (the app must already be running; a background job cannot launch it past the Keychain login wall).

## File Structure

**Created:**
- `app/Modules/NewStarMapFeature/Sources/BodySpin.swift` — the spin/obliquity value type and its derivations. Pure, no Metal, no SwiftUI.

**Modified:**
- `app/Modules/UniverseModels/Sources/LocationDTOs.swift` — add `orbitalPeriodHours` to `RawBodyPhysical` + its `physical` mapping.
- `app/Modules/UniverseModels/Sources/LocationModels.swift` — add `orbitalPeriodHours` to `BodyPhysical`.
- `app/Modules/NewStarMapFeature/Sources/PlanetMaterial.swift` — `RingSystem` + resolver, `SurfaceModifiers.ocean`, `lavaAmount` retune.
- `app/Modules/NewStarMapFeature/Sources/OrreryModels.swift` — `spin`/`rings` on `OrreryPlanet` and `CentralBody`; moon extras.
- `app/Modules/NewStarMapFeature/Sources/OrreryMapping.swift` — populate the new fields; real moon orbits.
- `app/Modules/NewStarMapFeature/Sources/OrreryLayout.swift` — expose the parent-planet position query used by body tracking.
- `app/Modules/CShaderTypes/include/ShaderTypes.h` — `OrreryBodyUniform.spinAxis`/`surfaceExtras`, `OrreryRingUniform`, `Uniforms.orreryBuildCenter`/`fieldCenter`.
- `app/Modules/NewStarMapFeature/Sources/Orrery.metal` — body-space texturing, sphere depth, volcanic fix, ring pass, scaffold rebasing.
- `app/Modules/NewStarMapFeature/Sources/StarField.metal` — field recession reads `fieldCenter`.
- `app/Modules/NewStarMapFeature/Sources/ShaderCommon.h` — `overlayPushed` reads `fieldCenter`.
- `app/Modules/NewStarMapFeature/Sources/StarFieldRenderer.swift` — uniform packing, ring pass, parent-system tracking, freeze removal.
- `app/Modules/NewStarMapFeature/Sources/TurntableCamera.swift` — `translate(by:)`.
- `app/Modules/NewStarMapFeature/Sources/StarMapViewpoint.swift` — persist the parent system.
- `app/Modules/NewStarMapFeature/Sources/NewStarMapView.swift` — dossier facts.

**Tests:**
- `app/Modules/UniverseModels/Tests/UniverseModelsTests.swift`
- `app/Modules/NewStarMapFeature/Tests/OrreryTests.swift`

---

### Task 1: Decode `orbital_period_hours`

The live moon payload carries `orbital_period_hours` and the decoder drops it, because `RawBodyPhysical` has no such field. Moons carry no `orbital_period_days` either, so today **every** moon orbit speed in the orrery is synthetic. This is the one genuine decoding gap.

**Files:**
- Modify: `app/Modules/UniverseModels/Sources/LocationDTOs.swift` (`RawBodyPhysical`, and its `physical` mapping around line 434)
- Modify: `app/Modules/UniverseModels/Sources/LocationModels.swift` (`BodyPhysical`, around lines 214–259)
- Test: `app/Modules/UniverseModels/Tests/UniverseModelsTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `BodyPhysical.orbitalPeriodHours: Double?`, populated from the wire key `orbital_period_hours` (decoding uses `.convertFromSnakeCase`, so no explicit `CodingKeys` entry is needed).

- [ ] **Step 1: Write the failing test**

The fixture `scannedMoonNoFlagJSON` already exists in this file and already contains `"orbital_period_hours": 165.19`. Add to the suite that decodes moon locations:

```swift
@Test func decodesMoonOrbitalPeriodHours() throws {
    let location = try LocationDecoding.location(from: Data(Fixtures.scannedMoonNoFlagJSON.utf8))
    let moon = try #require(location.moon)
    #expect(moon.physical?.orbitalPeriodHours == 165.19)
    // The sibling moon-only fields must keep decoding alongside it.
    #expect(moon.physical?.orbitalDistanceKm == 174286.7)
    #expect(moon.physical?.tidallyLocked == true)
}
```

If the surrounding suite decodes moons through a different entry point than `LocationDecoding.location(from:)`, match whatever the neighbouring tests in that file already call — do not introduce a new decoding path.

- [ ] **Step 2: Run test to verify it fails**

```bash
cd app/Modules
swift test --disable-xctest --test-product UniverseModelsTests \
  --filter 'decodesMoonOrbitalPeriodHours' \
  --event-stream-version 0 --event-stream-output-path .build/events.jsonl
```

Expected: FAIL — `value of type 'BodyPhysical' has no member 'orbitalPeriodHours'` (a compile error at this stage, which is a legitimate red).

- [ ] **Step 3: Add the field to the domain model**

In `LocationModels.swift`, inside `BodyPhysical`, immediately after `orbitalPeriodDays`:

```swift
    public var orbitalPeriodDays: Double?
    /// Moon orbital period. Moons never report `orbitalPeriodDays` — the backend
    /// gives them hours instead (SOL-3-1 = 655.7, SOL-5-1 = 42.46), so this is the
    /// only real orbit speed a moon has. Nil until the moon is scanned.
    public var orbitalPeriodHours: Double?
```

Add the matching init parameter (keep it adjacent to `orbitalPeriodDays` in the signature so the ordering reads consistently) and the assignment:

```swift
        orbitalPeriodDays: Double? = nil, orbitalPeriodHours: Double? = nil,
```
```swift
        self.orbitalPeriodHours = orbitalPeriodHours
```

- [ ] **Step 4: Add the field to the wire DTO and its mapping**

In `LocationDTOs.swift`, inside `RawBodyPhysical`, next to `orbitalPeriodDays`:

```swift
    var orbitalPeriodDays: Double?
    var orbitalPeriodHours: Double?
```

And in `extension RawBodyPhysical { var physical: BodyPhysical }`, extend the call:

```swift
            rotationPeriodHours: rotationPeriodHours, orbitalPeriodDays: orbitalPeriodDays,
            orbitalPeriodHours: orbitalPeriodHours,
            axialTiltDeg: axialTiltDeg, tags: tags ?? [], tidallyLocked: tidallyLocked,
```

- [ ] **Step 5: Run test to verify it passes**

```bash
cd app/Modules
swift test --disable-xctest --test-product UniverseModelsTests \
  --filter 'decodesMoonOrbitalPeriodHours' \
  --event-stream-version 0 --event-stream-output-path .build/events.jsonl
```

Expected: PASS, `total` ≥ 1.

- [ ] **Step 6: Run the whole UniverseModels suite for regressions**

```bash
cd app/Modules
swift test --disable-xctest --test-product UniverseModelsTests \
  --event-stream-version 0 --event-stream-output-path .build/events.jsonl
```

Expected: `failed: 0`. `BodyPhysical` is `Codable` and persisted inside `systemDetails.systemJSON`; an added optional decodes to `nil` from existing blobs, so the golden-schema and decode tests must stay green.

- [ ] **Step 7: Commit**

```bash
git add app/Modules/UniverseModels
git commit -m "Decode the moon orbital period the API already sends

Moons report orbital_period_hours, never orbital_period_days, and
RawBodyPhysical had no field for it — so the decoder dropped it and every
moon orbit speed in the orrery was synthetic."
```

---

### Task 2: `BodySpin` and `RingSystem` value types

Two small value types so the new facts stay cohesive instead of scattering optionals across `OrreryPlanet`. Pure logic, fully unit-testable, no renderer changes yet.

**Files:**
- Create: `app/Modules/NewStarMapFeature/Sources/BodySpin.swift`
- Modify: `app/Modules/NewStarMapFeature/Sources/PlanetMaterial.swift` (add `RingSystem` beside the existing `AtmosphereShell`, and a resolver beside `atmosphereShell`)
- Test: `app/Modules/NewStarMapFeature/Tests/OrreryTests.swift`

**Interfaces:**
- Consumes: `BodyPhysical.orbitalPeriodHours` (Task 1) is not used here; this task reads `axialTiltDeg`, `rotationPeriodHours`, `tidallyLocked` only at the call site in Task 3.
- Produces:
  - `struct BodySpin { var tiltDeg: Double?; var rotationHours: Double?; var tidallyLocked: Bool }`, with `static let unknown`, `var obliquityDeg: Double`, `var isRetrograde: Bool`, `var sign: Float`, `func pole(seed: Float) -> SIMD3<Float>`, `func spinRate(fastestHours: Double, baseRate: Float, falloff: Float) -> Float`.
  - `struct RingSystem { var innerFrac: Float; var outerFrac: Float; var seed: Float; var tint: SIMD3<Float> }`.
  - `PlanetMaterial.ringSystem(hasRings: Bool, type: PlanetType, seed: Float) -> RingSystem?`.

- [ ] **Step 1: Write the failing tests**

Append a new suite to `OrreryTests.swift`:

```swift
struct BodySpinTests {
    // Real SOL values, probed from locations/SOL-{2,5,6,7}.
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
        // Defensive only — the backend reports 0…180. A stray value must still
        // land on a sane obliquity rather than sending the pole somewhere absurd.
        #expect(abs(BodySpin(tiltDeg: 200).obliquityDeg - 160) < 1e-9)
        #expect(abs(BodySpin(tiltDeg: 380).obliquityDeg - 20) < 1e-9)
        #expect(abs(BodySpin(tiltDeg: -30).obliquityDeg - 30) < 1e-9)
    }

    @Test func unknownTiltIsUpright() {
        #expect(BodySpin.unknown.obliquityDeg == 0)
        #expect(BodySpin.unknown.sign == 1)
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

        // Same tilt, different seed => different lean direction (so two worlds
        // sharing an obliquity don't line up).
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

        // No reading => today's default rate, prograde.
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
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd app/Modules
swift test --disable-xctest --test-product NewStarMapFeatureTests \
  --filter 'BodySpinTests|RingSystemTests' \
  --event-stream-version 0 --event-stream-output-path .build/events.jsonl
```

Expected: FAIL — `cannot find 'BodySpin' in scope`.

- [ ] **Step 3: Create `BodySpin.swift`**

```swift
//
//  BodySpin.swift
//  NewStarMapFeature
//
//  How an orrery body turns: its obliquity, its rotation period, and whether it is
//  tidally locked to its parent. Built from the scan's `axial_tilt_deg` /
//  `rotation_period_hours` / `tidally_locked` (all nil until the body is scanned).
//  Pure + deterministic, so it is unit-tested rather than eyeballed on the GPU.
//

import Foundation
import simd

/// A body's rotation, as the renderer needs it: a pole direction and a signed rate.
///
/// The backend signals retrograde rotation TWO independent ways — a negative
/// `rotationHours` (SOL-2 = −5832.5, SOL-7 = −17.24) and an obliquity past 90°
/// (SOL-2 = 177.4°, SOL-7 = 97.77°), the standard astronomical convention.
///
/// Only the first needs code. The second is pure geometry: past 90° the pole tips
/// below the orbital plane, so a body spinning right-handed about it appears to turn
/// backwards from above. `sign` therefore deliberately IGNORES obliquity — flipping
/// it there too would double-count and cancel a retrograde world back to prograde.
struct BodySpin: Equatable, Sendable {
    /// Axial tilt in degrees, as reported. Nil until scanned.
    var tiltDeg: Double?
    /// Rotation period in hours, signed. Nil until scanned.
    var rotationHours: Double?
    /// Same face always toward the parent — true for essentially every scanned moon.
    var tidallyLocked: Bool = false

    /// An unscanned body: upright, default rate, free-rotating.
    static let unknown = BodySpin()

    /// Obliquity normalized into 0…180°. The backend already reports within that
    /// range (3.13 … 177.4 observed); the wrap is defensive so a stray value can
    /// never aim the pole somewhere absurd.
    var obliquityDeg: Double {
        guard let t = tiltDeg, t.isFinite else { return 0 }
        let wrapped = t.truncatingRemainder(dividingBy: 360)
        let positive = wrapped < 0 ? wrapped + 360 : wrapped
        return positive > 180 ? 360 - positive : positive
    }

    /// Whether this body turns retrograde, by either signal — for the dossier's
    /// label. The RENDERER does not consult this: obliquity is handled by the pole
    /// geometry and the explicit sign by `sign`.
    var isRetrograde: Bool {
        obliquityDeg > 90 || (rotationHours ?? 0) < 0
    }

    /// −1 only when the rotation is *explicitly* called retrograde by a negative
    /// period, else +1. Obliquity deliberately does not flip this — see the type's
    /// note: past 90° the tilted pole already reverses the apparent spin, and
    /// flipping here as well would cancel it back to prograde.
    var sign: Float {
        (rotationHours ?? 0) < 0 ? -1 : 1
    }

    /// The body's north pole as a unit vector: +Y tilted by `obliquityDeg` about an
    /// azimuth taken from the body's stable appearance seed, so two worlds sharing a
    /// tilt don't lean the same way.
    func pole(seed: Float) -> SIMD3<Float> {
        let obl = Float(obliquityDeg) * .pi / 180
        let az = seed * 2 * .pi
        return SIMD3(sin(obl) * cos(az), cos(obl), sin(obl) * sin(az))
    }

    /// Signed spin rate (rad/s), anchored so the FASTEST rotator in the layer turns at
    /// `baseRate` and the spread is compressed by `falloff`. Real periods run
    /// 9.92h…5832.5h — a 588× spread that a linear map either blurs at one end or
    /// freezes at the other. A body with no reading keeps the historical fixed rate.
    func spinRate(fastestHours: Double, baseRate: Float = 0.06, falloff: Float = 0.5) -> Float {
        guard let h = rotationHours, h != 0, h.isFinite, fastestHours > 0 else { return baseRate }
        let ratio = Float(fastestHours / abs(h))
        return sign * baseRate * pow(max(ratio, 1e-6), falloff)
    }
}
```

- [ ] **Step 4: Add `RingSystem` to `PlanetMaterial.swift`**

Immediately after the `AtmosphereShell` declaration (it is the same kind of thing — a per-body appearance shell resolved from scan facts):

```swift
/// A ring system, drawn as a flat annulus in the body's equatorial plane (see
/// `orrery_ring_fragment`). `innerFrac`/`outerFrac` are multiples of the body's
/// rendered radius; `seed` places the gaps so a body's rings look identical every
/// time it is viewed. Only bodies whose scan reports `rings == true` get one —
/// SOL-6 and SOL-7 are the live examples.
struct RingSystem: Equatable, Sendable {
    var innerFrac: Float
    var outerFrac: Float
    var seed: Float
    var tint: SIMD3<Float>
}
```

And, in `enum PlanetMaterial`, immediately after `atmosphereShell(for:atmosphere:tags:)`:

```swift
    // MARK: - Rings

    /// Resolve a body's ring system, or nil for a body that reports no rings.
    /// Giants carry broad, bright ice rings; a rocky world's are narrower and
    /// dustier. The band always starts clear of the body's own limb.
    static func ringSystem(hasRings: Bool, type: PlanetType, seed: Float) -> RingSystem? {
        guard hasRings else { return nil }
        let giant = type.isGiant
        return RingSystem(
            innerFrac: giant ? 1.35 : 1.25,
            outerFrac: giant ? 2.30 : 1.85,
            seed: seed,
            tint: OrreryGeometry.rgb(hex: giant ? "#d8cfb4" : "#9c9186"))
    }
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
cd app/Modules
swift test --disable-xctest --test-product NewStarMapFeatureTests \
  --filter 'BodySpinTests|RingSystemTests' \
  --event-stream-version 0 --event-stream-output-path .build/events.jsonl
```

Expected: PASS, `failed: 0`, `total` = 10.

- [ ] **Step 6: Commit**

```bash
git add app/Modules/NewStarMapFeature/Sources/BodySpin.swift \
        app/Modules/NewStarMapFeature/Sources/PlanetMaterial.swift \
        app/Modules/NewStarMapFeature/Tests/OrreryTests.swift
git commit -m "Add BodySpin and RingSystem

BodySpin turns axial_tilt_deg / rotation_period_hours / tidally_locked
into a pole vector and a signed, compressed spin rate. Retrograde needs
no special case in the renderer: a body whose obliquity aims its pole
downward reads retrograde from the geometry alone, so sign honours only
an explicitly negative period."
```

---

### Task 3: Carry the new facts onto the orrery model

Wire `BodySpin`, `RingSystem`, and the moon extras through `OrreryModels` and `OrreryMapping`. Still no renderer change — this task ends with the model carrying the data and tests proving it.

**Files:**
- Modify: `app/Modules/NewStarMapFeature/Sources/OrreryModels.swift`
- Modify: `app/Modules/NewStarMapFeature/Sources/OrreryMapping.swift`
- Test: `app/Modules/NewStarMapFeature/Tests/OrreryTests.swift`

**Interfaces:**
- Consumes: `BodySpin`, `RingSystem`, `PlanetMaterial.ringSystem(hasRings:type:seed:)` (Task 2); `BodyPhysical.orbitalPeriodHours` (Task 1).
- Produces: on `OrreryPlanet` — `var spin: BodySpin`, `var rings: RingSystem?`, `var hasSubsurfaceOcean: Bool`, `var orbitalDistanceKm: Double?`. On `CentralBody` — `var spin: BodySpin`, `var rings: RingSystem?`. **`hasRing: Bool` is removed from both** and replaced by `rings`.

- [ ] **Step 1: Write the failing tests**

Append to `OrreryTests.swift`:

```swift
struct OrreryPhysicalFactsTests {
    /// A scanned, ringed, tilted gas giant modelled on SOL-6.
    private func saturnLikeSystem() -> StarSystem {
        StarSystem(
            designation: "SOL", name: "Sol", star: nil,
            planets: [
                Planet(
                    designation: "SOL-6", type: "Gas Giant", recon: .scanned,
                    orbitalDistanceAu: 9.537,
                    physical: BodyPhysical(
                        radiusEarth: 9.45, surfaceTempC: -139,
                        rings: true, rotationPeriodHours: 10.66,
                        orbitalPeriodDays: 10747, axialTiltDeg: 26.73))
            ],
            belts: [], structures: [])
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
        // Modelled on SOL-5-2 (Europa): locked, subsurface ocean, no atmosphere.
        let planet = Planet(
            designation: "SOL-5", type: "Gas Giant", recon: .scanned,
            orbitalDistanceAu: 5.203,
            physical: BodyPhysical(rings: false, rotationPeriodHours: 9.92,
                                   orbitalPeriodDays: 4331, axialTiltDeg: 3.13),
            moons: [
                Moon(designation: "SOL-5-2", type: "Icy", recon: .scanned,
                     physical: BodyPhysical(
                        radiusEarth: 0.245, surfaceTempC: -160,
                        tidallyLocked: true, orbitalDistanceKm: 671100,
                        orbitalPeriodHours: 85.23,
                        hasSubsurfaceOcean: true, hasAtmosphere: false))
            ])
        let model = OrreryMapping.bodyModel(planet: planet)
        let moon = try #require(model.planets.first)
        #expect(moon.spin.tidallyLocked)
        #expect(moon.hasSubsurfaceOcean)
        #expect(moon.orbitalDistanceKm == 671100)
        #expect(model.centralBody?.spin.tiltDeg == 3.13)
    }
}
```

If `StarSystem`, `Planet`, or `Moon` initialisers differ from the shape above, copy the construction style used by the existing `mapsRealSystemToPlanetsBeltsHazards` test in this same file rather than inventing one.

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd app/Modules
swift test --disable-xctest --test-product NewStarMapFeatureTests \
  --filter 'OrreryPhysicalFactsTests' \
  --event-stream-version 0 --event-stream-output-path .build/events.jsonl
```

Expected: FAIL — `value of type 'OrreryPlanet' has no member 'spin'`.

- [ ] **Step 3: Extend `OrreryModels.swift`**

In `OrreryPlanet`, replace `var hasRing: Bool` with:

```swift
    /// The body's ring system (nil when the scan reports none). Replaces the old
    /// bare `hasRing` flag, which nothing ever rendered.
    var rings: RingSystem?
    /// How the body turns — obliquity, rotation period, tidal lock. `.unknown`
    /// until scanned, which renders upright at the default rate.
    var spin: BodySpin = .unknown
    /// Moon-only: a subsurface ocean, which draws cryo-fracture lineae.
    var hasSubsurfaceOcean: Bool = false
    /// Moon-only: real orbital distance, which sets the orbit radius at body level.
    var orbitalDistanceKm: Double?
```

In `CentralBody`, replace `var hasRing: Bool` with:

```swift
    var rings: RingSystem?
    var spin: BodySpin = .unknown
```

- [ ] **Step 4: Populate them in `OrreryMapping.swift`**

In `systemModel(from:)`, inside the `OrreryPlanet(...)` construction, replace
`hasRing: p.physical?.rings ?? false,` with:

```swift
                rings: PlanetMaterial.ringSystem(
                    hasRings: p.physical?.rings ?? false,
                    type: PlanetType(apiType: p.type),
                    seed: appearanceSeed(designation: p.designation,
                                         rotationPeriodHours: p.physical?.rotationPeriodHours)),
                spin: BodySpin(tiltDeg: p.physical?.axialTiltDeg,
                               rotationHours: p.physical?.rotationPeriodHours,
                               tidallyLocked: p.physical?.tidallyLocked ?? false),
```

In `bodyModel(planet:maxMoons:)`, in the `CentralBody(...)` construction, replace
`hasRing: planet.physical?.rings ?? false,` with:

```swift
            rings: PlanetMaterial.ringSystem(
                hasRings: planet.physical?.rings ?? false,
                type: PlanetType(apiType: planet.type),
                seed: appearanceSeed(designation: planet.designation,
                                     rotationPeriodHours: planet.physical?.rotationPeriodHours)),
            spin: BodySpin(tiltDeg: planet.physical?.axialTiltDeg,
                           rotationHours: planet.physical?.rotationPeriodHours,
                           tidallyLocked: planet.physical?.tidallyLocked ?? false),
```

And in the moon `OrreryPlanet(...)` construction, replace `hasRing: false,` with:

```swift
                rings: nil,
                spin: BodySpin(tiltDeg: m.physical?.axialTiltDeg,
                               rotationHours: m.physical?.rotationPeriodHours,
                               tidallyLocked: m.physical?.tidallyLocked ?? false),
                hasSubsurfaceOcean: m.physical?.hasSubsurfaceOcean ?? false,
                orbitalDistanceKm: m.physical?.orbitalDistanceKm,
```

- [ ] **Step 5: Fix the remaining `hasRing` references**

```bash
cd app/Modules
grep -rn "hasRing" NewStarMapFeature/ --include=*.swift
```

Expected: no hits. If any remain (a preview fixture, a test), update them to `rings:`. The renderer never read `hasRing`, so there should be nothing else.

- [ ] **Step 6: Run tests to verify they pass**

```bash
cd app/Modules
swift test --disable-xctest --test-product NewStarMapFeatureTests \
  --event-stream-version 0 --event-stream-output-path .build/events.jsonl
```

Expected: `failed: 0` across the whole module — the existing orrery mapping tests must stay green.

- [ ] **Step 7: Commit**

```bash
git add app/Modules/NewStarMapFeature
git commit -m "Carry spin, rings, and the moon block onto the orrery model

Replaces the bare hasRing flag (which nothing rendered) with a resolved
RingSystem, and adds obliquity/rotation/tidal-lock plus the moon's
subsurface-ocean and orbital-distance facts."
```

---

### Task 4: Fix the volcanic beach-ball and scale volcanism down

The smallest change with the most visible effect. `Orrery.metal:118` modulates the molten emissive by `sin(… + lon * 3.0)`. `lon` is `atan2(dir.z, dir.x)` — undefined at both poles and discontinuous at the antimeridian — so it draws three meridian wedges that converge at the poles and rotate with `t`. The banded, iceGiant, and desert styles each already carry an explicit fix for this same artifact, with comments naming it; molten was missed.

**Files:**
- Modify: `app/Modules/NewStarMapFeature/Sources/Orrery.metal` (the `style == 3` branch, lines 110–119)
- Modify: `app/Modules/NewStarMapFeature/Sources/PlanetMaterial.swift` (`lavaAmount`)
- Test: `app/Modules/NewStarMapFeature/Tests/OrreryTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces: no API change. `PlanetMaterial.lavaAmount(tempC:)` keeps its signature; only its range changes.

- [ ] **Step 1: Write the failing test for the CPU half**

The shader is untestable, but the lava *amount* is CPU-side and its ceiling is what stacks with tags into runaway coverage. Add to `OrreryTests.swift`:

```swift
struct VolcanismScaleTests {
    @Test func lavaAmountStaysBelowTheOldCeiling() {
        // Old range was 0.6 … 1.7; scaled down so a tag-stacked hellworld can't
        // push coverage past a crust-with-seams read.
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
        // `hellworld` multiplies by 1.8; the shader clamps lavaAmt to 1.8, so the
        // product must not sail so far past it that temperature stops mattering.
        let mods = PlanetMaterial.modifiers(tags: ["hellworld", "volcanic"])
        let combined = mods.lava * PlanetMaterial.lavaAmount(tempC: 1400)
        #expect(combined <= 2.8)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd app/Modules
swift test --disable-xctest --test-product NewStarMapFeatureTests \
  --filter 'VolcanismScaleTests' \
  --event-stream-version 0 --event-stream-output-path .build/events.jsonl
```

Expected: FAIL on `lavaAmountStaysBelowTheOldCeiling` — current range is 0.6…1.7.

- [ ] **Step 3: Retune `lavaAmount`**

In `PlanetMaterial.swift`, replace the body of `lavaAmount(tempC:)`:

```swift
    /// Temperature multiplier on a molten world's `lava` modifier: cooler volcanic
    /// worlds show thin, dim seams; hotter ones crack wider and glow brighter.
    /// Scaled down from the original 0.6…1.7 band — stacked with a `hellworld`
    /// tag that ceiling drove coverage past half the surface, which read as a lava
    /// world with basalt islands rather than a basalt world with lava seams.
    static func lavaAmount(tempC: Double) -> Float {
        0.5 + 0.95 * smooth01((tempC - 600) / 800)   // 0.5x at <=600C -> 1.45x at >=1400C
    }
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd app/Modules
swift test --disable-xctest --test-product NewStarMapFeatureTests \
  --filter 'VolcanismScaleTests|surfaceTemperatureShapesLavaAndIceCaps' \
  --event-stream-version 0 --event-stream-output-path .build/events.jsonl
```

Expected: PASS. `surfaceTemperatureShapesLavaAndIceCaps` is an existing test that asserts on lava behaviour — if it pins the old numeric range, update its expectations to the new band and keep its *directional* assertions intact.

- [ ] **Step 5: Fix the shader**

In `Orrery.metal`, replace the whole `style == 3` branch:

```c
    } else if (style == 3) {                     // molten — dark crust + glowing cracks
        // `mods.z` (lava×) carries temperature × tag intensity: hotter worlds crack
        // wider AND glow brighter, cooler ones show only thin, dim seams. `detail` is
        // the black-body lava hue the CPU chose from the surface temperature.
        s.albedo = mix(base * 0.55, base, fbm6(dir * 5.0 + sd * 7.0));
        float lavaAmt = mods.z;
        // Coverage threshold. The hot floor is 0.72 (was 0.60) and the ramp is
        // narrower, so even a hellworld reads as seams in basalt rather than the
        // >50% flood the old band produced.
        float lo = mix(0.88, 0.72, saturate((lavaAmt - 0.5) / 1.3));
        float cracks = smoothstep(lo, lo + 0.13, ridge(dir * 8.0 + sd * 3.0));
        // Breathe the glow from 3D NOISE, never longitude. The old
        // `sin(t + lon * 3.0)` drew three meridian wedges that converged at both
        // poles (the beach-ball artifact the banded / iceGiant / desert styles each
        // fix separately) and seamed at the antimeridian. Noise over the sphere
        // direction has neither a pole nor a seam, and it makes separate hot regions
        // pulse independently instead of as one rotating grille.
        float pulse = 0.7 + 0.3 * sin(t * 1.5 + fbm6(dir * 2.3 + sd * 11.0) * 6.283);
        s.emissive = detail * cracks * pulse * 1.4 * clamp(lavaAmt, 0.5, 1.8);
    } else if (style == 4) {                     // ocean / terrestrial — continents (clouds below)
```

- [ ] **Step 6: Verify `lon` is now unused, or still needed**

```bash
cd app/Modules
grep -n "lon" NewStarMapFeature/Sources/Orrery.metal
```

If `float lon = atan2(...)` has no remaining readers, delete the declaration — an unused variable in a shader is a warning and a trap for the next reader. If something else still uses it, leave it.

- [ ] **Step 7: Build to verify the shader compiles**

```bash
cd app
xcodebuild -project Replicould.xcodeproj -scheme Replicould -destination 'platform=macOS' build 2>&1 | tail -20
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 8: Visual check**

Screenshot the running app at SOL-5-1 (Io — a Volcanic moon) and at any volcanic planet. Confirm: no rotating dark bands, no beach-ball convergence at the poles, no seam, and lava reads as seams in dark crust rather than a majority of the surface. If coverage still reads high, raise the `0.88`/`0.72` pair in step 5 and rebuild — the exact numbers depend on the `ridge` distribution and are expected to need one tuning pass.

- [ ] **Step 9: Commit**

```bash
git add app/Modules/NewStarMapFeature
git commit -m "Fix the volcanic beach-ball and scale volcanism down

The molten emissive pulse was modulated by sin(t + lon * 3.0). lon is
atan2(dir.z, dir.x) — undefined at both poles, discontinuous at the
antimeridian — so it drew three rotating meridian wedges converging at
each pole. The banded, iceGiant and desert styles each already fix this
artifact explicitly; molten was missed. Drive the pulse from 3D noise
instead, and raise the crack threshold so lava reads as seams in basalt."
```

---

### Task 5: Axial tilt, rotation rate, and tidal lock on the GPU

Texture every body in its **own** frame. Because `orrerySurface` reads latitude as `dir.y`, transforming `dir` into body space before texturing makes gas bands, polar hoods, ice caps and everything else tilt correctly with no per-style change.

**Files:**
- Modify: `app/Modules/CShaderTypes/include/ShaderTypes.h` (`OrreryBodyUniform`)
- Modify: `app/Modules/NewStarMapFeature/Sources/Orrery.metal` (`OrreryBodyVaryings`, `orrery_body_vertex`, `orrery_body_fragment`)
- Modify: `app/Modules/NewStarMapFeature/Sources/StarFieldRenderer.swift` (body uniform packing)
- Test: `app/Modules/NewStarMapFeature/Tests/OrreryTests.swift`

**Interfaces:**
- Consumes: `OrreryPlanet.spin`, `CentralBody.spin` (Task 3); `BodySpin.pole(seed:)`, `BodySpin.spinRate(fastestHours:baseRate:falloff:)` (Task 2).
- Produces:
  - `OrreryBodyUniform.spinAxis: simd_float4` — `xyz` = body pole (unit, world space), `w` = signed spin rate (rad/s).
  - `OrreryLayout.fastestRotationHours: Double` — the smallest `|rotationHours|` among the layer's bodies, the anchor every spin rate scales off. Returns `1` when nothing in the layer reports a rotation period.

- [ ] **Step 1: Write the failing test**

```swift
struct LayerRotationAnchorTests {
    private func layer(hours: [Double?]) -> OrreryLayout {
        let planets = hours.enumerated().map { i, h in
            OrreryPlanet(
                designation: "SOL-\(i + 1)", name: nil, type: "Gas Giant",
                planetType: .gasGiant, estimated: false, tags: [],
                surfaceTempC: nil, atmosphere: .unknown, appearanceSeed: 0.5,
                orbitalDistanceAu: 1, inHabitableZone: false, scanned: true,
                moonCount: 0, lifeStage: nil, inventory: [],
                semiMajorScene: 10, periodDays: 100, phase0Deg: 0,
                displayRadius: 1, colorHex: "#ffffff", rings: nil,
                spin: BodySpin(rotationHours: h),
                indicators: [], hasInterestingMoon: false, moons: [])
        }
        var model = OrreryMapping.minimal(
            designation: "SOL", position: Position(x: 0, y: 0, z: 0),
            spectralType: "G2", color: "Yellow", name: "Sol")
        model.planets = planets
        return OrreryLayout(model: model, center: .zero, scale: 1, reveal: 1, time: 0)
    }

    @Test func anchorIsTheFastestRotator() {
        #expect(layer(hours: [9.92, 10.66, -5832.5]).fastestRotationHours == 9.92)
    }

    @Test func anchorIgnoresSignAndMissingReadings() {
        // A negative period is retrograde, not "faster than zero" — magnitude wins.
        #expect(layer(hours: [-17.24, 998.5]).fastestRotationHours == 17.24)
        #expect(layer(hours: [nil, 42.0, nil]).fastestRotationHours == 42.0)
    }

    @Test func anchorFallsBackWhenNothingReportsRotation() {
        #expect(layer(hours: [nil, nil]).fastestRotationHours == 1)
    }
}
```

Match the `OrreryPlanet(...)` argument list to whatever it actually is after Task 3 — the existing `OrreryLayoutTests` in this file build one and are the reference.

- [ ] **Step 2: Run test to verify it fails**

```bash
cd app/Modules
swift test --disable-xctest --test-product NewStarMapFeatureTests \
  --filter 'LayerRotationAnchorTests' \
  --event-stream-version 0 --event-stream-output-path .build/events.jsonl
```

Expected: FAIL — `value of type 'OrreryLayout' has no member 'fastestRotationHours'`.

- [ ] **Step 3: Add the anchor to `OrreryLayout.swift`**

Next to the existing `minPeriodDays`:

```swift
    /// The smallest |rotation period| (hours) among this layer's bodies — the anchor
    /// every body's spin rate scales off, so the fastest rotator in view turns at the
    /// base rate and the rest compress below it. 1 when nothing reports a period.
    /// Magnitude, not signed value: a negative period means retrograde, not fast.
    var fastestRotationHours: Double {
        let known = model.planets.compactMap { $0.spin.rotationHours }
            .map(abs).filter { $0 > 0 && $0.isFinite }
        return known.min() ?? 1
    }
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd app/Modules
swift test --disable-xctest --test-product NewStarMapFeatureTests \
  --filter 'LayerRotationAnchorTests' \
  --event-stream-version 0 --event-stream-output-path .build/events.jsonl
```

Expected: PASS, `total` = 3.

- [ ] **Step 5: Add `spinAxis` to the shared struct**

In `ShaderTypes.h`, inside `OrreryBodyUniform`, after `surfaceMods`:

```c
    // Body orientation: xyz = the body's north pole as a unit vector in world space
    // (from its axial tilt), w = signed spin rate in rad/s (negative = retrograde).
    // The fragment textures in the frame this defines, so every latitude feature —
    // gas bands, polar hoods, ice caps — tilts with the body for free.
    simd_float4 spinAxis;
    // x = subsurface-ocean cryo-fracture amount (0…1), yzw reserved.
    simd_float4 surfaceExtras;
```

`surfaceExtras` is added now (rather than in Task 7) so the struct layout changes exactly once.

- [ ] **Step 6: Texture in body space**

In `Orrery.metal`, add to `OrreryBodyVaryings`:

```c
    float3 pole;         // body north pole (unit, world space) — the texturing frame
    float  spinRate;     // signed spin rate (rad/s); negative = retrograde
    float  ocean;        // subsurface-ocean cryo-fracture amount (0…1)
```

In `orrery_body_vertex`, before `return out;`:

```c
    out.pole = b.spinAxis.xyz;
    out.spinRate = b.spinAxis.w;
    out.ocean = b.surfaceExtras.x;
```

In `orrery_body_fragment`, replace the surface-direction block (the `float3x3 viewRot` … `dir = float3(dir.x * cs …)` sequence) with:

```c
    // Reconstruct the real surface direction from the billboard: back-transform the
    // view-space hemisphere by the inverse (transpose) view rotation.
    float3x3 viewRot = float3x3(u.view[0].xyz, u.view[1].xyz, u.view[2].xyz);
    float3 dirWorld = normalize(transpose(viewRot) * nView);

    // Then move into the BODY's own frame, whose +Y is its (tilted) north pole.
    // Everything downstream reads latitude as dir.y, so doing this once here is what
    // makes axial tilt work for every surface style at once — including retrograde
    // worlds, whose pole simply aims downward (SOL-2 at 177.4 degrees).
    float3 pole = normalize(in.pole);
    float3 ref = fabs(pole.y) > 0.99 ? float3(1.0, 0.0, 0.0) : float3(0.0, 1.0, 0.0);
    float3 bx = normalize(cross(ref, pole));
    float3 bz = cross(pole, bx);
    float3x3 bodyFrame = float3x3(bx, pole, bz);          // columns
    float3 dir = transpose(bodyFrame) * dirWorld;         // world -> body

    // Spin about the body's own pole. A tidally locked body arrives with spinRate 0
    // and its orbit angle baked into `seed`, so its near face stays toward its parent.
    float spin = u.time * in.spinRate + in.seed;
    float cs = cos(spin), sn = sin(spin);
    dir = float3(dir.x * cs - dir.z * sn, dir.y, dir.x * sn + dir.z * cs);
```

Then replace the cloud-deck block so the deck shares the same frame:

```c
    float3 toCam = float3(0.0, 0.0, 1.0);                      // distant-camera view dir (view space)
    float3 tang = toCam - dot(toCam, nView) * nView;           // tangential to the sphere here
    float3 nViewCloud = normalize(nView - tang * kCloudHeight);
    float3 cloudWorld = normalize(transpose(viewRot) * nViewCloud);
    float3 cloudDir = transpose(bodyFrame) * cloudWorld;
    float cspin = spin + u.time * kCloudDrift;
    float ccs = cos(cspin), csn = sin(cspin);
    cloudDir = float3(cloudDir.x * ccs - cloudDir.z * csn, cloudDir.y, cloudDir.x * csn + cloudDir.z * ccs);
```

- [ ] **Step 7: Write true sphere depth**

Still in `Orrery.metal`, change `orrery_body_fragment` to return a struct with a depth attachment. The fragment currently writes no depth, so the buffer holds the flat billboard-quad plane; a ring needs the real sphere silhouette to occlude against.

Add above the fragment:

```c
// The body writes TRUE sphere depth, not the billboard quad's flat plane, so
// geometry that intersects the body — the ring annulus above all — is occluded at
// the real silhouette. The reconstructed surface always bulges toward the camera
// relative to the quad plane, so `less` is the correct conservative qualifier.
struct OrreryBodyOut {
    float4 color [[color(0)]];
    float  depth [[depth(less)]];
};
```

Change the signature to `fragment OrreryBodyOut orrery_body_fragment(...)`, and replace the final `return float4(lit, coverage * u.orreryAlpha);` with:

```c
    OrreryBodyOut out;
    out.color = float4(lit, coverage * u.orreryAlpha);
    float4 clip = u.projection * float4(fragView, 1.0);
    out.depth = clip.z / clip.w;
    return out;
```

`fragView` is already computed above for the lighting term.

- [ ] **Step 8: Pack the uniform in the renderer**

Bodies are gathered into a `PlacedBody` list and each is turned into a uniform by
`bodyUniform(_:)` (`StarFieldRenderer.swift:1731`). `PlacedBody` currently carries
`seedDeg`, which `bodyUniform` converts to a spin phase with
`let spin = Float(p.seedDeg) * .pi / 180`.

Compute the spin at *placement* time, where the layout is in scope, and let
`bodyUniform` stay a pure packer. **Replace `seedDeg: Double` on `PlacedBody`** with:

```swift
        /// Spin phase in radians at t = 0. For a free-rotating body this is its stable
        /// per-body offset (so two planets of a type aren't rotated identically); for a
        /// TIDALLY LOCKED body it is the body's orbit angle, which — paired with
        /// `spinRate == 0` — keeps its near face toward its parent as it goes round.
        var spinPhase: Float
        /// The body's north pole (unit, world space) — the frame it is textured in.
        var spinAxis: SIMD3<Float>
        /// Signed spin rate (rad/s); negative is retrograde, 0 is tidally locked.
        var spinRate: Float
        /// Subsurface-ocean cryo-fracture amount (0…1). Filled in Task 7; 0 for now.
        var ocean: Float
        /// The body's ring system, if it has one. Consumed by the ring pass in Task 6.
        var rings: RingSystem?
```

In the placement function, for the **central body**:

```swift
            let centralSpin = central.spin
            placed.append(PlacedBody(
                // …existing arguments unchanged…
                spinPhase: Float(OrreryMapping.phaseDeg(model.star.designation)) * .pi / 180,
                spinAxis: centralSpin.pole(seed: central.appearanceSeed),
                // A central body is not an orbiter of its own layer, so it never locks here.
                spinRate: centralSpin.spinRate(fastestHours: layout.fastestRotationHours),
                ocean: 0,
                rings: central.rings))
```

and for each **orbiter**:

```swift
            // A tidally locked body does not spin freely: its near face tracks its
            // parent, so the rate is zero and its ORBIT ANGLE is the spin phase.
            let locked = planet.spin.tidallyLocked
            placed.append(PlacedBody(
                // …existing arguments unchanged…
                spinPhase: locked ? layout.orbiterAngle(planet)
                                  : Float(planet.phase0Deg) * .pi / 180,
                spinAxis: planet.spin.pole(seed: planet.appearanceSeed),
                spinRate: locked ? 0
                                 : planet.spin.spinRate(fastestHours: layout.fastestRotationHours),
                ocean: 0,
                rings: planet.rings))
```

Then in `bodyUniform(_:)`, delete `let spin = Float(p.seedDeg) * .pi / 180` and use the
precomputed values:

```swift
        return OrreryBodyUniform(
            centerRadius: SIMD4(p.center, p.radius),
            color: SIMD4(s.base, s.polarIce),
            sunEmissive: SIMD4(p.sun, s.greenVibrancy),
            detailColor: SIMD4(s.detail, Float(s.style.rawValue)),
            surfaceParams: SIMD4(s.estimated ? 1 : 0, s.life, p.spinPhase, p.appearanceSeed),
            surfaceMods: SIMD4(s.mods.craters, s.mods.atmosphere, s.mods.lava, s.mods.frost),
            spinAxis: SIMD4(p.spinAxis, p.spinRate),
            surfaceExtras: SIMD4(p.ocean, 0, 0, 0))
    }
```

`layout.orbiterAngle(planet)` already returns radians, and it is the same value the
body's *position* is derived from — which is exactly why locking the phase to it keeps
the near face pointed inward.

- [ ] **Step 9: Build**

```bash
cd app
xcodebuild -project Replicould.xcodeproj -scheme Replicould -destination 'platform=macOS' build 2>&1 | tail -20
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 10: Run the full module suite**

```bash
cd app/Modules
swift test --disable-xctest --test-product NewStarMapFeatureTests \
  --event-stream-version 0 --event-stream-output-path .build/events.jsonl
```

Expected: `failed: 0`.

- [ ] **Step 11: Visual check**

Screenshot: SOL-7 (obliquity 97.77° — bands should run near-vertically, rolled on its side), SOL-2 (177.4° — visibly upside-down and turning backwards), SOL-5 vs SOL-2 side by side (9.92h should visibly outpace 5832.5h without blurring), and any moon at body level (a tidally locked moon must keep one face toward the planet as it orbits).

- [ ] **Step 12: Commit**

```bash
git add app/Modules
git commit -m "Texture orrery bodies in their own tilted frame

Transform the reconstructed sphere direction into a frame whose +Y is the
body's north pole before texturing. Because every surface style reads
latitude as dir.y, one transform tilts gas bands, polar hoods and ice
caps together. Retrograde needs no special case — a body at 177 degrees
obliquity aims its pole down and reads backwards on its own.

Spin rate now comes from rotation_period_hours, compressed against the
fastest rotator in the layer (real periods span 588x). Tidally locked
bodies get rate 0 with their orbit angle as spin phase, so they keep one
face toward their parent.

Bodies also write true sphere depth instead of the billboard quad plane,
which the ring pass needs to occlude correctly."
```

---

### Task 6: Rings

A new pass drawing an annulus in each ringed body's equatorial plane. Depth-read so the body's near hemisphere occludes the far half of the ring; no depth write so the ring occludes nothing.

**Files:**
- Modify: `app/Modules/CShaderTypes/include/ShaderTypes.h` (`OrreryRingUniform`)
- Modify: `app/Modules/NewStarMapFeature/Sources/Orrery.metal` (ring vertex + fragment)
- Modify: `app/Modules/NewStarMapFeature/Sources/StarFieldRenderer.swift` (pipeline state + draw pass)
- Test: `app/Modules/NewStarMapFeature/Tests/OrreryTests.swift`

**Interfaces:**
- Consumes: `OrreryPlanet.rings`, `CentralBody.rings`, `BodySpin.pole(seed:)`.
- Produces: `OrreryRingUniform`; a `ringPipeline` on the renderer; `orrery_ring_vertex` / `orrery_ring_fragment`.

- [ ] **Step 1: Write the failing test**

The GPU work is untestable, but which bodies get a ring draw, and at what radii, is not.

```swift
struct RingDrawListTests {
    @Test func onlyRingedBodiesEnterTheDrawList() throws {
        var system = StarSystem(
            designation: "SOL", name: "Sol", star: nil,
            planets: [
                Planet(designation: "SOL-5", type: "Gas Giant", recon: .scanned,
                       orbitalDistanceAu: 5.203,
                       physical: BodyPhysical(rings: false, axialTiltDeg: 3.13)),
                Planet(designation: "SOL-6", type: "Gas Giant", recon: .scanned,
                       orbitalDistanceAu: 9.537,
                       physical: BodyPhysical(rings: true, axialTiltDeg: 26.73)),
            ],
            belts: [], structures: [])
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
```

- [ ] **Step 2: Run test to verify it fails or passes**

```bash
cd app/Modules
swift test --disable-xctest --test-product NewStarMapFeatureTests \
  --filter 'RingDrawListTests' \
  --event-stream-version 0 --event-stream-output-path .build/events.jsonl
```

These may pass immediately given Tasks 2–3. That is fine — they are a regression guard for the draw list, not a red-first driver for the shader. Record the result and continue.

- [ ] **Step 3: Add the ring uniform**

In `ShaderTypes.h`, after `OrreryAtmosphereUniform`:

```c
// Per-body params for one ring annulus, drawn in the body's EQUATORIAL plane (the
// plane perpendicular to its axial-tilt pole). Alpha-blended and depth-READ after
// the opaque bodies, so the near hemisphere occludes the far half of the ring and
// the ring itself occludes nothing. See orrery_ring_{vertex,fragment}.
typedef struct {
    simd_float4 centerRadius;   // xyz = body world centre, w = body radius
    simd_float4 poleInner;      // xyz = body pole (unit), w = inner radius (x body radius)
    simd_float4 sunOuter;       // xyz = sun world position, w = outer radius (x body radius)
    simd_float4 tintSeed;       // rgb = ring tint, w = band seed
} OrreryRingUniform;
```

- [ ] **Step 4: Write the ring shaders**

In `Orrery.metal`, after the atmosphere pass:

```c
// Ring system — a flat annulus in the body's equatorial plane. The geometry is
// generated from the vertex id (no buffer): `kRingSegments` quads as one triangle
// strip, alternating inner and outer rim vertices.
constant uint kRingSegments = 192;

struct OrreryRingVaryings {
    float4 position [[position]];
    float3 world;      // world position of this ring point (for the shadow test)
    float  t;          // 0 at the inner rim, 1 at the outer rim
    float3 tint;
    float  seed;
    float3 center;     // body centre
    float  bodyRadius;
    float3 sun;
    float3 pole;       // ring plane normal == the body's pole
};

vertex OrreryRingVaryings orrery_ring_vertex(uint vid                        [[vertex_id]],
                                             constant Uniforms&              u   [[buffer(1)]],
                                             constant OrreryRingUniform&     r   [[buffer(2)]])
{
    uint seg = vid / 2;
    bool outerRim = (vid & 1u) == 1u;
    float a = float(seg) / float(kRingSegments) * 2.0 * M_PI_F;

    // Basis for the equatorial plane: two axes perpendicular to the pole.
    float3 pole = normalize(r.poleInner.xyz);
    float3 ref = fabs(pole.y) > 0.99 ? float3(1.0, 0.0, 0.0) : float3(0.0, 1.0, 0.0);
    float3 bx = normalize(cross(ref, pole));
    float3 bz = cross(pole, bx);

    float frac = outerRim ? r.sunOuter.w : r.poleInner.w;
    float radius = r.centerRadius.w * frac;
    float3 world = r.centerRadius.xyz + (bx * cos(a) + bz * sin(a)) * radius;

    OrreryRingVaryings out;
    out.position = u.projection * (u.view * float4(world, 1.0));
    out.world = world;
    out.t = outerRim ? 1.0 : 0.0;
    out.tint = r.tintSeed.rgb;
    out.seed = r.tintSeed.w;
    out.center = r.centerRadius.xyz;
    out.bodyRadius = r.centerRadius.w;
    out.sun = r.sunOuter.xyz;
    out.pole = pole;
    return out;
}

fragment float4 orrery_ring_fragment(OrreryRingVaryings in [[stage_in]],
                                     constant Uniforms&   u [[buffer(1)]])
{
    // Banding: seeded ridged noise across the radius gives stable Cassini-like gaps.
    float band = ridge(float3(in.t * 9.0 + in.seed * 17.0, in.seed * 3.0, 0.0));
    float density = smoothstep(0.30, 0.75, band);
    // Fade both rims so the annulus has no hard edge.
    density *= smoothstep(0.0, 0.12, in.t) * smoothstep(1.0, 0.88, in.t);

    // Openness: how far the ring plane is turned toward the sun. Edge-on to the sun
    // (dot ~ 0) the ring is lit only across its thickness and nearly vanishes;
    // face-on it reads bright.
    float3 toSun = normalize(in.sun - in.center);
    float open = saturate(fabs(dot(toSun, normalize(in.pole))));
    float lit = mix(0.30, 1.0, open);

    // Planet shadow on the ring: march from this ring point toward the sun and test
    // whether the ray passes within the body. Analytic, and the detail that sells it.
    float3 L = normalize(in.sun - in.world);
    float3 toCenter = in.center - in.world;
    float s = dot(toCenter, L);
    float shadow = 1.0;
    if (s > 0.0) {
        float miss = length(toCenter - L * s);
        shadow = smoothstep(in.bodyRadius * 0.92, in.bodyRadius * 1.12, miss);
    }
    shadow = mix(0.18, 1.0, shadow);

    float alpha = density * u.orreryAlpha;
    return float4(in.tint * (lit * shadow), alpha);
}
```

- [ ] **Step 5: Add the pipeline state**

In `StarFieldRenderer.swift`, build `ringPipeline` alongside the existing atmosphere pipeline. Match the atmosphere pass's descriptor except:
- vertex function `orrery_ring_vertex`, fragment `orrery_ring_fragment`
- **alpha blending** (`sourceRGBBlendFactor = .sourceAlpha`, `destinationRGBBlendFactor = .oneMinusSourceAlpha`), not additive — a ring occludes what is behind it
- depth descriptor: `depthCompareFunction = .less`, `isDepthWriteEnabled = false`

- [ ] **Step 6: Encode the ring pass**

Add a `ringUniform(_:)` packer beside the existing `atmosphereUniform(_:)` — it reads
straight off the `PlacedBody` fields Task 5 added, so nothing is recomputed:

```swift
    /// The ring uniform for a placed body, or nil if it has no rings. Same
    /// centre/radius/sun as the body draw so the annulus registers exactly with the
    /// limb, and the same pole so it lies in the body's true equatorial plane.
    private func ringUniform(_ p: PlacedBody) -> OrreryRingUniform? {
        guard let r = p.rings else { return nil }
        return OrreryRingUniform(
            centerRadius: SIMD4(p.center, p.radius),
            poleInner: SIMD4(p.spinAxis, r.innerFrac),
            sunOuter: SIMD4(p.sun, r.outerFrac),
            tintSeed: SIMD4(r.tint, r.seed))
    }
```

Then, after the opaque body pass and beside the atmosphere pass:

```swift
        /// Segment count of the generated ring annulus. SYNC POINT: must match
        /// `kRingSegments` in Orrery.metal, which derives its geometry from vertex_id.
        // (declare once as a private constant on the renderer)
        private let ringSegments = 192

        // …in the encode loop…
        for body in placed {
            guard var ring = ringUniform(body) else { continue }
            enc.setRenderPipelineState(ringPipeline)
            enc.setVertexBytes(&ring, length: MemoryLayout<OrreryRingUniform>.stride, index: 2)
            enc.setFragmentBytes(&ring, length: MemoryLayout<OrreryRingUniform>.stride, index: 2)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0,
                               vertexCount: (ringSegments + 1) * 2)
        }
```

The sync-point comment matters: the codebase already uses this convention where a
Swift value and a shader constant must agree (see `PlanetSurfaceStyle`'s style-index
note). If they drift, the ring silently develops a wedge-shaped gap.

- [ ] **Step 7: Build**

```bash
cd app
xcodebuild -project Replicould.xcodeproj -scheme Replicould -destination 'platform=macOS' build 2>&1 | tail -20
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 8: Run the module suite**

```bash
cd app/Modules
swift test --disable-xctest --test-product NewStarMapFeatureTests \
  --event-stream-version 0 --event-stream-output-path .build/events.jsonl
```

Expected: `failed: 0`.

- [ ] **Step 9: Visual check against SOL-6 and SOL-7**

Both report `rings: true`. Confirm: the ring lies in the body's tilted equatorial plane (SOL-7's should be steeply inclined, matching its 97.77° obliquity); the far half is hidden behind the planet and reappears past the limb; the planet's shadow falls across the ring on the anti-sun side; banding gaps are stable across frames and across re-entry into the system.

- [ ] **Step 10: Decide on ring shadow on the planet**

The spec marks this optional. Add it only if step 9 looks right and there is appetite: in `orrery_body_fragment`, intersect the surface point's ray toward the sun with the ring plane and darken when the hit radius falls inside the band. If it reads as noise at orrery scale, **do not ship it** — say so in the commit message instead of leaving a half-tuned effect in.

- [ ] **Step 11: Commit**

```bash
git add app/Modules
git commit -m "Draw ring systems

A ringed body now draws an annulus in its equatorial plane, generated
from the vertex id with no buffer. Alpha-blended and depth-read after the
opaque bodies, so the near hemisphere occludes the far half of the ring.
Banding gaps come from the body's stable appearance seed, and the planet
casts an analytic shadow across the ring.

rings: true is live on SOL-6 and SOL-7."
```

---

### Task 7: Real moon orbits, atmosphere, and subsurface oceans

Moons currently orbit on a synthetic ladder (`8 + index * 3` days) at index-stepped radii, always render airless, and show nothing for a subsurface ocean. All three facts are in the data.

**Files:**
- Modify: `app/Modules/NewStarMapFeature/Sources/OrreryMapping.swift` (`bodyModel`)
- Modify: `app/Modules/NewStarMapFeature/Sources/PlanetMaterial.swift` (`SurfaceModifiers.ocean`, `surface(for:...)`)
- Modify: `app/Modules/NewStarMapFeature/Sources/Orrery.metal` (cryo-fracture lineae)
- Modify: `app/Modules/NewStarMapFeature/Sources/StarFieldRenderer.swift` (pack `surfaceExtras.x`)
- Test: `app/Modules/NewStarMapFeature/Tests/OrreryTests.swift`

**Interfaces:**
- Consumes: `OrreryPlanet.orbitalDistanceKm`, `.hasSubsurfaceOcean` (Task 3); `BodyPhysical.orbitalPeriodHours` (Task 1); `OrreryBodyUniform.surfaceExtras` (Task 5).
- Produces: `OrreryMapping.moonSceneRadius(km:) -> Double`; `SurfaceModifiers.ocean: Float`.

- [ ] **Step 1: Write the failing tests**

```swift
struct MoonOrbitFidelityTests {
    private func jupiterLike() -> Planet {
        Planet(
            designation: "SOL-5", type: "Gas Giant", recon: .scanned,
            orbitalDistanceAu: 5.203,
            physical: BodyPhysical(rings: false, rotationPeriodHours: 9.92,
                                   orbitalPeriodDays: 4331, axialTiltDeg: 3.13),
            moons: [
                // Io: nearest and fastest.
                Moon(designation: "SOL-5-1", type: "Volcanic", recon: .scanned,
                     physical: BodyPhysical(radiusEarth: 0.286, tidallyLocked: true,
                                            orbitalDistanceKm: 421700,
                                            orbitalPeriodHours: 42.46,
                                            hasSubsurfaceOcean: false, hasAtmosphere: false)),
                // Europa: farther and slower.
                Moon(designation: "SOL-5-2", type: "Icy", recon: .scanned,
                     physical: BodyPhysical(radiusEarth: 0.245, tidallyLocked: true,
                                            orbitalDistanceKm: 671100,
                                            orbitalPeriodHours: 85.23,
                                            hasSubsurfaceOcean: true, hasAtmosphere: false)),
            ])
    }

    @Test func moonPeriodComesFromHours() throws {
        let model = OrreryMapping.bodyModel(planet: jupiterLike())
        let io = try #require(model.planets.first { $0.designation == "SOL-5-1" })
        let europa = try #require(model.planets.first { $0.designation == "SOL-5-2" })
        #expect(abs(io.periodDays - 42.46 / 24) < 1e-9)
        #expect(abs(europa.periodDays - 85.23 / 24) < 1e-9)
        #expect(io.periodDays < europa.periodDays)     // nearer moon is faster
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
        // Titan: has_atmosphere true plus a thick_atmosphere tag.
        let planet = Planet(
            designation: "SOL-6", type: "Gas Giant", recon: .scanned,
            orbitalDistanceAu: 9.537,
            physical: BodyPhysical(rings: true, axialTiltDeg: 26.73),
            moons: [
                Moon(designation: "SOL-6-1", type: "Icy", recon: .scanned,
                     physical: BodyPhysical(tags: ["thick_atmosphere"],
                                            tidallyLocked: true,
                                            orbitalDistanceKm: 1221870,
                                            orbitalPeriodHours: 382.69,
                                            hasSubsurfaceOcean: false, hasAtmosphere: true)),
                Moon(designation: "SOL-6-9", type: "Rocky", recon: .scanned,
                     physical: BodyPhysical(tidallyLocked: true,
                                            orbitalDistanceKm: 12952000,
                                            orbitalPeriodHours: 1000,
                                            hasSubsurfaceOcean: false, hasAtmosphere: false)),
            ])
        let model = OrreryMapping.bodyModel(planet: planet)
        let titan = try #require(model.planets.first { $0.designation == "SOL-6-1" })
        let airless = try #require(model.planets.first { $0.designation == "SOL-6-9" })
        #expect(titan.atmosphere != .unknown)
        #expect(titan.atmosphere != .none)
        #expect(airless.atmosphere == .none)
    }

    @Test func subsurfaceOceanBecomesASurfaceModifier() {
        let plain = PlanetMaterial.surface(for: .frozen, lifeStage: nil, estimated: false)
        #expect(plain.mods.ocean == 0)
        let ocean = PlanetMaterial.surface(for: .frozen, lifeStage: nil, estimated: false,
                                           hasSubsurfaceOcean: true)
        #expect(ocean.mods.ocean > 0)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd app/Modules
swift test --disable-xctest --test-product NewStarMapFeatureTests \
  --filter 'MoonOrbitFidelityTests' \
  --event-stream-version 0 --event-stream-output-path .build/events.jsonl
```

Expected: FAIL — `moonSceneRadius` and the `hasSubsurfaceOcean:` parameter do not exist.

- [ ] **Step 3: Add the moon radial map**

In `OrreryMapping.swift`, next to `sceneRadius(au:)`:

```swift
    /// Compressed km → scene units for moon orbits. Real moon distances span roughly
    /// 1.7e5 … 2.6e7 km within a single system, so the same sqrt compression the
    /// planets get keeps the inner moons legible while the outer ones still frame.
    /// Tuned so a Luna-like 3.8e5 km lands near the old index-stepped first orbit.
    static func moonSceneRadius(km: Double) -> Double {
        0.0068 * (max(km, 0) as Double).squareRoot()
    }
```

- [ ] **Step 4: Use real distance and period in `bodyModel`**

Replace the `base`/`step`/`semiMajorScene` logic. Keep the existing `shown` ordering, then:

```swift
        // Real orbit radii where the scan gives them, else the historical index step,
        // then the SAME non-overlap pass the planets get — so no moon orbit ever falls
        // inside the central body or another moon.
        let base = centralScene * 1.7          // first moon clears the planet + a gap
        let step = centralScene * 0.5
        let rawOrbits = shown.enumerated().map { i, m -> Double in
            if let km = m.physical?.orbitalDistanceKm, km > 0 {
                return max(moonSceneRadius(km: km), base)
            }
            return base + Double(i) * step
        }
        let moonRadii = shown.map { centralScene * moonSizeFraction($0) }
        let moonLayout = spacedLayout(
            planetOrbits: rawOrbits, planetRadii: moonRadii,
            beltInner: [], beltOuter: [], sunScene: centralScene)
        let moonOrbits = moonLayout.orbits
```

and in the moon `OrreryPlanet(...)`:

```swift
                semiMajorScene: moonOrbits[i],
                periodDays: m.physical?.orbitalPeriodHours.map { $0 / 24 }
                    ?? m.physical?.orbitalPeriodDays
                    ?? (8 + Double(i) * 3),
```

**Ordering caveat:** `spacedLayout` walks occupants by raw radius, and `shown` is sorted interest-first, not distance-first. Sort `shown` by raw orbit before building `rawOrbits` so the spacing pass sees monotonic input, then keep that order for the rest of the construction.

- [ ] **Step 5: Map the moon atmosphere boolean**

Moons receive `has_atmosphere` and never the thickness string, so `Atmosphere(apiValue:)` yields `.unknown` and every moon renders airless. In the moon construction, replace `atmosphere: Atmosphere(apiValue: m.physical?.atmosphere),` with:

```swift
                atmosphere: moonAtmosphere(m),
```

and add the helper next to `moonColor(type:)`:

```swift
    /// A moon's atmosphere thickness. Moons report a `has_atmosphere` BOOLEAN, never
    /// the ordinal string planets get — so reading `physical.atmosphere` alone left
    /// every moon `.unknown`, i.e. permanently airless. A moon with air gets a thin
    /// sky, upgraded to dense when its tags call the atmosphere thick (Titan).
    static func moonAtmosphere(_ m: Moon) -> Atmosphere {
        if let s = m.physical?.atmosphere, case let a = Atmosphere(apiValue: s), a != .unknown {
            return a                                   // an explicit reading always wins
        }
        guard m.physical?.hasAtmosphere == true else {
            return m.physical == nil ? .unknown : .none    // scanned + no air = airless
        }
        let tags = (m.physical?.tags ?? []).map { $0.lowercased() }
        if tags.contains("thick_atmosphere") { return .dense }
        if tags.contains("thin_atmosphere") { return .thin }
        return .thin
    }
```

- [ ] **Step 6: Add the subsurface-ocean modifier**

In `PlanetMaterial.swift`, add to `SurfaceModifiers`:

```swift
    /// Cryo-fracture lineae from a subsurface ocean (0 = none). Moon-only.
    var ocean: Float = 0
```

Add a `hasSubsurfaceOcean: Bool = false` parameter to `surface(for:lifeStage:estimated:tags:surfaceTempC:atmosphere:inHabitableZone:)` and, in the body, before the return:

```swift
        // A subsurface ocean cracks the crust into long cryo-fracture lineae
        // (Europa-like). Deliberately unlike lava: cool tint, no pulsing.
        if hasSubsurfaceOcean { mods.ocean = 1 }
```

Update the call sites in `StarFieldRenderer.swift` to pass `hasSubsurfaceOcean: planet.hasSubsurfaceOcean`.

- [ ] **Step 7: Draw the lineae**

In `Orrery.metal`, in `orrerySurface`, after the frost overlay block and before the cloud block:

```c
    // Subsurface-ocean cryo-fracture lineae — long, cool cracks in the crust where a
    // buried ocean stresses the ice (Europa-like). Deliberately distinct from the
    // molten style's lava: bluish, faintly emissive, and NOT pulsing.
    if (ocean > 0.0) {
        float3 warp = dir + (fbm6(dir * 2.0 + sd * 13.0) - 0.5) * 0.35;
        float lineae = smoothstep(0.74, 0.94, ridge(warp * float3(3.0, 9.0, 3.0) + sd * 6.0));
        float3 crackTint = float3(0.42, 0.62, 0.78);
        s.albedo = mix(s.albedo, crackTint, saturate(lineae * ocean * 0.75));
        s.emissive += crackTint * lineae * ocean * 0.05;    // barest inner glow
    }
```

Add `float ocean` to the `orrerySurface` parameter list and pass `in.ocean` at the call
site in `orrery_body_fragment`.

On the CPU, Task 5 left `PlacedBody.ocean` hard-coded to `0`. Populate it at placement:
`ocean: planet.hasSubsurfaceOcean ? 1 : 0` for orbiters, and `0` for the central body
(a drilled planet's own ocean flag is a moon-level fact and is not modelled on
`CentralBody`). `bodyUniform` already forwards it into `surfaceExtras.x`.

- [ ] **Step 8: Run tests to verify they pass**

```bash
cd app/Modules
swift test --disable-xctest --test-product NewStarMapFeatureTests \
  --event-stream-version 0 --event-stream-output-path .build/events.jsonl
```

Expected: `failed: 0` across the module. The existing `bodyModelBuildsCentralPlanetAndMoons` and `moonCapForceIncludesEveryInterestingMoon` tests exercise this code — if they pin index-stepped radii, update the expectations to the spaced-layout values while keeping their ordering and force-include assertions intact.

- [ ] **Step 9: Build**

```bash
cd app
xcodebuild -project Replicould.xcodeproj -scheme Replicould -destination 'platform=macOS' build 2>&1 | tail -20
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 10: Visual check**

Drill into SOL-5: Io nearest and visibly fastest, Europa farther and slower, both keeping one face to the planet. Europa and SOL-6-2 should show bluish lineae. SOL-6-1 (Titan) should carry a faint haze halo where before it had none.

- [ ] **Step 11: Commit**

```bash
git add app/Modules
git commit -m "Give moons their real orbits, air, and oceans

Moon orbit radii now come from orbital_distance_km through the same sqrt
compression and non-overlap pass the planets get, and periods from
orbital_period_hours — replacing a synthetic 8 + index * 3 day ladder at
index-stepped radii.

Moons report has_atmosphere as a boolean and never the thickness string,
so every moon rendered airless; they now get a thin sky (dense when
tagged thick, as Titan is). has_subsurface_ocean draws cool cryo-fracture
lineae, deliberately unlike the molten style's lava."
```

---

### Task 8: Stop pausing the orrery

`StarFieldRenderer.swift:643` freezes `orbitClock` at body level, which also freezes the drilled planet's **moons** — most of what reads as "paused". The freeze exists so the body view's fixed centre still matches the planet's system position on zoom-out. Track the planet instead, and the reason disappears.

**Files:**
- Modify: `app/Modules/CShaderTypes/include/ShaderTypes.h` (`Uniforms.orreryBuildCenter`, `Uniforms.fieldCenter`)
- Modify: `app/Modules/NewStarMapFeature/Sources/Orrery.metal` (scaffold + belt rebasing)
- Modify: `app/Modules/NewStarMapFeature/Sources/StarField.metal`, `ShaderCommon.h` (recession pivot)
- Modify: `app/Modules/NewStarMapFeature/Sources/TurntableCamera.swift` (`translate(by:)`)
- Modify: `app/Modules/NewStarMapFeature/Sources/StarFieldRenderer.swift`
- Modify: `app/Modules/NewStarMapFeature/Sources/StarMapViewpoint.swift`
- Test: `app/Modules/NewStarMapFeature/Tests/OrreryTests.swift`

**Interfaces:**
- Consumes: `OrreryLayout.orbiterPosition(id:)` (already exists).
- Produces:
  - `TurntableCamera.translate(by delta: SIMD3<Float>)` — shifts `target` and any in-flight framing endpoints.
  - `Uniforms.orreryBuildCenter: simd_float4` — the centre the scaffold buffers were generated around.
  - `Uniforms.fieldCenter: simd_float4` — the focused star, the pivot the background field recedes from.

- [ ] **Step 1: Write the failing test for the camera**

```swift
struct CameraTranslationTests {
    @Test func translateMovesTargetAndEyeTogether() {
        var cam = TurntableCamera()
        cam.target = SIMD3(1, 2, 3)
        let eyeBefore = cam.eye
        let delta = SIMD3<Float>(0.5, 0, -0.25)
        cam.translate(by: delta)
        #expect(simd_length(cam.target - SIMD3<Float>(1.5, 2, 2.75)) < 1e-6)
        // The eye rides along, so the view does not swing.
        #expect(simd_length((cam.eye - eyeBefore) - delta) < 1e-5)
    }

    @Test func translateCarriesAnInFlightFraming() {
        var cam = TurntableCamera()
        cam.target = .zero
        cam.dive(on: SIMD3(10, 0, 0), radius: 5, now: 0, duration: 1)
        cam.translate(by: SIMD3(0, 0, 2))
        // Halfway through the dive the goal must have moved with the body, so the
        // fly still lands on the (moved) target rather than where it started.
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
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd app/Modules
swift test --disable-xctest --test-product NewStarMapFeatureTests \
  --filter 'CameraTranslationTests' \
  --event-stream-version 0 --event-stream-output-path .build/events.jsonl
```

Expected: FAIL — `value of type 'TurntableCamera' has no member 'translate'`.

- [ ] **Step 3: Add `translate(by:)`**

In `TurntableCamera.swift`, next to `focus(on:now:)`:

```swift
    /// Rigidly shift the whole pose by `delta` — the pivot, and therefore the derived
    /// eye, move together so the view does not swing. Used to ride a body-level orrery
    /// along with the planet it is centred on: the planet keeps orbiting its star, and
    /// the camera follows it so nothing on screen appears to move.
    ///
    /// An in-flight framing move is carried too, so a dive that started toward a body
    /// still lands on that body after it has travelled.
    mutating func translate(by delta: SIMD3<Float>) {
        guard delta != .zero else { return }
        target += delta
        if var f = framing {
            f.startEye += delta
            f.goalEye += delta
            f.startTarget += delta
            f.goalTarget += delta
            framing = f
        }
    }
```

`Framing` is a private nested struct; if its properties are `let`, change them to `var`.

- [ ] **Step 4: Run test to verify it passes**

```bash
cd app/Modules
swift test --disable-xctest --test-product NewStarMapFeatureTests \
  --filter 'CameraTranslationTests' \
  --event-stream-version 0 --event-stream-output-path .build/events.jsonl
```

Expected: PASS, `total` = 3.

- [ ] **Step 5: Separate the field-recession pivot from the orrery centre**

`StarField.metal:39` and `ShaderCommon.h:70` push the background field radially away from `u.orreryCenter`. At body level that is the planet — static today, but **moving** once tracking lands, which would drag the whole star field. Give the recession its own pivot, pinned to the focused star.

In `ShaderTypes.h`, after `orreryCenter`:

```c
    // The pivot the background field recedes from — the FOCUSED STAR, always. Kept
    // separate from `orreryCenter` because at body level that centre tracks the
    // drilled planet as it orbits, and the field must not be dragged along with it.
    simd_float4 fieldCenter;
    // The centre the orrery scaffold/belt buffers were GENERATED around. Scaffold
    // vertices are rebased by (orreryCenter - orreryBuildCenter) at draw time, so a
    // moving body-level centre never forces a per-frame buffer rebuild.
    simd_float4 orreryBuildCenter;
```

In `StarField.metal`, change lines 39–40 to read `u.fieldCenter.xyz`. In `ShaderCommon.h`, change `overlayPushed` to read `u.fieldCenter.xyz` (and update its comment, which currently says the focused star "sits exactly at orreryCenter").

In the renderer's per-frame uniform packing, set `fieldCenter` to the focused star's world position (`stars[focusedStarIndex].position`, falling back to `orreryCenter` when there is no focused star) and `orreryBuildCenter` to the centre the current scaffold buffers were built around.

- [ ] **Step 6: Rebase the scaffold and belt shaders**

In `Orrery.metal`, `orrery_line_vertex`:

```c
    // Grow out of the centre in step with the planets (same `orreryReveal`), and
    // rebase onto the LIVE centre: at body level the orrery centre tracks the drilled
    // planet around its star, while these vertices were baked around a fixed origin.
    float3 local = verts[vid].position.xyz - u.orreryBuildCenter.xyz;
    float3 world = u.orreryCenter.xyz + local * u.orreryReveal;
```

Same substitution in `orrery_point_vertex` (which also rotates the belt — keep that rotation, only the base changes).

- [ ] **Step 7: Track the planet in the renderer**

In `StarFieldRenderer.swift`:

Add the retained parent system next to the `departing` field:

```swift
    /// The system a body-level orrery is drilled into, retained for the whole visit
    /// (not just the cross-fade, which is all `departing` covers). The body centre is
    /// recomputed from this every frame so the drilled planet keeps orbiting its star.
    private struct ParentSystem {
        var model: SystemModel
        var center: SIMD3<Float>
        var scale: Float
        var starIndex: Int
    }
    private var parentSystem: ParentSystem?
    /// The centre the live scaffold/belt buffers were generated around.
    private var orreryBuildCenter = SIMD3<Float>(repeating: 0)
```

Set `orreryBuildCenter = orreryCenter` at the end of `setOrreryModel` (that is exactly the centre the buffers were just built at).

In `enterBody`, before `setOrreryModel(model)`:

```swift
        parentSystem = orreryModel.map {
            ParentSystem(model: $0, center: orreryCenter, scale: orreryScale, starIndex: starIndex)
        }
```

Careful: this must capture the **system** centre and scale, so read them *before* `orreryCenter`/`orreryScale` are reassigned to the body values.

Clear it in `exitToSystem` and `exitSystem` (`parentSystem = nil`).

In `draw`, replace the freeze:

```swift
        // The orrery never pauses. Body level used to freeze this so the drilled
        // planet held still under a fixed centre; the centre now tracks the planet
        // instead (see `trackBodyCentre`), so the whole system — including the
        // drilled planet's moons — keeps running at every level.
        orbitClock += dt
```

and add, immediately after the transition clocks are advanced:

```swift
        trackBodyCentre()
```

with:

```swift
    /// Ride the body-level orrery along with the planet it is centred on. The planet
    /// keeps orbiting its star, so its world position moves every frame; the orrery
    /// centre, its lighting sun, and the camera all shift by the same delta, which
    /// means nothing on screen appears to move — and, crucially, the centre IS the
    /// planet's live system position, so zooming back out registers exactly with the
    /// system layer's own copy of that planet with nothing to reconcile.
    private func trackBodyCentre() {
        guard orreryIsBody, let parent = parentSystem, let planetID = bodyPlanetID else { return }
        let layout = orreryLayout(model: parent.model, center: parent.center,
                                  scale: parent.scale, reveal: 1, time: orbitClock)
        guard let live = layout.orbiterPosition(id: planetID) else { return }
        let delta = live - orreryCenter
        guard delta != .zero else { return }
        orreryCenter = live
        orrerySunWorldPos = bodySunPosition(
            planet: live, starIndex: parent.starIndex,
            distance: simd_length(orrerySunWorldPos - orreryCenter))
        camera.translate(by: delta)
        // A departing BODY layer (mid zoom-out) is centred on the same planet, so it
        // must ride along too or it will separate from the arriving system's copy.
        if var d = departing, d.isBody {
            d.center += delta
            departing = d
        }
    }
```

The sun distance is recomputed from the current offset so the distant-sun framing set in `enterBody` is preserved. If that reads awkwardly, store the body sun distance as a field in `enterBody` and reuse it here — either is fine, but do not let the sun drift toward or away from the planet over a long visit.

- [ ] **Step 8: Persist the parent system across a teardown**

In `StarMapViewpoint.swift`, add fields mirroring `ParentSystem` (`parentModel: SystemModel?`, `parentCenter`, `parentScale`, `parentStarIndex`). Save them in `persistViewpoint` and restore them in `restoreViewpoint`, so a tab switch back into a body view still tracks instead of silently re-freezing.

- [ ] **Step 9: Build**

```bash
cd app
xcodebuild -project Replicould.xcodeproj -scheme Replicould -destination 'platform=macOS' build 2>&1 | tail -20
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 10: Run the full module suite**

```bash
cd app/Modules
swift test --disable-xctest --test-product NewStarMapFeatureTests \
  --event-stream-version 0 --event-stream-output-path .build/events.jsonl
```

Expected: `failed: 0`. `OrreryLayoutTests` and the drill-in reducer tests both exercise this area.

- [ ] **Step 11: Visual check — this is the acceptance gate**

1. Drill into a system. Planets orbit. Drill into a planet with moons (SOL-5). **The moons orbit** — they did not before.
2. Stay at body level for a full minute. The view must not drift, wobble, or swing; the background field must stay put (this is what step 5 protects).
3. Zoom back out. The planet must be exactly where the system view draws it — **no jump, no snap, no catch-up slide**. Repeat several times, including zooming out immediately after arriving and after a long dwell.
4. Drill in and out rapidly. The cross-fade must not tear.
5. Switch to another sidebar tab and back at body level: still tracking, still no jump on zoom-out.

- [ ] **Step 12: Commit**

```bash
git add app/Modules
git commit -m "Stop pausing the orrery in the planet view

The body level froze the orbit clock so the drilled planet held still
under a fixed centre — which also froze its moons, the thing that most
read as paused. The centre now tracks the planet's live orbital position
each frame, with the lighting sun and the camera riding the same delta,
so nothing appears to move while nothing is actually stopped.

Zoom-out is seamless by construction rather than by reconciliation: the
body centre IS the planet's system position, so the arriving system layer
already draws the planet exactly there.

Scaffold buffers are rebased on the GPU via orreryBuildCenter instead of
being regenerated per frame, and the background field's recession pivot
moves to its own fieldCenter uniform so a tracking centre cannot drag the
star field along with it."
```

---

### Task 9: Dossier facts

Surface the numbers as text on the location card.

**Files:**
- Modify: `app/Modules/NewStarMapFeature/Sources/NewStarMapView.swift` (`resolveLocation`, around lines 1221–1259)
- Test: manual (this is view formatting over already-tested model data)

**Interfaces:**
- Consumes: `OrreryPlanet.spin`, `.rings`, `.hasSubsurfaceOcean`, `.orbitalDistanceKm`, `.atmosphere`, `.periodDays`.
- Produces: no new API.

- [ ] **Step 1: Add the facts**

In `resolveLocation`, in the `model.planets.first(where:)` branch, after the existing `Type` / `Orbit` / `Moons` facts:

```swift
            if !isBody {
                // System level: the body is a planet.
                if p.rings != nil { facts.append(("Rings", "Yes")) }
                if let h = p.spin.rotationHours {
                    facts.append(("Day", formatHours(abs(h))))
                }
                facts.append(("Year", formatDays(p.periodDays)))
                if let t = p.spin.tiltDeg {
                    facts.append(("Tilt", String(format: "%.1f°", t)
                        + (p.spin.isRetrograde ? " · retrograde" : "")))
                }
            } else {
                // Body level: the body is a moon.
                if let km = p.orbitalDistanceKm {
                    facts.append(("Orbit", formatKm(km)))
                }
                facts.append(("Period", formatHours(p.periodDays * 24)))
                if p.spin.tidallyLocked { facts.append(("Rotation", "Tidally locked")) }
                if p.atmosphere != .unknown {
                    facts.append(("Atmosphere", p.atmosphere == .none ? "None" : p.atmosphere.label))
                }
                if p.hasSubsurfaceOcean { facts.append(("Ocean", "Subsurface")) }
            }
```

Add the formatters as private helpers on the same view. Keep them small and unit-free-at-zero:

```swift
    /// "10.7 h" / "5832 h" / "243 d" — hours below a day stay hours; longer periods
    /// read better in days, which is how the game talks about rotation anyway.
    private func formatHours(_ h: Double) -> String {
        h < 48 ? String(format: "%.1f h", h) : String(format: "%.0f d", h / 24)
    }

    /// "224.7 d" / "29.4 y" — a gas giant's year in days is an unreadable five digits.
    private func formatDays(_ d: Double) -> String {
        d < 900 ? String(format: "%.1f d", d) : String(format: "%.1f y", d / 365.25)
    }

    /// "384 400 km" / "1.22 M km" — moon distances span two orders of magnitude.
    private func formatKm(_ km: Double) -> String {
        km >= 1_000_000
            ? String(format: "%.2f M km", km / 1_000_000)
            : String(format: "%.0f km", km)
    }
```

If `Atmosphere` has no `label` property, add one to that type (a `var label: String` switch over the cases) rather than inlining a switch in the view.

- [ ] **Step 2: Check the fact row does not overflow**

`locationDossier` lays facts out in a single `HStack` at a fixed `width: 280`. Six facts will not fit. Wrap them so they flow onto multiple lines — replace the `HStack` in `locationDossier` with a two-column `Grid`, or chunk `info.facts` into rows of three and stack the rows. Do not let the card clip.

- [ ] **Step 3: Build**

```bash
cd app
xcodebuild -project Replicould.xcodeproj -scheme Replicould -destination 'platform=macOS' build 2>&1 | tail -20
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Run the module suite**

```bash
cd app/Modules
swift test --disable-xctest --test-product NewStarMapFeatureTests \
  --event-stream-version 0 --event-stream-output-path .build/events.jsonl
```

Expected: `failed: 0`.

- [ ] **Step 5: Visual check in both colour schemes**

Select SOL-6 (rings, 26.73° tilt, 10.66 h day, 29.4 y year), SOL-2 (177.4° tilt, retrograde), and a moon like SOL-5-2 (671 100 km, 85.2 h, tidally locked, subsurface ocean). Confirm the card reads correctly, does not clip, uses design tokens, and keeps the designation in a mono font. Check light mode as well as dark.

- [ ] **Step 6: Commit**

```bash
git add app/Modules/NewStarMapFeature/Sources/NewStarMapView.swift
git commit -m "Show the physical facts on the location dossier

Planets list rings, day, year and axial tilt (flagged retrograde);
moons list orbital distance, period, tidal lock, atmosphere and
subsurface ocean. Facts now wrap instead of overflowing the card."
```

---

## Final verification

- [ ] **Full test suite across every product**

```bash
cd app/Modules
for p in UniverseModelsTests NewStarMapFeatureTests; do
  swift test --disable-xctest --test-product "$p" \
    --event-stream-version 0 --event-stream-output-path ".build/events-$p.jsonl"
done
```

Read each stream separately — one output path per product, or later targets truncate earlier ones.

- [ ] **Full app build**

```bash
cd app
xcodebuild -project Replicould.xcodeproj -scheme Replicould -destination 'platform=macOS' build 2>&1 | tail -20
```

- [ ] **Merge to main and remove the worktree.** No PR, no push to a remote.

## Notes on shader tuning

Three constants in this plan are first estimates that the screenshot pass is expected to refine. They are called out here so a reviewer does not mistake them for measured values:

- The volcanic crack thresholds `0.88` / `0.72` (Task 4).
- The ring band frequency `9.0` and gap smoothstep `0.30…0.75` (Task 6).
- The cryo-fracture threshold `0.74…0.94` (Task 7).

Tune them against the SOL bodies named in each task's visual step. Do not leave a half-tuned effect in the build; if something cannot be made to read well, remove it and say so.
