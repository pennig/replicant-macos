# Location Body Portrait — Design

Every Location details screen gains a 128×128 rendering of the thing it describes,
sitting to the left of a top info group that is also 128pt tall. The rendering is
the star map's own, drawn through the production shaders, so a body looks the same
in the inspector as it does in the map — animation included. Planets and moons are
lit by a sun, giving the terminator you would see zoomed into that body in the map's
Body focus.

## 1. Scope

All six inspectors in `LocationDetailView.swift` get a 128pt leading square:

| Inspector | Square shows | Path |
| --- | --- | --- |
| `SystemInspector` | the system's star — disc, granulation, flares | Metal, `star_vertex` + `star_body_fragment` + `star_fragment` |
| `PlanetInspector` | the planet — surface, rings, atmosphere halo, terminator | Metal, `orrery_body_*` + `orrery_ring_*` + `orrery_atmosphere_*` |
| `MoonInspector` | the moon, tidal lock respected | Metal, `orrery_body_*` |
| `BeltInspector` | the belt's own density-driven point ring, tilted | Metal, `orrery_point_*` |
| `ObjectInspector`, kind `.kuiper` / `.oort` | a wide, sparse point field | Metal, `orrery_point_*` |
| `ObjectInspector`, kind `.megastructure` / `.object` | a 128pt symbol tile in house chrome | SwiftUI |
| `LagrangeInspector` | a Lagrange schematic, the selected point highlighted | SwiftUI `Canvas` |

`SpecialSiteKind` carries five cases. Two of them — `.kuiper` and `.oort` — are
outer-system regions the map already draws as point fields, so they take the belt's
pipeline with a wider, sparser ring rather than a symbol. Only `.megastructure` and
`.object` have no map geometry to borrow. (`.lagrange` never reaches
`ObjectInspector`; it is routed to `LagrangeInspector`.)

Nothing is interactive. The square animates and ignores the mouse: at 128pt inside
a `ScrollView`, drag-to-orbit fights the scroll gesture and pinch has nowhere to go.

## 2. Module placement

The `.metal` files are `.process` resources of `NewStarMapFeature` and
`device.makeDefaultLibrary(bundle: .module)` resolves only inside that target. The
renderer therefore lives in `NewStarMapFeature`, and `LocationsFeature` takes a new
dependency on it. Verified in `Modules/Package.swift`: `LocationsFeature` (:486–498)
and `NewStarMapFeature` (:585–609) share a base of `GameModels`, `GameServices`,
`TravelUI`, `UI`, `UniverseModels`, and neither references the other. No cycle.

`NewStarMapFeature` gains exactly two public symbols:

```swift
public enum BodyPortrait: Equatable, Sendable {
    case star(SystemStar)
    case planet(Planet)
    case moon(Moon)
    case belt(Belt)
    case region(SpecialSite)   // .kuiper / .oort only
}

public struct BodyPortraitView: View {
    public init(_ subject: BodyPortrait)
}
```

The associated values are `UniverseModels` types both modules already depend on, and
each inspector already holds the resolved value (`LocationDetailView.swift:152, 238,
266, 287`). `PlanetType`, `PlanetMaterial`, `BodySpin`, `Atmosphere` and
`StellarClass` stay `internal` — nothing is hoisted, and no new shared target appears.

The two SwiftUI fallbacks need no Metal and live in `LocationsFeature`:
`LagrangeDiagram.swift` and the symbol tile inline in `LocationDetailView.swift`.

## 3. Appearance derivation

The portrait must not reimplement how a body looks. It calls the same code the map
calls, so a change to either shows up in both.

The same twelve appearance fields are derived inline in three places today —
`systemModel` (`OrreryMapping.swift:129–191`), the `CentralBody` block
(`:526–559`), and the promoted-moon block (`:590–626`) — and all three funnel into
`PlacedBody`, a `private struct` inside `StarFieldRenderer` (`:1985–2013`).
`PlacedBody` is already the de-facto appearance type; it is merely private and mixed
with placement. `PlanetMaterial.surface(...)` is called from exactly one place in the
module, `bodyUniform` (`:2126`).

Two extractions, both behaviour-preserving:

```swift
struct BodyAppearance: Equatable, Sendable {
    var planetType: PlanetType
    var rawType: String?        // PlanetMaterial.irregularity reads the raw API string
    var lifeStage: String?
    var estimated: Bool
    var tags: [String]
    var surfaceTempC: Double?
    var atmosphere: Atmosphere
    var inHabitableZone: Bool
    var hasSubsurfaceOcean: Bool
    var appearanceSeed: Float
    var spin: BodySpin
    var rings: RingSystem?
}

extension OrreryMapping {
    static func appearance(planet: Planet, options: OrreryPlaneOptions) -> BodyAppearance
    static func appearance(moon: Moon, options: OrreryPlaneOptions) -> BodyAppearance
}
```

`rawType` must survive the extraction. `PlanetMaterial.irregularity(type:)` is driven
off the raw string, not `PlanetType`, because "Captured Asteroid" is a moon type with
no `PlanetType` case; dropping it renders every captured asteroid as a smooth sphere.

`PlacedBody` and the three pure uniform builders (`bodyUniform`, `ringUniform`,
`atmosphereUniform`) move out of `StarFieldRenderer` into their own file at internal
scope. They reference no renderer state. The map's call sites become free-function
calls and are otherwise unchanged. The portrait then runs the identical chain:

```
Planet / Moon → OrreryMapping.appearance(…) → PlacedBody(portrait:…)
              → bodyUniform / ringUniform / atmosphereUniform → production shaders
```

Star colour is derived the way the map derives it, and only that way:
`StellarClass(spectralType:)` → `representativeTemperature` (the band midpoint) →
`Star.color(forTemperature:)`. `SystemStar.temperatureK` is read by nothing in the
render path and is deliberately not used here — a real 5,200 K reading would produce a
more faithful star that does not match the map, and matching the map is the
requirement.

## 4. Framing and light

- Body centred at the origin with world radius 1, camera fovy 60°, matching
  `TurntableCamera` (`TurntableCamera.swift:20`).
- Camera at fixed azimuth, elevation ≈ 18°, so a tilted spin axis and a ring plane
  both read as ellipses rather than lines.
- Camera distance computed from actual content extent, never fixed. Rings reach to
  `rings.outerFrac` × radius and irregular bodies to 1.54× (unit-product axes); a
  fixed distance crops them. Distance is `extent / (tan(fovy/2) · fill)` with
  `fill ≈ 0.85`, floored at 5.1× radius.
- Sun fixed in world space at azimuth 0.9, elevation 0.30, at 40× body radius —
  matching `bodySunDistance = frameWorldRadius * 40` (`StarFieldRenderer.swift:1624`).
  The 40× matters: a sun placed inside the body's own radius unlights it.

The sun and the camera are both fixed, so every body is lit identically and two
bodies can be compared across screens. Deriving the sun from real orbital geometry
was considered and rejected: a body can land near-full or near-dark, which reads
badly at 128pt.

### Uniform fields that are not optional

Most of `Uniforms` may stay zero, but five values are load-bearing and each fails
silently — a correct render that is invisible or black.

| Field | Value | Consequence of leaving it zero |
| --- | --- | --- |
| `orreryAlpha` | `1` | body, ring and halo all multiply coverage by it — the body draws fully transparent |
| `orreryReveal` | `1` for the belt pass only | the belt's point ring collapses into its centre |
| `atmoFloor` | `1` | `star_vertex` computes `atmo = 0`, so the star renders black |
| `focusedStar` | the star's instance index, `0` | otherwise `ceiling = maxAngularSize = 0.05` caps the star's angular size and no camera distance can make a full disc |
| `bodyReveal` | `0` | with `focusedStar` set, this lifts the ceiling to `1e9` so `radius = worldRadius` exactly |

The star's disc fills a given fraction of a 128pt view at `α = worldRadius / dist`,
with disc diameter in pixels `= 176.9 · α`. A 60% fill is `α ≈ 0.434`, i.e.
`dist ≈ 2.3 × worldRadius`. The star pass also binds a fragment `relRange` at index 3;
a single-draw portrait binds `SIMD2<Float>(0, 2)` to keep every fragment.

### Draw order

The map's order, which the portrait matches: star glow → star disc → belt points →
bodies → rings → atmosphere, all into one `rgba16Float` HDR target with a
`depth32Float` attachment, then `tonemap_fragment` to the drawable. Only the star
disc and a central body write depth; everything else tests without writing.

`tonemap_fragment` returns a hard-coded alpha of 1, so the portrait is opaque. It is
clipped to `Radius.card` by its frame rather than blended.

## 5. Layout

`InspectorScroll` (`LocationDetailView.swift:471–502`) gains two slots — a leading
portrait and a facts block — and its header row is pinned to 128pt:

```swift
HStack(alignment: .top, spacing: Space.m) {
    portrait
        .frame(width: TileSize.portrait, height: TileSize.portrait)
    VStack(alignment: .leading, spacing: Space.s) {
        titleLockup          // title, then code + ReconDot + recon label
        facts                // up to five Readout rows
    }
    Spacer(minLength: 0)
    accessory
}
.frame(height: TileSize.portrait)
```

`TileSize` gains `portrait: CGFloat = 128` beside `small: 30` and `large: 52`. There
is no `128` in first-party source today, and the project rule forbids inlining it.

The facts filling the square's neighbour come from one derivation, `BodyFacts`,
returning at most five label/value rows per subject. Those exact rows are removed
from the cards below so nothing is stated twice:

| Inspector | Promoted rows | Effect below |
| --- | --- | --- |
| System | Class, Color, Age, Mining bonus, From Sol | `RCReadoutCard("Star")` deleted |
| Planet | Type, Orbit, Habitable zone, Life, Moons | `RCReadoutCard("Planet")` deleted |
| Moon | Type, Radius, Gravity, Surface, Atmosphere | `RCReadoutCard("Moon")` deleted; the four physical rows removed from `PhysicalCard` |
| Belt | Density, Radius | `RCReadoutCard("Belt")` deleted |
| Object | Type, Status, Stage, Orbit, Deadline | `RCReadoutCard(site.kind.label)` deleted |
| Lagrange | Point, Stability, Parent, Orbit | `RCReadoutCard("Lagrange Point")` deleted |

Rows whose underlying value is absent are dropped, exactly as they are today, so a
sparse body simply shows fewer rows. A designation value keeps its mono token
(`Parent`, `Deadline`), per the project's monospace rule.

## 6. The Lagrange schematic

A `Canvas`-drawn two-body diagram in the familiar textbook arrangement: the star at
one focus, the parent planet on a circular orbit, and the five points marked — L1
between star and planet, L2 beyond the planet, L3 diametrically opposite, L4 60°
ahead of the planet on the orbit and L5 60° behind. The selected point is drawn in
`.rcAccent` at full size; the other four are `.rcTextTertiary` ticks.

Lightness, not hue, separates the selected point from the rest: the highlight is
larger and brighter, and carries its own `L4`-style label. Hue alone would not
distinguish it.

## 7. Testing

Pure and testable:

- `BodyFacts` — given a `Planet`, `Moon`, `SystemStar`, `Belt`, `SpecialSite`, or a
  Lagrange designation, assert the exact rows and their order, including the
  absent-value drops.
- `OrreryMapping.appearance(of:)` — assert style index, base colour, ring presence
  for a ringed gas giant, the `estimated` flag for an unscanned body, and the spin
  axis for a tidally-locked moon.
- The extraction is behaviour-preserving, so existing `OrreryTests` and
  `OrreryPushTests` must stay green untouched.

Not unit-testable: the Metal output. The rendering is verified by eye. The
implementer builds and type-checks; a human confirms the pixels.

## 8. Known risks

- **`estimated` bodies at 128pt.** An unscanned body renders with a sensor-glitch
  treatment (`Orrery.metal:527–557`) — 2×2 static blocks, scanlines, a refresh sweep
  — tuned for a body a few dozen pixels across. At 128pt it will read loudly. The
  flag is kept honest rather than suppressed, because it carries real information,
  and the intensity is tuned after first sight.
- **Frame cost.** One `MTKView` at 60fps in a detail pane is cheap, but it must pause
  when the pane is not visible.
- **Belt speckle differs from the map.** `OrreryGeometry.beltPoints` seeds its RNG
  once per call and shares it across every belt in the system, so a belt's point
  pattern depends on how many belts precede it. A single-belt portrait produces a
  different speckle than the same belt shows in the map. The band width, density and
  colour all match; only the individual grain placement differs.
- **Belt radius carries no meaning alone.** `innerScene`/`outerScene` come from a
  system-wide spacing pass. The portrait keeps the band's true radial width and picks
  its own inner edge for framing, because an absolute radius is unreadable without the
  star to measure it against.
- **`tiltCapDeg` is a user setting.** `BodySpin` takes it from `OrreryPlaneOptions`,
  which the map reads from `@Shared(.appStorage)`. The portrait must read the same
  value, or a body leans differently in the inspector than in the map.
- **A tidally locked body has no orbit angle.** `PlacedBody.spinPhase` normally comes
  from the live orbit for a locked body. The portrait uses the free-rotator branch —
  `phaseDeg(designation)` — which is exactly what the map's own central body does,
  and is deterministic per designation.

## 9. Out of scope

- Any interactivity on the square.
- Changing what the star map itself renders.
- A structure-specific rendering; structures get a symbol.
- An offscreen PNG verification harness.
