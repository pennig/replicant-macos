# Location Body Portrait Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every Location details screen shows a 128×128 rendering of its star, planet, moon, belt or region, drawn through the star map's own shaders, beside a 128pt-tall info group.

**Architecture:** A new `BodyPortraitView` lives in `NewStarMapFeature` (the only target whose bundle resolves the compiled `.metal` library) and renders one body through the production `orrery_body_*` / `star_*` / `orrery_point_*` shaders plus `tonemap_fragment`, exactly as the map does. `LocationsFeature` takes a new dependency on `NewStarMapFeature` and hands it the domain value each inspector already holds. Two non-Metal fallbacks — a Lagrange schematic and a symbol tile — stay in `LocationsFeature`.

**Tech Stack:** Swift 6, SwiftUI, Metal / MetalKit, Swift Testing, SPM (`app/Modules/Package.swift`).

**Spec:** `docs/superpowers/specs/2026-08-16-location-body-portrait-design.md`

## Global Constraints

- **Never inline colors, spacing, radii or font sizes.** Use `DesignSystem.swift` tokens (`Space.m`, `Radius.card`, `.rcTextPrimary`, `.rcCaption`). A missing token is added there, not inlined.
- **System and location designations always render in a monospace token** (`.rcMono`, `.rcMonoSmall`, `.rcBodyEmphMono`, `.rcTitleMono`).
- **Comment budget is hard:** file header ≤ 10 lines, `///` doc ≤ 3 lines, inline `//` ≤ 2 lines. No dated history, no rejected alternatives, no rationale — those go to `.claude/memory/`.
- **Never encode meaning in hue alone.** Lightness and size are the channels that survive; the reviewer is colour-vision deficient.
- **Logging is `os.Logger` only**, subsystem `name.pennig.replicould`, category = module name. No `print`.
- **Read `swift test` results from the JSON event stream**, never by parsing console text. Use the `swift-test-event-stream` skill for the invocation.
- **Worktree setup, once, before any LSP query:** `cd app/Modules && swift build --build-tests`, then `cd app && ./scripts/link-index-store.sh`. Without the symlink every reference query silently returns zero.
- **No PRs, no pushing to origin.** Commit to the working branch.
- Target platform is macOS 26; current SwiftUI and Metal APIs are available.

---

### Task 1: `BodyFacts` — the promoted key-facts derivation

The rows that fill the 128pt info group beside the portrait. Pure, no SwiftUI, so it is fully testable. Each subject yields at most five rows; a row whose underlying value is absent is dropped.

**Files:**
- Create: `app/Modules/LocationsFeature/Sources/BodyFacts.swift`
- Create: `app/Modules/LocationsFeature/Tests/BodyFactsTests.swift`

**Interfaces:**
- Consumes: `UniverseModels` — `SystemStar`, `Planet`, `Moon`, `Belt`, `SpecialSite`, `BodyPhysical`.
- Produces:
  ```swift
  public struct BodyFact: Equatable, Sendable {
      public let label: String
      public let value: String
      public let mono: Bool
  }
  public enum BodyFacts {
      public static func rows(star: SystemStar) -> [BodyFact]
      public static func rows(planet: Planet) -> [BodyFact]
      public static func rows(moon: Moon) -> [BodyFact]
      public static func rows(belt: Belt) -> [BodyFact]
      public static func rows(site: SpecialSite) -> [BodyFact]
      public static func rows(lagrangePoint: Int, parent: Planet, site: SpecialSite?) -> [BodyFact]
  }
  ```

- [ ] **Step 1: Write the failing tests**

Create `app/Modules/LocationsFeature/Tests/BodyFactsTests.swift`:

```swift
import Testing
import UniverseModels
@testable import LocationsFeature

@Suite("BodyFacts")
struct BodyFactsTests {
    @Test("a planet promotes type, orbit, habitable zone, life and moons")
    func planetRows() {
        let planet = Planet(
            designation: "SOL-3", name: "Terra", type: "Terrestrial",
            typeEstimated: false, orbitalDistanceAu: 1.0, inHabitableZone: true,
            lifeStage: "complex", recon: .scanned, moonCount: 1
        )
        #expect(BodyFacts.rows(planet: planet) == [
            BodyFact(label: "Type", value: "Terrestrial", mono: false),
            BodyFact(label: "Orbit", value: "1.00 AU", mono: false),
            BodyFact(label: "Habitable zone", value: "Yes", mono: false),
            BodyFact(label: "Life", value: "Complex", mono: false),
            BodyFact(label: "Moons", value: "1", mono: false),
        ])
    }

    @Test("an estimated type is marked, and absent values drop their rows")
    func planetSparse() {
        let planet = Planet(
            designation: "SOL-9", type: "Gas Giant", typeEstimated: true,
            inHabitableZone: false, recon: .aware
        )
        #expect(BodyFacts.rows(planet: planet) == [
            BodyFact(label: "Type", value: "Gas Giant (est.)", mono: false),
            BodyFact(label: "Habitable zone", value: "No", mono: false),
        ])
    }

    @Test("a life stage of none is not a fact")
    func planetLifeNone() {
        let planet = Planet(
            designation: "SOL-4", type: "Barren", typeEstimated: false,
            inHabitableZone: false, lifeStage: "none", recon: .scanned
        )
        #expect(!BodyFacts.rows(planet: planet).contains { $0.label == "Life" })
    }

    @Test("a moon draws its remaining rows from physical characteristics")
    func moonRows() {
        let moon = Moon(
            designation: "SOL-3-1", name: "Luna", type: "Rocky", recon: .scanned,
            physical: BodyPhysical(
                radiusEarth: 0.27, surfaceGravity: 0.17,
                surfaceTempC: -20, atmosphere: "none"
            )
        )
        #expect(BodyFacts.rows(moon: moon) == [
            BodyFact(label: "Type", value: "Rocky", mono: false),
            BodyFact(label: "Radius", value: "0.27 R⊕", mono: false),
            BodyFact(label: "Gravity", value: "0.17 g", mono: false),
            BodyFact(label: "Surface", value: "-20 °C", mono: false),
            BodyFact(label: "Atmosphere", value: "None", mono: false),
        ])
    }

    @Test("a moon with no physical block yields only its type")
    func moonUnscanned() {
        let moon = Moon(designation: "SOL-5-2", recon: .aware)
        #expect(BodyFacts.rows(moon: moon) == [
            BodyFact(label: "Type", value: "—", mono: false),
        ])
    }

    @Test("a star promotes class, colour, age, mining bonus and distance")
    func starRows() {
        let star = SystemStar(
            designation: "SOL", stellarClass: "G2V", color: "yellow",
            ageMy: 4600, miningBonusPct: 12, distanceFromSol: 0
        )
        #expect(BodyFacts.rows(star: star) == [
            BodyFact(label: "Class", value: "G2V", mono: false),
            BodyFact(label: "Color", value: "Yellow", mono: false),
            BodyFact(label: "Age", value: "4600 My", mono: false),
            BodyFact(label: "Mining bonus", value: "+12%", mono: false),
            BodyFact(label: "From Sol", value: "0.0 ly", mono: false),
        ])
    }

    @Test("a zero mining bonus is not a fact")
    func starZeroBonus() {
        let star = SystemStar(designation: "VEGA", stellarClass: "A0V", miningBonusPct: 0)
        #expect(!BodyFacts.rows(star: star).contains { $0.label == "Mining bonus" })
    }

    @Test("a belt promotes density and radius")
    func beltRows() {
        let belt = Belt(designation: "SOL-BELT-1", innerRadiusAu: 2.1,
                        outerRadiusAu: 3.4, density: "moderate")
        #expect(BodyFacts.rows(belt: belt) == [
            BodyFact(label: "Density", value: "Moderate", mono: false),
            BodyFact(label: "Radius", value: "2.1–3.4 AU", mono: false),
        ])
    }

    @Test("a Lagrange point names its parent in monospace")
    func lagrangeRows() {
        let parent = Planet(designation: "SOL-3", typeEstimated: false,
                            orbitalDistanceAu: 1.0, inHabitableZone: true, recon: .scanned)
        #expect(BodyFacts.rows(lagrangePoint: 4, parent: parent, site: nil) == [
            BodyFact(label: "Point", value: "L4", mono: false),
            BodyFact(label: "Stability", value: "Stable", mono: false),
            BodyFact(label: "Parent", value: "SOL-3", mono: true),
            BodyFact(label: "Orbit", value: "1.00 AU", mono: false),
        ])
    }

    @Test("L1 L2 and L3 are unstable")
    func lagrangeStability() {
        let parent = Planet(designation: "SOL-3", typeEstimated: false,
                            inHabitableZone: false, recon: .scanned)
        for n in [1, 2, 3] {
            let rows = BodyFacts.rows(lagrangePoint: n, parent: parent, site: nil)
            #expect(rows.first { $0.label == "Stability" }?.value == "Unstable")
        }
    }

    @Test("a site promotes type status stage orbit and deadline")
    func siteRows() {
        let site = SpecialSite(
            designation: "SOL-MEGA-1", kind: .megastructure,
            objectType: "dyson_swarm", status: "building", stage: "phase_one",
            orbitalDistanceAu: 0.8, deadline: "2026-09-01T00:00:00Z"
        )
        #expect(BodyFacts.rows(site: site) == [
            BodyFact(label: "Type", value: "Dyson Swarm", mono: false),
            BodyFact(label: "Status", value: "Building", mono: false),
            BodyFact(label: "Stage", value: "Phase One", mono: false),
            BodyFact(label: "Orbit", value: "0.80 AU", mono: false),
            BodyFact(label: "Deadline", value: "2026-09-01T00:00:00Z", mono: true),
        ])
    }
}
```

- [ ] **Step 2: Run the tests and confirm they fail**

```bash
cd app/Modules && swift test --filter BodyFacts \
  --event-stream-output-path /tmp/bodyfacts.jsonl
```

Expected: compile failure — `cannot find 'BodyFacts' in scope`.

- [ ] **Step 3: Write the implementation**

Create `app/Modules/LocationsFeature/Sources/BodyFacts.swift`:

```swift
import Foundation
import UniverseModels

/// One promoted key/value row in a location header's info group.
public struct BodyFact: Equatable, Sendable {
    public let label: String
    public let value: String
    public let mono: Bool

    public init(label: String, value: String, mono: Bool = false) {
        self.label = label
        self.value = value
        self.mono = mono
    }
}

/// The facts a location detail header promotes beside its 128pt portrait, at most
/// five per subject. A row whose value is absent is dropped rather than shown empty.
public enum BodyFacts {
    public static func rows(star: SystemStar) -> [BodyFact] {
        var out = [BodyFact(label: "Class", value: star.stellarClass ?? "—")]
        if let colour = star.color { out.append(BodyFact(label: "Color", value: colour.capitalized)) }
        if let age = star.ageMy { out.append(BodyFact(label: "Age", value: String(format: "%.0f My", age))) }
        if let bonus = star.miningBonusPct, bonus != 0 {
            out.append(BodyFact(label: "Mining bonus", value: "+\(Int(bonus))%"))
        }
        if let d = star.distanceFromSol {
            out.append(BodyFact(label: "From Sol", value: String(format: "%.1f ly", d)))
        }
        return out
    }

    public static func rows(planet: Planet) -> [BodyFact] {
        var out = [BodyFact(
            label: "Type",
            value: (planet.type ?? "—") + (planet.typeEstimated ? " (est.)" : "")
        )]
        if let au = planet.orbitalDistanceAu {
            out.append(BodyFact(label: "Orbit", value: String(format: "%.2f AU", au)))
        }
        out.append(BodyFact(label: "Habitable zone", value: planet.inHabitableZone ? "Yes" : "No"))
        if let life = planet.lifeStage, life != "none" {
            out.append(BodyFact(label: "Life", value: life.capitalized))
        }
        if let n = planet.moonCount { out.append(BodyFact(label: "Moons", value: "\(n)")) }
        return out
    }

    public static func rows(moon: Moon) -> [BodyFact] {
        var out = [BodyFact(label: "Type", value: moon.type ?? "—")]
        guard let p = moon.physical else { return out }
        if let r = p.radiusEarth { out.append(BodyFact(label: "Radius", value: String(format: "%.2f R⊕", r))) }
        if let g = p.surfaceGravity { out.append(BodyFact(label: "Gravity", value: String(format: "%.2f g", g))) }
        if let t = p.surfaceTempC { out.append(BodyFact(label: "Surface", value: String(format: "%.0f °C", t))) }
        if let a = p.atmosphere { out.append(BodyFact(label: "Atmosphere", value: a.capitalized)) }
        return out
    }

    public static func rows(belt: Belt) -> [BodyFact] {
        var out: [BodyFact] = []
        if let d = belt.density { out.append(BodyFact(label: "Density", value: d.capitalized)) }
        if let inner = belt.innerRadiusAu, let outer = belt.outerRadiusAu {
            out.append(BodyFact(label: "Radius", value: String(format: "%.1f–%.1f AU", inner, outer)))
        }
        return out
    }

    public static func rows(site: SpecialSite) -> [BodyFact] {
        var out = [BodyFact(label: "Type", value: humanised(site.objectType ?? site.kind.rawValue))]
        if let status = site.status { out.append(BodyFact(label: "Status", value: humanised(status))) }
        if let stage = site.stage { out.append(BodyFact(label: "Stage", value: humanised(stage))) }
        if let au = site.orbitalDistanceAu {
            out.append(BodyFact(label: "Orbit", value: String(format: "%.2f AU", au)))
        }
        if let deadline = site.deadline {
            out.append(BodyFact(label: "Deadline", value: deadline, mono: true))
        }
        return out
    }

    public static func rows(lagrangePoint n: Int, parent: Planet, site: SpecialSite?) -> [BodyFact] {
        var out = [
            BodyFact(label: "Point", value: "L\(n)"),
            BodyFact(label: "Stability", value: (n == 4 || n == 5) ? "Stable" : "Unstable"),
            BodyFact(label: "Parent", value: parent.designation, mono: true),
        ]
        if let au = site?.orbitalDistanceAu ?? parent.orbitalDistanceAu {
            out.append(BodyFact(label: "Orbit", value: String(format: "%.2f AU", au)))
        }
        return out
    }

    private static func humanised(_ raw: String) -> String {
        raw.replacingOccurrences(of: "_", with: " ").capitalized
    }
}
```

- [ ] **Step 4: Run the tests and confirm they pass**

```bash
cd app/Modules && swift test --filter BodyFacts \
  --event-stream-output-path /tmp/bodyfacts.jsonl
jq -r 'select(.kind=="event" and .payload.kind=="testCaseEnded")
       | "\(.payload.testID)  \(.payload.result // "ok")"' /tmp/bodyfacts.jsonl
```

Expected: every test case ends without an `issueRecorded` event. If a fixture's initializer signature does not match `UniverseModels`, fix the **test** to match the real model — do not add initializer overloads to the model.

- [ ] **Step 5: Commit**

```bash
git add app/Modules/LocationsFeature/Sources/BodyFacts.swift \
        app/Modules/LocationsFeature/Tests/BodyFactsTests.swift
git commit -m "feat(locations): derive the key facts a detail header promotes"
```

---

### Task 2: `TileSize.portrait` and the 128pt header row

`InspectorScroll` gains a leading portrait slot and a facts slot, and its header row is pinned to 128pt. Every inspector passes its `BodyFacts` rows, and the card those rows came from is removed. The portrait slot is filled with a plain placeholder square here; Task 10 replaces it with the real rendering.

**Files:**
- Modify: `app/Modules/UI/Sources/DesignSystem.swift:298-302`
- Modify: `app/Modules/LocationsFeature/Sources/LocationDetailView.swift`

**Interfaces:**
- Consumes: `BodyFacts`, `BodyFact` from Task 1.
- Produces: `TileSize.portrait: CGFloat` (= 128); `InspectorScroll(title:code:recon:accessory:portrait:facts:content:)` where `portrait` is `AnyView?` (matching the existing `accessory` precedent) and `facts` is `[BodyFact]`.

- [ ] **Step 1: Add the size token**

In `app/Modules/UI/Sources/DesignSystem.swift`, extend `TileSize` (currently at `:298-302`). Update its doc comment to cover the new case, staying inside the 3-line budget:

```swift
/// Square dimensions for the icon/glyph tiles used in list rows (small), detail
/// headers (large), and the body rendering in a location header (portrait). Owned
/// here so the recurring magic numbers live in one place.
public enum TileSize {
    public static let small: CGFloat = 30
    public static let large: CGFloat = 52
    public static let portrait: CGFloat = 128
}
```

- [ ] **Step 2: Widen `InspectorScroll`**

Replace `InspectorScroll` in `LocationDetailView.swift:471-502` with:

```swift
private struct InspectorScroll<Content: View>: View {
    let title: String
    let code: String
    let recon: Recon
    var accessory: AnyView? = nil
    /// The 128pt body rendering shown leading the header, when the location has one.
    var portrait: AnyView? = nil
    /// Key facts promoted beside the portrait to fill the header's height.
    var facts: [BodyFact] = []
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.l) {
                HStack(alignment: .top, spacing: Space.m) {
                    if let portrait {
                        portrait
                            .frame(width: TileSize.portrait, height: TileSize.portrait)
                    }
                    VStack(alignment: .leading, spacing: Space.s) {
                        VStack(alignment: .leading, spacing: Space.xs) {
                            Text(title).font(.rcTitleMono).foregroundStyle(.rcTextPrimary)
                            HStack(spacing: Space.s) {
                                Text(code).font(.rcMono).foregroundStyle(.rcTextTertiary)
                                ReconDot(recon: recon)
                                Text(recon.label).font(.rcCaption).foregroundStyle(.rcTextTertiary)
                            }
                        }
                        ForEach(facts, id: \.label) { fact in
                            Readout(fact.label, fact.value, mono: fact.mono)
                        }
                    }
                    if let accessory {
                        Spacer(minLength: 0)
                        accessory
                    }
                }
                .frame(height: portrait == nil ? nil : TileSize.portrait, alignment: .top)
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Space.l)
        }
        .navigationTitle(title)
    }
}
```

The header keeps its intrinsic height when there is no portrait, so a location that
never gets one is unchanged.

- [ ] **Step 3: Add the placeholder square**

Add to `LocationDetailView.swift`, above `InspectorScroll`:

```swift
/// The house chrome every 128pt header square shares: raised surface, hairline
/// border, card radius. Wraps whatever the location's rendering turns out to be.
private struct PortraitFrame<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .frame(width: TileSize.portrait, height: TileSize.portrait)
            .background(.rcSurfaceRaised, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .strokeBorder(.rcSeparator, lineWidth: Hairline.thin)
            )
            .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }
}
```

- [ ] **Step 4: Wire each inspector**

In `SystemInspector` (`:148-234`), pass the facts and drop the `Star` card. The
`if let star = system.star` block that opened `content` goes away entirely:

```swift
InspectorScroll(
    title: system.name ?? system.designation, code: system.designation,
    recon: system.recon, accessory: accessory,
    portrait: system.star.map { _ in AnyView(PortraitFrame { Color.clear }) },
    facts: system.star.map { BodyFacts.rows(star: $0) } ?? []
) {
    RCReadoutCard("System") {
        // unchanged
    }
    // …the rest of the system content, unchanged
}
```

In `PlanetInspector` (`:237-263`), drop `RCReadoutCard("Planet")`:

```swift
InspectorScroll(
    title: planet.name ?? planet.designation, code: planet.designation,
    recon: planet.recon, accessory: accessory,
    portrait: AnyView(PortraitFrame { Color.clear }),
    facts: BodyFacts.rows(planet: planet)
) {
    if let phys = planet.physical { PhysicalCard(phys) }
    SiteSalvageSections(sites: planet.sites, salvage: planet.remainingSalvage, assayTotals: assayTotals)
    let holdings = planet.inventoryHoldings
    if !holdings.isEmpty {
        RCReadoutCard("Inventory", count: holdings.count) {
            ForEach(holdings) { InventoryHoldingRow(holding: $0) }
        }
    }
}
```

In `MoonInspector` (`:265-280`), drop `RCReadoutCard("Moon")` and pass
`promoted: true` to `PhysicalCard` so its four promoted rows are not repeated:

```swift
InspectorScroll(
    title: moon.name ?? moon.designation, code: moon.designation,
    recon: moon.recon, accessory: accessory,
    portrait: AnyView(PortraitFrame { Color.clear }),
    facts: BodyFacts.rows(moon: moon)
) {
    if let phys = moon.physical { PhysicalCard(phys, promoted: true) }
    SiteSalvageSections(sites: moon.sites, salvage: moon.remainingSalvage, assayTotals: assayTotals)
    InventoryCard(moon.inventory)
}
```

Give `PhysicalCard` (`:454-469`) the flag:

```swift
private struct PhysicalCard: View {
    let phys: BodyPhysical
    /// Radius, gravity, surface temp and atmosphere already sit in the header.
    let promoted: Bool
    init(_ phys: BodyPhysical, promoted: Bool = false) {
        self.phys = phys; self.promoted = promoted
    }
    var body: some View {
        RCReadoutCard("Physical") {
            if let m = phys.massEarth { Readout("Mass", String(format: "%.2f M⊕", m)) }
            if !promoted, let r = phys.radiusEarth { Readout("Radius", String(format: "%.2f R⊕", r)) }
            if let d = phys.densityGcc { Readout("Density", String(format: "%.2f g/cc", d)) }
            if !promoted, let g = phys.surfaceGravity { Readout("Gravity", String(format: "%.2f g", g)) }
            if !promoted, let t = phys.surfaceTempC { Readout("Surface", String(format: "%.0f °C", t)) }
            if !promoted, let a = phys.atmosphere { Readout("Atmosphere", a.capitalized) }
            if phys.tidallyLocked == true { Readout("Tidally locked", "Yes") }
            if phys.hasSubsurfaceOcean == true { Readout("Subsurface ocean", "Yes") }
            if !phys.tags.isEmpty { Readout("Tags", phys.tags.joined(separator: ", ")) }
        }
    }
}
```

In `BeltInspector` (`:282-318`), drop `RCReadoutCard("Belt")` and pass
`facts: BodyFacts.rows(belt: belt)` with the same placeholder portrait.

In `ObjectInspector` (`:320-351`), drop `RCReadoutCard(site.kind.label)` and pass
`facts: BodyFacts.rows(site: site)` with the same placeholder portrait.

In `LagrangeInspector` (`:356-376`), drop `RCReadoutCard("Lagrange Point")` and pass
`facts: BodyFacts.rows(lagrangePoint: point, parent: planet, site: site)` with the
same placeholder portrait.

- [ ] **Step 5: Build and confirm the package type-checks**

```bash
cd app/Modules && swift build --build-tests 2>&1 | tail -20
```

Expected: no errors. A `Readout` visibility error means `Readout` must move above
`InspectorScroll` in the file, or lose its `private` on the initializer — it is
already `private` to the file, which is sufficient.

- [ ] **Step 6: Run the existing Locations tests**

```bash
cd app/Modules && swift test --filter LocationsFeature \
  --event-stream-output-path /tmp/locations.jsonl
jq -r 'select(.payload.kind=="issueRecorded") | .payload' /tmp/locations.jsonl
```

Expected: no output — no issues recorded.

- [ ] **Step 7: Commit**

```bash
git add app/Modules/UI/Sources/DesignSystem.swift \
        app/Modules/LocationsFeature/Sources/LocationDetailView.swift
git commit -m "feat(locations): give every inspector header a 128pt portrait slot"
```

---

### Task 3: The Lagrange schematic

A `Canvas`-drawn two-body diagram in the textbook arrangement, with the selected point highlighted by size and lightness rather than hue.

**Files:**
- Create: `app/Modules/LocationsFeature/Sources/LagrangeDiagram.swift`
- Create: `app/Modules/LocationsFeature/Tests/LagrangeGeometryTests.swift`
- Modify: `app/Modules/LocationsFeature/Sources/LocationDetailView.swift` (`LagrangeInspector` only)

**Interfaces:**
- Produces:
  ```swift
  enum LagrangeGeometry {
      static func points(orbitRadius: CGFloat, centre: CGPoint) -> [Int: CGPoint]
  }
  struct LagrangeDiagram: View { init(selected: Int) }
  ```

- [ ] **Step 1: Write the failing geometry test**

The drawing is not testable, but the point placement is. Create
`app/Modules/LocationsFeature/Tests/LagrangeGeometryTests.swift`:

```swift
import Testing
import CoreGraphics
@testable import LocationsFeature

@Suite("LagrangeGeometry")
struct LagrangeGeometryTests {
    private let centre = CGPoint(x: 0, y: 0)
    private let r: CGFloat = 100

    @Test("all five points are placed")
    func fivePoints() {
        let pts = LagrangeGeometry.points(orbitRadius: r, centre: centre)
        #expect(Set(pts.keys) == [1, 2, 3, 4, 5])
    }

    @Test("L1 sits between the star and the planet, L2 beyond it, L3 opposite")
    func collinearPoints() {
        let pts = LagrangeGeometry.points(orbitRadius: r, centre: centre)
        // The planet sits at +x. Distances from the star at the origin.
        #expect(pts[1]!.x < r && pts[1]!.x > 0)
        #expect(pts[2]!.x > r)
        #expect(pts[3]!.x < 0)
        for n in [1, 2, 3] {
            #expect(abs(pts[n]!.y) < 0.001)
        }
    }

    @Test("L4 and L5 sit on the orbit, 60 degrees either side of the planet")
    func trojanPoints() {
        let pts = LagrangeGeometry.points(orbitRadius: r, centre: centre)
        for n in [4, 5] {
            let d = hypot(pts[n]!.x - centre.x, pts[n]!.y - centre.y)
            #expect(abs(d - r) < 0.001)
        }
        #expect(pts[4]!.y < 0)              // 60 degrees ahead, screen y grows downward
        #expect(pts[5]!.y > 0)
        #expect(abs(pts[4]!.x - pts[5]!.x) < 0.001)
        #expect(abs(pts[4]!.x - r * 0.5) < 0.001)
    }
}
```

- [ ] **Step 2: Run it and confirm it fails**

```bash
cd app/Modules && swift test --filter LagrangeGeometry \
  --event-stream-output-path /tmp/lagrange.jsonl
```

Expected: compile failure — `cannot find 'LagrangeGeometry' in scope`.

- [ ] **Step 3: Write the diagram**

Create `app/Modules/LocationsFeature/Sources/LagrangeDiagram.swift`:

```swift
import CoreGraphics
import SwiftUI
import UI

/// Where the five Lagrange points fall for a planet on a circular orbit of
/// `orbitRadius` about a star at `centre`, with the planet at +x.
enum LagrangeGeometry {
    static func points(orbitRadius r: CGFloat, centre c: CGPoint) -> [Int: CGPoint] {
        [
            1: CGPoint(x: c.x + r * 0.85, y: c.y),
            2: CGPoint(x: c.x + r * 1.15, y: c.y),
            3: CGPoint(x: c.x - r, y: c.y),
            4: CGPoint(x: c.x + r * 0.5, y: c.y - r * sqrt(3) / 2),
            5: CGPoint(x: c.x + r * 0.5, y: c.y + r * sqrt(3) / 2),
        ]
    }
}

/// The five Lagrange points of a star/planet pair, with one of them selected.
/// Selection reads through size and lightness, never hue alone.
struct LagrangeDiagram: View {
    let selected: Int

    var body: some View {
        Canvas { context, size in
            let centre = CGPoint(x: size.width / 2, y: size.height / 2)
            let r = min(size.width, size.height) * 0.34
            let points = LagrangeGeometry.points(orbitRadius: r, centre: centre)
            let planet = CGPoint(x: centre.x + r, y: centre.y)

            context.stroke(
                Path(ellipseIn: CGRect(x: centre.x - r, y: centre.y - r, width: r * 2, height: r * 2)),
                with: .color(.rcSeparator),
                lineWidth: Hairline.thin
            )
            context.fill(dot(at: centre, radius: 5), with: .color(.rcTextSecondary))
            context.fill(dot(at: planet, radius: 3.5), with: .color(.rcTextSecondary))

            for (n, p) in points where n != selected {
                context.stroke(cross(at: p, arm: 2.5), with: .color(.rcTextTertiary), lineWidth: Hairline.regular)
            }
            if let p = points[selected] {
                context.fill(dot(at: p, radius: 5), with: .color(.rcAccent))
                context.stroke(dot(at: p, radius: 8), with: .color(.rcAccent), lineWidth: Hairline.regular)
                context.draw(
                    Text("L\(selected)").font(.rcMonoSmall).foregroundStyle(.rcTextPrimary),
                    at: CGPoint(x: p.x, y: p.y - 16)
                )
            }
        }
    }

    private func dot(at p: CGPoint, radius: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2))
    }

    private func cross(at p: CGPoint, arm: CGFloat) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: p.x - arm, y: p.y)); path.addLine(to: CGPoint(x: p.x + arm, y: p.y))
        path.move(to: CGPoint(x: p.x, y: p.y - arm)); path.addLine(to: CGPoint(x: p.x, y: p.y + arm))
        return path
    }
}
```

- [ ] **Step 4: Run the test and confirm it passes**

```bash
cd app/Modules && swift test --filter LagrangeGeometry \
  --event-stream-output-path /tmp/lagrange.jsonl
jq -r 'select(.payload.kind=="issueRecorded") | .payload' /tmp/lagrange.jsonl
```

Expected: no output.

- [ ] **Step 5: Wire it into the inspector**

In `LagrangeInspector`, replace the placeholder portrait:

```swift
portrait: AnyView(PortraitFrame { LagrangeDiagram(selected: point) }),
```

- [ ] **Step 6: Build**

```bash
cd app/Modules && swift build --build-tests 2>&1 | tail -20
```

Expected: no errors.

- [ ] **Step 7: Commit**

```bash
git add app/Modules/LocationsFeature/Sources/LagrangeDiagram.swift \
        app/Modules/LocationsFeature/Tests/LagrangeGeometryTests.swift \
        app/Modules/LocationsFeature/Sources/LocationDetailView.swift
git commit -m "feat(locations): draw a Lagrange schematic in the header portrait"
```

---

### Task 4: The structure symbol tile

`.megastructure` and `.object` sites have no map geometry to borrow, so they get a symbol in the same 128pt chrome.

**Files:**
- Create: `app/Modules/LocationsFeature/Sources/SiteGlyph.swift`
- Create: `app/Modules/LocationsFeature/Tests/SiteGlyphTests.swift`
- Modify: `app/Modules/LocationsFeature/Sources/LocationDetailView.swift` (`ObjectInspector` only)

**Interfaces:**
- Produces:
  ```swift
  enum SiteGlyph {
      static func symbolName(for site: SpecialSite) -> String
  }
  ```

- [ ] **Step 1: Write the failing test**

Create `app/Modules/LocationsFeature/Tests/SiteGlyphTests.swift`:

```swift
import Testing
import UniverseModels
@testable import LocationsFeature

@Suite("SiteGlyph")
struct SiteGlyphTests {
    @Test("an inbound impactor is a hazard, not a structure")
    func impactor() {
        let site = SpecialSite(designation: "SOL-OBJ-1", kind: .object,
                               objectType: "incoming_asteroid")
        #expect(SiteGlyph.symbolName(for: site) == "exclamationmark.triangle")
    }

    @Test("a megastructure gets the construction glyph")
    func megastructure() {
        let site = SpecialSite(designation: "SOL-MEGA-1", kind: .megastructure)
        #expect(SiteGlyph.symbolName(for: site) == "building.2")
    }

    @Test("kuiper and oort fall back to a region glyph")
    func regions() {
        for kind in [SpecialSiteKind.kuiper, .oort] {
            let site = SpecialSite(designation: "SOL-K", kind: kind)
            #expect(SiteGlyph.symbolName(for: site) == "circle.dotted")
        }
    }

    @Test("an unremarkable object gets the generic glyph")
    func object() {
        let site = SpecialSite(designation: "SOL-OBJ-2", kind: .object)
        #expect(SiteGlyph.symbolName(for: site) == "shippingbox")
    }
}
```

- [ ] **Step 2: Run it and confirm it fails**

```bash
cd app/Modules && swift test --filter SiteGlyph \
  --event-stream-output-path /tmp/siteglyph.jsonl
```

Expected: compile failure — `cannot find 'SiteGlyph' in scope`.

- [ ] **Step 3: Write the implementation**

Create `app/Modules/LocationsFeature/Sources/SiteGlyph.swift`:

```swift
import SwiftUI
import UniverseModels

/// The SF Symbol standing in for a site that has no rendered geometry.
enum SiteGlyph {
    static func symbolName(for site: SpecialSite) -> String {
        if site.objectType == "incoming_asteroid" { return "exclamationmark.triangle" }
        switch site.kind {
        case .megastructure:      return "building.2"
        case .kuiper, .oort:      return "circle.dotted"
        case .object, .lagrange:  return "shippingbox"
        }
    }
}

/// A site's symbol at portrait size, in the header's chrome.
struct SiteGlyphPortrait: View {
    let site: SpecialSite

    private var isThreat: Bool { site.objectType == "incoming_asteroid" }

    var body: some View {
        Image(systemName: SiteGlyph.symbolName(for: site))
            .font(.system(size: IconSize.display, weight: .regular))
            .foregroundStyle(isThreat ? .rcDanger : .rcTextSecondary)
    }
}
```

- [ ] **Step 4: Run the test and confirm it passes**

```bash
cd app/Modules && swift test --filter SiteGlyph \
  --event-stream-output-path /tmp/siteglyph.jsonl
jq -r 'select(.payload.kind=="issueRecorded") | .payload' /tmp/siteglyph.jsonl
```

Expected: no output.

- [ ] **Step 5: Wire it into `ObjectInspector`**

`.kuiper` and `.oort` take the Metal point field in Task 10; until then all four
kinds take the glyph. Replace the placeholder portrait:

```swift
portrait: AnyView(PortraitFrame { SiteGlyphPortrait(site: site) }),
```

- [ ] **Step 6: Build**

```bash
cd app/Modules && swift build --build-tests 2>&1 | tail -20
```

Expected: no errors.

- [ ] **Step 7: Commit**

```bash
git add app/Modules/LocationsFeature/Sources/SiteGlyph.swift \
        app/Modules/LocationsFeature/Tests/SiteGlyphTests.swift \
        app/Modules/LocationsFeature/Sources/LocationDetailView.swift
git commit -m "feat(locations): give a geometry-less site a portrait glyph"
```

---

### Task 5: Extract `BodyAppearance` from `OrreryMapping`

The same twelve appearance fields are derived inline in three places. Extract them into one type and two functions the map and the portrait both call. This task changes no behaviour — it is a pure lift, and the existing orrery tests are the proof.

**Files:**
- Create: `app/Modules/NewStarMapFeature/Sources/BodyAppearance.swift`
- Modify: `app/Modules/NewStarMapFeature/Sources/OrreryMapping.swift:129-191, 526-559, 590-626`
- Create: `app/Modules/NewStarMapFeature/Tests/BodyAppearanceTests.swift`

**Interfaces:**
- Consumes: `PlanetType`, `Atmosphere`, `BodySpin`, `RingSystem`, `PlanetMaterial`, `OrreryPlaneOptions` — all internal to `NewStarMapFeature`.
- Produces:
  ```swift
  struct BodyAppearance: Equatable, Sendable {
      var planetType: PlanetType
      var rawType: String?
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

- [ ] **Step 1: Write the failing tests**

Create `app/Modules/NewStarMapFeature/Tests/BodyAppearanceTests.swift`:

```swift
import Testing
import UniverseModels
@testable import NewStarMapFeature

@Suite("BodyAppearance")
struct BodyAppearanceTests {
    @Test("a planet carries its raw type through, so irregularity can read it")
    func rawTypeSurvives() {
        let planet = Planet(designation: "SOL-3", type: "Terrestrial",
                            typeEstimated: false, inHabitableZone: true, recon: .scanned)
        #expect(OrreryMapping.appearance(planet: planet, options: .default).rawType == "Terrestrial")
    }

    @Test("a ringed gas giant resolves a ring system")
    func ringedGiant() {
        let planet = Planet(
            designation: "SOL-6", type: "Gas Giant", typeEstimated: false,
            inHabitableZone: false, recon: .scanned,
            physical: BodyPhysical(rings: true, rotationPeriodHours: 10.7)
        )
        #expect(OrreryMapping.appearance(planet: planet, options: .default).rings != nil)
    }

    @Test("an unringed planet resolves no ring system")
    func unringed() {
        let planet = Planet(designation: "SOL-4", type: "Barren", typeEstimated: false,
                            inHabitableZone: false, recon: .scanned)
        #expect(OrreryMapping.appearance(planet: planet, options: .default).rings == nil)
    }

    @Test("a planet's estimated flag is its own typeEstimated")
    func planetEstimated() {
        let planet = Planet(designation: "SOL-9", type: "Ice Giant", typeEstimated: true,
                            inHabitableZone: false, recon: .scanned)
        #expect(OrreryMapping.appearance(planet: planet, options: .default).estimated)
    }

    @Test("a moon's estimated flag comes from recon, since it has no typeEstimated")
    func moonEstimated() {
        let scanned = Moon(designation: "SOL-3-1", type: "Rocky", recon: .scanned)
        let aware = Moon(designation: "SOL-3-2", type: "Rocky", recon: .aware)
        #expect(!OrreryMapping.appearance(moon: scanned, options: .default).estimated)
        #expect(OrreryMapping.appearance(moon: aware, options: .default).estimated)
    }

    @Test("a moon never has rings and is never in a habitable zone")
    func moonDefaults() {
        let moon = Moon(designation: "SOL-6-1", type: "Icy", recon: .scanned,
                        physical: BodyPhysical(rings: true))
        let a = OrreryMapping.appearance(moon: moon, options: .default)
        #expect(a.rings == nil)
        #expect(!a.inHabitableZone)
    }

    @Test("a moon's atmosphere goes through the moon-specific derivation")
    func moonAtmosphere() {
        let moon = Moon(designation: "SOL-6-2", type: "Rocky", recon: .scanned,
                        physical: BodyPhysical(tags: ["thick_atmosphere"], hasAtmosphere: true))
        #expect(OrreryMapping.appearance(moon: moon, options: .default).atmosphere == .dense)
    }

    @Test("the appearance seed depends only on designation and rotation period")
    func seedIsStable() {
        let a = Planet(designation: "SOL-3", type: "Terrestrial", typeEstimated: false,
                       inHabitableZone: true, recon: .scanned,
                       physical: BodyPhysical(rotationPeriodHours: 24))
        let b = Planet(designation: "SOL-3", type: "Gas Giant", typeEstimated: true,
                       inHabitableZone: false, recon: .aware,
                       physical: BodyPhysical(rotationPeriodHours: 24))
        #expect(OrreryMapping.appearance(planet: a, options: .default).appearanceSeed
                == OrreryMapping.appearance(planet: b, options: .default).appearanceSeed)
    }

    @Test("a tidally locked moon reports a locked spin")
    func lockedSpin() {
        let moon = Moon(designation: "SOL-3-1", type: "Rocky", recon: .scanned,
                        physical: BodyPhysical(rotationPeriodHours: 655, tidallyLocked: true))
        #expect(OrreryMapping.appearance(moon: moon, options: .default).spin.tidallyLocked)
    }
}
```

- [ ] **Step 2: Run and confirm failure**

```bash
cd app/Modules && swift test --filter BodyAppearance \
  --event-stream-output-path /tmp/appearance.jsonl
```

Expected: compile failure — `cannot find 'BodyAppearance' in scope`.

- [ ] **Step 3: Write `BodyAppearance.swift`**

```swift
import UniverseModels
import simd

/// Everything about how one body looks, independent of where it sits in a system.
/// Exactly the inputs `PlanetMaterial` and `BodySpin` need — nothing scene-scoped.
struct BodyAppearance: Equatable, Sendable {
    var planetType: PlanetType
    /// The raw API type string. `PlanetMaterial.irregularity` reads this, not
    /// `planetType` — "Captured Asteroid" has no `PlanetType` case.
    var rawType: String?
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
    static func appearance(planet p: Planet, options: OrreryPlaneOptions = .default) -> BodyAppearance {
        let type = PlanetType(apiType: p.type)
        let seed = appearanceSeed(designation: p.designation,
                                  rotationPeriodHours: p.physical?.rotationPeriodHours)
        return BodyAppearance(
            planetType: type,
            rawType: p.type,
            lifeStage: p.lifeStage,
            estimated: p.typeEstimated,
            tags: p.physical?.tags ?? [],
            surfaceTempC: p.physical?.surfaceTempC,
            atmosphere: Atmosphere(apiValue: p.physical?.atmosphere),
            inHabitableZone: p.inHabitableZone,
            hasSubsurfaceOcean: p.physical?.hasSubsurfaceOcean ?? false,
            appearanceSeed: seed,
            spin: BodySpin(tiltDeg: p.physical?.axialTiltDeg,
                           rotationHours: p.physical?.rotationPeriodHours,
                           tidallyLocked: p.physical?.tidallyLocked ?? false,
                           tiltCapDeg: options.tiltCapDeg),
            rings: PlanetMaterial.ringSystem(hasRings: p.physical?.rings ?? false,
                                             type: type, seed: seed))
    }

    static func appearance(moon m: Moon, options: OrreryPlaneOptions = .default) -> BodyAppearance {
        BodyAppearance(
            planetType: PlanetType(apiType: m.type),
            rawType: m.type,
            lifeStage: m.lifeStage,
            estimated: m.recon != .scanned,
            tags: m.physical?.tags ?? [],
            surfaceTempC: m.physical?.surfaceTempC,
            atmosphere: moonAtmosphere(m),
            inHabitableZone: false,
            hasSubsurfaceOcean: m.physical?.hasSubsurfaceOcean ?? false,
            appearanceSeed: appearanceSeed(designation: m.designation,
                                           rotationPeriodHours: m.physical?.rotationPeriodHours),
            spin: BodySpin(tiltDeg: m.physical?.axialTiltDeg,
                           rotationHours: m.physical?.rotationPeriodHours,
                           tidallyLocked: m.physical?.tidallyLocked ?? false,
                           tiltCapDeg: options.tiltCapDeg),
            rings: nil)
    }
}
```

- [ ] **Step 4: Rewrite the three call sites to consume it**

In `systemModel` (`OrreryMapping.swift:129-135`), replace the `ringSystems` array:

```swift
let appearances = s.planets.map { appearance(planet: $0, options: options) }
let ringSystems = appearances.map(\.rings)
```

In the `OrreryPlanet` build (`:167-191`), read from `appearances[i]` instead of
re-deriving — `planetType`, `estimated`, `tags`, `surfaceTempC`, `atmosphere`,
`appearanceSeed`, `spin`, `rings`. Leave every other argument exactly as it is.

In the `CentralBody` block (`:526-559`), derive once and read from it:

```swift
let ca = appearance(planet: planet, options: options)
let centralRings = ca.rings
let centralClearance = clearanceRadius(centralScene, centralRings)
let centralSpin = ca.spin
let centralSeed = ca.appearanceSeed
let central = CentralBody(
    displayRadius: centralScene,
    rings: centralRings,
    spin: centralSpin,
    orbitPole: options.decoupleMoonPlane ? nil : centralSpin.pole(seed: centralSeed),
    planetType: ca.planetType,
    lifeStage: ca.lifeStage, estimated: ca.estimated,
    tags: ca.tags,
    inHabitableZone: ca.inHabitableZone,
    surfaceTempC: ca.surfaceTempC,
    atmosphere: ca.atmosphere,
    appearanceSeed: centralSeed,
    orbitalDistanceAu: planet.orbitalDistanceAu,
    periodDays: planet.physical?.orbitalPeriodDays)
```

In the promoted-moon block (`:590-626`), derive `let ma = appearance(moon: m, options: options)`
inside the `map` and read `ma.planetType`, `ma.estimated`, `ma.tags`, `ma.surfaceTempC`,
`ma.atmosphere`, `ma.appearanceSeed`, `ma.spin`. Leave `hasSubsurfaceOcean`,
`orbitalDistanceKm`, `periodDays`, `displayRadius` and everything else untouched.

- [ ] **Step 5: Run the new tests and the whole existing orrery suite**

```bash
cd app/Modules && swift test --filter 'BodyAppearance|Orrery' \
  --event-stream-output-path /tmp/appearance.jsonl
jq -r 'select(.payload.kind=="issueRecorded") | .payload' /tmp/appearance.jsonl
```

Expected: no output. `OrreryTests` and `OrreryPushTests` passing untouched is what
proves the lift changed no behaviour. If either fails, the extraction is wrong — fix
the extraction, never the existing test.

- [ ] **Step 6: Commit**

```bash
git add app/Modules/NewStarMapFeature/Sources/BodyAppearance.swift \
        app/Modules/NewStarMapFeature/Sources/OrreryMapping.swift \
        app/Modules/NewStarMapFeature/Tests/BodyAppearanceTests.swift
git commit -m "refactor(starmap): derive a body's appearance in one place"
```

---

### Task 6: Lift `PlacedBody` and the uniform builders out of the renderer

`PlacedBody` and `bodyUniform`/`ringUniform`/`atmosphereUniform` are pure functions of their arguments and touch no renderer state. Move them so a second renderer can call them, and add a portrait-shaped initializer.

**Files:**
- Create: `app/Modules/NewStarMapFeature/Sources/OrreryBodyRender.swift`
- Modify: `app/Modules/NewStarMapFeature/Sources/StarFieldRenderer.swift:1985-2013, 2126-2171`
- Create: `app/Modules/NewStarMapFeature/Tests/PlacedBodyPortraitTests.swift`

**Interfaces:**
- Consumes: `BodyAppearance` from Task 5.
- Produces: `struct PlacedBody` at internal scope; free functions `bodyUniform(_:) -> OrreryBodyUniform`, `ringUniform(_:) -> OrreryRingUniform?`, `atmosphereUniform(_:) -> OrreryAtmosphereUniform?`; and
  ```swift
  extension PlacedBody {
      init(portrait: BodyAppearance, designation: String,
           center: SIMD3<Float>, radius: Float, sun: SIMD3<Float>)
  }
  ```

- [ ] **Step 1: Write the failing test**

Create `app/Modules/NewStarMapFeature/Tests/PlacedBodyPortraitTests.swift`:

```swift
import Testing
import UniverseModels
import simd
@testable import NewStarMapFeature

@Suite("PlacedBody portrait")
struct PlacedBodyPortraitTests {
    private func planet(_ type: String, rings: Bool = false) -> Planet {
        Planet(designation: "SOL-6", type: type, typeEstimated: false,
               inHabitableZone: false, recon: .scanned,
               physical: BodyPhysical(rings: rings, rotationPeriodHours: 10.7))
    }

    private func portrait(_ p: Planet) -> PlacedBody {
        PlacedBody(portrait: OrreryMapping.appearance(planet: p, options: .default),
                   designation: p.designation, center: .zero, radius: 1,
                   sun: SIMD3(28, 12, 20))
    }

    @Test("a portrait body is never central and sits at the origin")
    func placement() {
        let b = portrait(planet("Gas Giant"))
        #expect(!b.isCentral)
        #expect(b.center == .zero)
        #expect(b.radius == 1)
    }

    @Test("a ringed giant carries its rings into the uniform builder")
    func rings() {
        #expect(ringUniform(portrait(planet("Gas Giant", rings: true))) != nil)
        #expect(ringUniform(portrait(planet("Gas Giant", rings: false))) == nil)
    }

    @Test("a captured asteroid is irregular, read off the raw type string")
    func irregular() {
        let moon = Moon(designation: "SOL-5-9", type: "Captured Asteroid", recon: .scanned)
        let b = PlacedBody(portrait: OrreryMapping.appearance(moon: moon, options: .default),
                           designation: moon.designation, center: .zero, radius: 1,
                           sun: SIMD3(28, 12, 20))
        #expect(b.irregularity > 0)
    }

    @Test("a tidally locked body still spins from its designation, not an orbit angle")
    func lockedPhase() {
        let moon = Moon(designation: "SOL-3-1", type: "Rocky", recon: .scanned,
                        physical: BodyPhysical(rotationPeriodHours: 655, tidallyLocked: true))
        let b = PlacedBody(portrait: OrreryMapping.appearance(moon: moon, options: .default),
                           designation: moon.designation, center: .zero, radius: 1,
                           sun: SIMD3(28, 12, 20))
        #expect(b.spinRate != 0)
    }

    @Test("the sun position reaches the body uniform unchanged")
    func sunTravels() {
        let sun = SIMD3<Float>(28, 12, 20)
        let u = bodyUniform(portrait(planet("Terrestrial")))
        #expect(SIMD3(u.sunEmissive.x, u.sunEmissive.y, u.sunEmissive.z) == sun)
    }
}
```

- [ ] **Step 2: Run and confirm failure**

```bash
cd app/Modules && swift test --filter 'PlacedBody portrait' \
  --event-stream-output-path /tmp/placed.jsonl
```

Expected: failure — `PlacedBody` is private to `StarFieldRenderer`.

- [ ] **Step 3: Move the code**

Cut `private struct PlacedBody { … }` from `StarFieldRenderer.swift:1985-2013` and the
three `private func …Uniform(_:)` from `:2126-2171`. Paste into a new
`app/Modules/NewStarMapFeature/Sources/OrreryBodyRender.swift`, dropping `private` and
making the methods free functions. Keep every doc comment verbatim — they are inside
budget and carry invariants. Add the imports the file needs:

```swift
import CStarMapShaderTypes
import UniverseModels
import simd
```

Then append the portrait initializer:

```swift
extension PlacedBody {
    /// A body drawn alone, filling its own frame: no orbit, no siblings, no parent
    /// star. A locked body takes the free-rotator phase, as a central body does.
    init(portrait a: BodyAppearance, designation: String,
         center: SIMD3<Float>, radius: Float, sun: SIMD3<Float>) {
        let irregularity = PlanetMaterial.irregularity(type: a.rawType)
        self.init(
            isCentral: false, center: center, radius: radius, sun: sun,
            type: a.planetType, lifeStage: a.lifeStage, estimated: a.estimated,
            tags: a.tags, inHabitableZone: a.inHabitableZone,
            surfaceTempC: a.surfaceTempC, atmosphere: a.atmosphere,
            appearanceSeed: a.appearanceSeed,
            spinPhase: Float(OrreryMapping.phaseDeg(designation)) * .pi / 180,
            spinAxis: BodySpin.renderSpinAxis(
                irregularity: irregularity, locked: false,
                pole: a.spin.pole(seed: a.appearanceSeed),
                tumbleSeed: a.appearanceSeed),
            spinRate: a.spin.spinRate(),
            ocean: a.hasSubsurfaceOcean ? 1 : 0,
            irregularity: irregularity,
            rings: a.rings)
    }
}
```

If `PlanetMaterial.irregularity(type:)` takes a non-optional `String`, pass
`a.rawType ?? ""`. Check the real signature at `PlanetMaterial.swift:209` rather than
assuming it.

At the renderer call sites (`StarFieldRenderer.swift:1923`, `:1932`, `:1937`, `:1951`,
`:1956`) drop the method receiver so they call the free functions. Nothing else in the
renderer changes.

- [ ] **Step 4: Run the new test plus the full star-map suite**

```bash
cd app/Modules && swift test --filter NewStarMapFeature \
  --event-stream-output-path /tmp/starmap.jsonl
jq -r 'select(.payload.kind=="issueRecorded") | .payload' /tmp/starmap.jsonl
```

Expected: no output.

- [ ] **Step 5: Commit**

```bash
git add app/Modules/NewStarMapFeature/Sources/OrreryBodyRender.swift \
        app/Modules/NewStarMapFeature/Sources/StarFieldRenderer.swift \
        app/Modules/NewStarMapFeature/Tests/PlacedBodyPortraitTests.swift
git commit -m "refactor(starmap): make the body render path callable without the map"
```

---

### Task 7: The portrait renderer — bodies, rings, atmosphere

The two-pass HDR-then-tonemap renderer, drawing a planet or moon through the production shaders. Modelled on the deleted `AsteroidPlayground.swift` — recover it with `git show 54e4ff8 -- app/Modules/NewStarMapFeature/Sources/AsteroidPlayground.swift` and **read it before writing**; it is a working reference for this exact two-pass setup.

**Files:**
- Create: `app/Modules/NewStarMapFeature/Sources/BodyPortraitRenderer.swift`
- Create: `app/Modules/NewStarMapFeature/Sources/BodyPortraitSubject.swift`

**Interfaces:**
- Consumes: `PlacedBody`, `bodyUniform`, `ringUniform`, `atmosphereUniform` from Task 6.
- Produces:
  ```swift
  public enum BodyPortrait: Equatable, Sendable {
      case star(SystemStar), planet(Planet), moon(Moon), belt(Belt), region(SpecialSite)
  }
  final class BodyPortraitRenderer: NSObject, MTKViewDelegate { var subject: BodyPortrait? }
  ```

- [ ] **Step 1: Define the subject**

Create `app/Modules/NewStarMapFeature/Sources/BodyPortraitSubject.swift`:

```swift
import UniverseModels

/// What a location detail header's 128pt square renders.
public enum BodyPortrait: Equatable, Sendable {
    case star(SystemStar)
    case planet(Planet)
    case moon(Moon)
    case belt(Belt)
    /// A Kuiper belt or Oort cloud, drawn as a wide sparse point field.
    case region(SpecialSite)
}
```

- [ ] **Step 2: Write the renderer**

Create `app/Modules/NewStarMapFeature/Sources/BodyPortraitRenderer.swift`. Every
constant below is cited, and each one fails silently if wrong.

```swift
import AppKit
import CStarMapShaderTypes
import MetalKit
import UniverseModels
import simd

/// Draws one body alone through the star map's own shaders and tone-map, so a body
/// looks the same in a location inspector as it does in the map.
final class BodyPortraitRenderer: NSObject, MTKViewDelegate {
    var subject: BodyPortrait?
    /// Must match what the map reads, or a body leans differently in the two views.
    /// `OrreryPlaneOptions` is nested in `OrreryMapping`, so it needs qualifying here.
    var options: OrreryMapping.OrreryPlaneOptions = .default

    private var device: MTLDevice?
    private var queue: MTLCommandQueue?
    private var bodyPipeline: MTLRenderPipelineState?
    private var ringPipeline: MTLRenderPipelineState?
    private var atmoPipeline: MTLRenderPipelineState?
    private var tonemapPipeline: MTLRenderPipelineState?
    private var bodyDepthState: MTLDepthStencilState?
    private var readDepthState: MTLDepthStencilState?
    private var hdrTexture: MTLTexture?
    private var depthTexture: MTLTexture?
    private let start = CACurrentMediaTime()

    private let bodyRadius: Float = 1
    private let fovy: Float = 60 * .pi / 180
    private let cameraAzimuth: Float = 0.6
    private let cameraElevation: Float = 18 * .pi / 180
    private let sunAzimuth: Float = 0.9
    private let sunElevation: Float = 0.30
    private let exposure: Float = 1.3

    @MainActor func configure(view: MTKView) {
        guard let device = view.device ?? MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = try? device.makeDefaultLibrary(bundle: .module)
        else { return }
        self.device = device
        self.queue = queue

        func alphaOver(_ ca: MTLRenderPipelineColorAttachmentDescriptor) {
            ca.pixelFormat = .rgba16Float
            ca.isBlendingEnabled = true
            ca.rgbBlendOperation = .add
            ca.alphaBlendOperation = .add
            ca.sourceRGBBlendFactor = .sourceAlpha
            ca.destinationRGBBlendFactor = .oneMinusSourceAlpha
            ca.sourceAlphaBlendFactor = .one
            ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }
        func additive(_ ca: MTLRenderPipelineColorAttachmentDescriptor) {
            ca.pixelFormat = .rgba16Float
            ca.isBlendingEnabled = true
            ca.rgbBlendOperation = .add
            ca.alphaBlendOperation = .add
            ca.sourceRGBBlendFactor = .one
            ca.destinationRGBBlendFactor = .one
            ca.sourceAlphaBlendFactor = .one
            ca.destinationAlphaBlendFactor = .one
        }
        func pipeline(_ vertex: String, _ fragment: String,
                      _ blend: (MTLRenderPipelineColorAttachmentDescriptor) -> Void)
            -> MTLRenderPipelineState? {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: vertex)
            d.fragmentFunction = library.makeFunction(name: fragment)
            blend(d.colorAttachments[0]!)
            d.depthAttachmentPixelFormat = .depth32Float
            return try? device.makeRenderPipelineState(descriptor: d)
        }

        bodyPipeline = pipeline("orrery_body_vertex", "orrery_body_fragment", alphaOver)
        ringPipeline = pipeline("orrery_ring_vertex", "orrery_ring_fragment", alphaOver)
        atmoPipeline = pipeline("orrery_atmosphere_vertex", "orrery_atmosphere_fragment", additive)

        let tm = MTLRenderPipelineDescriptor()
        tm.vertexFunction = library.makeFunction(name: "fullscreen_vertex")
        tm.fragmentFunction = library.makeFunction(name: "tonemap_fragment")
        tm.colorAttachments[0].pixelFormat = view.colorPixelFormat
        tonemapPipeline = try? device.makeRenderPipelineState(descriptor: tm)

        let bd = MTLDepthStencilDescriptor()
        bd.depthCompareFunction = .less; bd.isDepthWriteEnabled = true
        bodyDepthState = device.makeDepthStencilState(descriptor: bd)
        let rd = MTLDepthStencilDescriptor()
        rd.depthCompareFunction = .less; rd.isDepthWriteEnabled = false
        readDepthState = device.makeDepthStencilState(descriptor: rd)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        hdrTexture = nil
        depthTexture = nil
    }

    func draw(in view: MTKView) {
        let size = view.drawableSize
        guard let device, let queue, let tonemapPipeline,
              size.width > 0, size.height > 0,
              let drawable = view.currentDrawable,
              let finalPass = view.currentRenderPassDescriptor
        else { return }

        makeTargets(device: device, size: size)
        guard let hdrTexture, let depthTexture, let cmd = queue.makeCommandBuffer() else { return }

        var u = uniforms(aspect: Float(size.width / size.height))

        let scene = MTLRenderPassDescriptor()
        scene.colorAttachments[0].texture = hdrTexture
        scene.colorAttachments[0].loadAction = .clear
        scene.colorAttachments[0].storeAction = .store
        scene.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        scene.depthAttachment.texture = depthTexture
        scene.depthAttachment.loadAction = .clear
        scene.depthAttachment.storeAction = .dontCare
        scene.depthAttachment.clearDepth = 1
        if let enc = cmd.makeRenderCommandEncoder(descriptor: scene) {
            encodeSubject(into: enc, uniforms: &u)
            enc.endEncoding()
        }

        if let enc = cmd.makeRenderCommandEncoder(descriptor: finalPass) {
            enc.setRenderPipelineState(tonemapPipeline)
            enc.setFragmentTexture(hdrTexture, index: 0)
            enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }

        cmd.present(drawable)
        cmd.commit()
    }

    private func encodeSubject(into enc: MTLRenderCommandEncoder, uniforms u: inout Uniforms) {
        switch subject {
        case .planet(let p):
            encodeBody(OrreryMapping.appearance(planet: p, options: options),
                       designation: p.designation, into: enc, uniforms: &u)
        case .moon(let m):
            encodeBody(OrreryMapping.appearance(moon: m, options: options),
                       designation: m.designation, into: enc, uniforms: &u)
        case .star, .belt, .region, .none:
            break   // Tasks 8 and 9
        }
    }

    private func encodeBody(_ appearance: BodyAppearance, designation: String,
                            into enc: MTLRenderCommandEncoder, uniforms u: inout Uniforms) {
        guard let bodyPipeline, let bodyDepthState, let readDepthState else { return }
        let placed = PlacedBody(portrait: appearance, designation: designation,
                                center: .zero, radius: bodyRadius, sun: sunPosition())

        enc.setRenderPipelineState(bodyPipeline)
        enc.setDepthStencilState(bodyDepthState)
        enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
        enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
        var body = bodyUniform(placed)
        enc.setVertexBytes(&body, length: MemoryLayout<OrreryBodyUniform>.stride, index: 2)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)

        if var ring = ringUniform(placed), let ringPipeline {
            enc.setRenderPipelineState(ringPipeline)
            enc.setDepthStencilState(readDepthState)
            enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
            enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
            enc.setVertexBytes(&ring, length: MemoryLayout<OrreryRingUniform>.stride, index: 2)
            enc.setFragmentBytes(&ring, length: MemoryLayout<OrreryRingUniform>.stride, index: 2)
            // SYNC POINT: kRingSegments = 192 in Orrery.metal.
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 193 * 2)
        }

        if var atmo = atmosphereUniform(placed), let atmoPipeline {
            enc.setRenderPipelineState(atmoPipeline)
            enc.setDepthStencilState(readDepthState)
            enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
            enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
            enc.setVertexBytes(&atmo, length: MemoryLayout<OrreryAtmosphereUniform>.stride, index: 2)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }
    }

    private func makeTargets(device: MTLDevice, size: CGSize) {
        let w = Int(size.width), h = Int(size.height)
        if let hdrTexture, hdrTexture.width == w, hdrTexture.height == h { return }

        let color = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
        color.usage = [.renderTarget, .shaderRead]
        color.storageMode = .private
        hdrTexture = device.makeTexture(descriptor: color)

        let depth = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float, width: w, height: h, mipmapped: false)
        depth.usage = [.renderTarget]
        depth.storageMode = .private
        depthTexture = device.makeTexture(descriptor: depth)
    }

    /// The widest thing the frame must hold, in body radii — a ring's outer edge, or
    /// an irregular body's long axis at 1.54x (unit-product axes).
    private func extent() -> Float {
        switch subject {
        case .planet(let p):
            let rings = OrreryMapping.appearance(planet: p, options: options).rings
            return max(1.54, rings.map { $0.outerFrac } ?? 1)
        default:
            return 1.54
        }
    }

    private func cameraDistance() -> Float {
        let fill: Float = 0.85
        return max(extent() * bodyRadius / (tan(fovy * 0.5) * fill), bodyRadius * 5.1)
    }

    private func sunPosition() -> SIMD3<Float> {
        let ce = cos(sunElevation), se = sin(sunElevation)
        // 40x the radius, matching bodySunDistance. A nearer sun unlights the body.
        let d = bodyRadius * 40
        return SIMD3(d * ce * sin(sunAzimuth), d * se, d * ce * cos(sunAzimuth))
    }

    private func uniforms(aspect: Float) -> Uniforms {
        var u = Uniforms()
        let d = cameraDistance()
        let ce = cos(cameraElevation), se = sin(cameraElevation)
        let eye = SIMD3<Float>(d * ce * sin(cameraAzimuth), d * se, d * ce * cos(cameraAzimuth))
        u.view = .lookAt(eye: eye, center: .zero, up: SIMD3(0, 1, 0))
        u.projection = .perspective(fovyRadians: fovy, aspect: aspect,
                                    near: max(0.01, d * 0.02), far: 200)
        u.time = Float(CACurrentMediaTime() - start)
        // Body, ring and halo all multiply coverage by this. At 0 the body renders
        // correctly and completely invisibly.
        u.orreryAlpha = 1
        u.exposure = exposure
        return u
    }
}
```

- [ ] **Step 3: Build**

```bash
cd app/Modules && swift build --build-tests 2>&1 | tail -30
```

Expected: no errors. A missing `.lookAt` / `.perspective` means checking `Math.swift`
for the real `simd_float4x4` static names — `TurntableCamera` uses them.

- [ ] **Step 4: Commit**

```bash
git add app/Modules/NewStarMapFeature/Sources/BodyPortraitRenderer.swift \
        app/Modules/NewStarMapFeature/Sources/BodyPortraitSubject.swift
git commit -m "feat(starmap): render one body through the production shaders"
```

---

### Task 8: The star pass

A star is an instanced billboard, not a body. It needs a one-element `StarInstance` buffer, a one-element relevance buffer, and five `Uniforms` fields the body pass never touches — each of which fails silently.

**Files:**
- Modify: `app/Modules/NewStarMapFeature/Sources/BodyPortraitRenderer.swift`
- Create: `app/Modules/NewStarMapFeature/Tests/StarPortraitTests.swift`

**Interfaces:**
- Consumes: `BodyPortrait.star(SystemStar)` from Task 7.
- Produces: `static func starInstance(for: SystemStar, radius: Float) -> StarInstance`.

- [ ] **Step 1: Write the failing test**

Create `app/Modules/NewStarMapFeature/Tests/StarPortraitTests.swift`:

```swift
import Testing
import UniverseModels
import simd
@testable import NewStarMapFeature

@Suite("Star portrait")
struct StarPortraitTests {
    @Test("a star's colour comes from its spectral class, matching the map")
    func colourFromClass() {
        let star = SystemStar(designation: "SOL", stellarClass: "G2V", temperatureK: 5772)
        let instance = BodyPortraitRenderer.starInstance(for: star, radius: 1)
        let expected = Star.color(
            forTemperature: StellarClass(spectralType: "G2V").representativeTemperature)
        #expect(SIMD3(instance.color.x, instance.color.y, instance.color.z) == expected)
    }

    @Test("the real temperature is deliberately not used")
    func temperatureIgnored() {
        let warm = SystemStar(designation: "A", stellarClass: "G2V", temperatureK: 5900)
        let cool = SystemStar(designation: "B", stellarClass: "G8V", temperatureK: 5300)
        #expect(BodyPortraitRenderer.starInstance(for: warm, radius: 1).color
                == BodyPortraitRenderer.starInstance(for: cool, radius: 1).color)
    }

    @Test("an unknown or missing class falls back to G, as the map does")
    func unknownClass() {
        let none = SystemStar(designation: "X")
        let g = SystemStar(designation: "Y", stellarClass: "G0V")
        #expect(BodyPortraitRenderer.starInstance(for: none, radius: 1).color
                == BodyPortraitRenderer.starInstance(for: g, radius: 1).color)
    }

    @Test("the instance carries the requested radius")
    func radius() {
        let star = SystemStar(designation: "SOL")
        #expect(BodyPortraitRenderer.starInstance(for: star, radius: 1).positionRadius.w == 1)
    }
}
```

- [ ] **Step 2: Run and confirm failure**

```bash
cd app/Modules && swift test --filter 'Star portrait' \
  --event-stream-output-path /tmp/starportrait.jsonl
```

Expected: failure — `starInstance` does not exist.

- [ ] **Step 3: Add the star path**

Add two stored properties (`starGlowPipeline`, `starDiscPipeline`) and build them in
`configure(view:)` beside the body ones:

```swift
        starGlowPipeline = pipeline("star_vertex", "star_fragment", additive)
        starDiscPipeline = pipeline("star_vertex", "star_body_fragment", alphaOver)
```

Add the instance builder and the encode:

```swift
    /// A star's rendered colour comes from its spectral-class STRING, exactly as
    /// `LiveStar` derives it. `SystemStar.temperatureK` is real but the map ignores it.
    static func starInstance(for star: SystemStar, radius: Float) -> StarInstance {
        let klass = StellarClass(spectralType: star.stellarClass ?? "G")
        return StarInstance(
            positionRadius: SIMD4(SIMD3<Float>.zero, radius),
            color: SIMD4(Star.color(forTemperature: klass.representativeTemperature), 1))
    }

    private func encodeStar(_ star: SystemStar, into enc: MTLRenderCommandEncoder,
                            uniforms u: inout Uniforms) {
        guard let starGlowPipeline, let starDiscPipeline, let bodyDepthState else { return }

        var instance = Self.starInstance(for: star, radius: bodyRadius)
        var relevance: Float = 1                  // 1.0 = fully relevant
        var relRange = SIMD2<Float>(0, 2)         // one draw, keep every fragment

        enc.setRenderPipelineState(starGlowPipeline)
        enc.setDepthStencilState(bodyDepthState)
        enc.setVertexBytes(&instance, length: MemoryLayout<StarInstance>.stride, index: 0)
        enc.setVertexBytes(&relevance, length: MemoryLayout<Float>.stride, index: 1)
        enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 2)
        enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 2)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: 1)

        enc.setRenderPipelineState(starDiscPipeline)
        enc.setVertexBytes(&instance, length: MemoryLayout<StarInstance>.stride, index: 0)
        enc.setVertexBytes(&relevance, length: MemoryLayout<Float>.stride, index: 1)
        enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 2)
        enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 2)
        enc.setFragmentBytes(&relRange, length: MemoryLayout<SIMD2<Float>>.stride, index: 3)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: 1)
    }
```

Route it in `encodeSubject`:

```swift
        case .star(let s):
            encodeStar(s, into: enc, uniforms: &u)
```

Give `uniforms(aspect:)` a star branch. Each of these is load-bearing:

```swift
        if case .star = subject {
            u.minAngularSize = 0.0015
            u.maxAngularSize = 0.05
            // Left at zero, `atmo` collapses to 0 and the star renders black.
            u.atmoNear = 40; u.atmoFar = 420; u.atmoFloor = 1
            u.lodStart = 0.004; u.lodFull = 0.018
            u.fieldDim = 1
            // Matching focusedStar to the instance with bodyReveal 0 lifts the angular
            // ceiling from 0.05 to 1e9; otherwise no distance yields a full disc.
            u.focusedStar = 0
            u.bodyReveal = 0
        }
```

and give the star its own camera distance. Disc diameter in pixels is `176.9 · α`
where `α = radius / dist`, so a 60% fill of a 128pt view is `dist = 2.3 · radius`:

```swift
    private func cameraDistance() -> Float {
        if case .star = subject { return bodyRadius * 2.3 }
        let fill: Float = 0.85
        return max(extent() * bodyRadius / (tan(fovy * 0.5) * fill), bodyRadius * 5.1)
    }
```

- [ ] **Step 4: Run the test**

```bash
cd app/Modules && swift test --filter 'Star portrait' \
  --event-stream-output-path /tmp/starportrait.jsonl
jq -r 'select(.payload.kind=="issueRecorded") | .payload' /tmp/starportrait.jsonl
```

Expected: no output.

- [ ] **Step 5: Commit**

```bash
git add app/Modules/NewStarMapFeature/Sources/BodyPortraitRenderer.swift \
        app/Modules/NewStarMapFeature/Tests/StarPortraitTests.swift
git commit -m "feat(starmap): render a star portrait through the star shaders"
```

---

### Task 9: The belt and region pass

A belt is an additive point ring. `OrreryGeometry.beltPoints` reads only `model.belts`, so a one-element `BeltModel` array drives it unchanged.

**Files:**
- Modify: `app/Modules/NewStarMapFeature/Sources/BodyPortraitRenderer.swift`
- Create: `app/Modules/NewStarMapFeature/Tests/BeltPortraitTests.swift`

**Interfaces:**
- Produces: `static func beltBand(for: Belt) -> BeltModel`, `static func regionBand(for: SpecialSite) -> BeltModel`.

- [ ] **Step 1: Write the failing test**

Create `app/Modules/NewStarMapFeature/Tests/BeltPortraitTests.swift`:

```swift
import Testing
import UniverseModels
@testable import NewStarMapFeature

@Suite("Belt portrait")
struct BeltPortraitTests {
    @Test("the band keeps the belt's true radial width")
    func widthPreserved() {
        let belt = Belt(designation: "SOL-BELT-1", innerRadiusAu: 2.1,
                        outerRadiusAu: 3.4, density: "moderate")
        let band = BodyPortraitRenderer.beltBand(for: belt)
        let expected = OrreryMapping.sceneRadius(au: 3.4) - OrreryMapping.sceneRadius(au: 2.1)
        #expect(abs((band.outerScene - band.innerScene) - expected) < 0.001)
    }

    @Test("a belt with no radii still gets a visible band")
    func noRadii() {
        let band = BodyPortraitRenderer.beltBand(for: Belt(designation: "X-BELT-1"))
        #expect(band.outerScene > band.innerScene)
    }

    @Test("density carries through, since it drives the point count")
    func density() {
        let belt = Belt(designation: "SOL-BELT-1", density: "dense")
        #expect(BodyPortraitRenderer.beltBand(for: belt).density == "dense")
    }

    @Test("a Kuiper or Oort region reads as a wide sparse band")
    func region() {
        for kind in [SpecialSiteKind.kuiper, .oort] {
            let site = SpecialSite(designation: "SOL-K", kind: kind)
            let band = BodyPortraitRenderer.regionBand(for: site)
            #expect(band.density == "sparse")
            #expect(band.outerScene - band.innerScene > 2)
        }
    }
}
```

- [ ] **Step 2: Run and confirm failure**

```bash
cd app/Modules && swift test --filter 'Belt portrait' \
  --event-stream-output-path /tmp/belt.jsonl
```

Expected: failure — `beltBand` does not exist.

- [ ] **Step 3: Add the belt path**

Add a `pointPipeline` stored property and build it in `configure(view:)`:

```swift
        pointPipeline = pipeline("orrery_point_vertex", "orrery_point_fragment", additive)
```

Add the band builders and the encode:

```swift
    /// A belt framed on its own. Absolute orbital radius means nothing without the
    /// star to measure it against, so only the band's true width carries over.
    static func beltBand(for belt: Belt) -> BeltModel {
        let inner = OrreryMapping.sceneRadius(au: belt.innerRadiusAu ?? 0)
        let outer = OrreryMapping.sceneRadius(au: belt.outerRadiusAu ?? 0)
        let width = max(outer - inner, 0.8)
        return BeltModel(designation: belt.designation, innerScene: 6,
                         outerScene: 6 + width, density: belt.density,
                         richness: belt.richness, hasSites: !belt.sites.isEmpty)
    }

    static func regionBand(for site: SpecialSite) -> BeltModel {
        BeltModel(designation: site.designation, innerScene: 5, outerScene: 9,
                  density: "sparse", richness: [:], hasSites: false)
    }

    private func encodePoints(_ band: BeltModel, into enc: MTLRenderCommandEncoder,
                              uniforms u: inout Uniforms) {
        guard let pointPipeline, let device, let readDepthState else { return }
        let model = SystemModel(belts: [band])
        let pts = OrreryGeometry.beltPoints(model: model, center: .zero, scale: 1)
        guard !pts.isEmpty,
              let buffer = device.makeBuffer(
                  bytes: pts,
                  length: MemoryLayout<AmbientVertex>.stride * pts.count,
                  options: .storageModeShared)
        else { return }
        enc.setRenderPipelineState(pointPipeline)
        enc.setDepthStencilState(readDepthState)
        enc.setVertexBuffer(buffer, offset: 0, index: 0)
        enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
        enc.drawPrimitives(type: .point, vertexStart: 0, vertexCount: pts.count)
    }
```

`SystemModel(belts:)` will only compile if `SystemModel`'s other fields are defaulted.
Check its real initializer in `OrreryModels.swift` and construct it with the full
signature if not — do **not** add a convenience init to `SystemModel` for this.

Route both cases in `encodeSubject`:

```swift
        case .belt(let b):   encodePoints(Self.beltBand(for: b), into: enc, uniforms: &u)
        case .region(let s): encodePoints(Self.regionBand(for: s), into: enc, uniforms: &u)
```

In `uniforms(aspect:)`, add the two fields the point vertex reads:

```swift
        switch subject {
        case .belt, .region:
            // The point vertex scales its local offset by reveal; at 0 the whole ring
            // collapses into its own centre.
            u.orreryReveal = 1
            u.orreryCenter = SIMD4(repeating: 0)
            u.orreryBuildCenter = SIMD4(repeating: 0)
        default:
            break
        }
```

Extend `extent()` so the band is framed:

```swift
        case .belt(let b):   return Float(Self.beltBand(for: b).outerScene)
        case .region(let s): return Float(Self.regionBand(for: s).outerScene)
```

A ring viewed near edge-on reads as a line, so give these two cases a steeper camera —
use `cameraElevation * 1.6` when the subject is `.belt` or `.region`.

- [ ] **Step 4: Run the test**

```bash
cd app/Modules && swift test --filter 'Belt portrait' \
  --event-stream-output-path /tmp/belt.jsonl
jq -r 'select(.payload.kind=="issueRecorded") | .payload' /tmp/belt.jsonl
```

Expected: no output.

- [ ] **Step 5: Commit**

```bash
git add app/Modules/NewStarMapFeature/Sources/BodyPortraitRenderer.swift \
        app/Modules/NewStarMapFeature/Tests/BeltPortraitTests.swift
git commit -m "feat(starmap): render a belt or region portrait as a point ring"
```

---

### Task 10: `BodyPortraitView` and the `MTKView` bridge

The public SwiftUI wrapper. Passive — no gesture handling at all — and paused when off screen.

**Files:**
- Create: `app/Modules/NewStarMapFeature/Sources/BodyPortraitView.swift`

**Interfaces:**
- Produces: `public struct BodyPortraitView: View { public init(_ subject: BodyPortrait) }`

- [ ] **Step 1: Write the view**

The view reads the same two `@Shared(.appStorage)` keys the map reads
(`NewStarMapFeature.swift:77-83`). Without this a body leans differently in the
inspector than it does in the map, which is exactly what this feature exists to avoid.

```swift
import MetalKit
import Sharing
import SwiftUI

/// A location's star, planet, moon, belt or region, drawn through the star map's own
/// shaders. Animates; ignores input.
public struct BodyPortraitView: View {
    private let subject: BodyPortrait
    @Environment(\.scenePhase) private var scenePhase
    @State private var visible = true

    @Shared(.appStorage(OrreryMapping.OrreryPlaneOptions.tiltCapKey))
    private var tiltCapDeg: Double = 90
    @Shared(.appStorage(OrreryMapping.OrreryPlaneOptions.decoupleKey))
    private var decoupleMoonPlane: Bool = false

    public init(_ subject: BodyPortrait) {
        self.subject = subject
    }

    public var body: some View {
        MetalBodyPortrait(
            subject: subject,
            options: .init(tiltCapDeg: tiltCapDeg, decoupleMoonPlane: decoupleMoonPlane),
            paused: !visible || scenePhase != .active
        )
        .background(.black)
        .onAppear { visible = true }
        .onDisappear { visible = false }
    }
}

private struct MetalBodyPortrait: NSViewRepresentable {
    let subject: BodyPortrait
    let options: OrreryMapping.OrreryPlaneOptions
    let paused: Bool

    func makeCoordinator() -> BodyPortraitRenderer { BodyPortraitRenderer() }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = MTLCreateSystemDefaultDevice()
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColorMake(0, 0, 0, 1)
        view.preferredFramesPerSecond = 60
        view.enableSetNeedsDisplay = false
        view.delegate = context.coordinator
        context.coordinator.subject = subject
        context.coordinator.options = options
        context.coordinator.configure(view: view)
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        context.coordinator.subject = subject
        context.coordinator.options = options
        view.isPaused = paused
    }
}
```

Check the real declared defaults for both keys at `NewStarMapFeature.swift:77-80` and
match them; a different default here silently disagrees with the map. If
`OrreryPlaneOptions` or its two key constants are `private`, widen them to `internal` —
not `public`; this view lives in the same module.

- [ ] **Step 2: Build**

```bash
cd app/Modules && swift build --build-tests 2>&1 | tail -20
```

Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add app/Modules/NewStarMapFeature/Sources/BodyPortraitView.swift
git commit -m "feat(starmap): expose the body portrait as a SwiftUI view"
```

---

### Task 11: Wire the portrait into the inspectors

Replace the placeholder squares with the real rendering, then verify the whole package.

**Files:**
- Modify: `app/Modules/Package.swift` (`LocationsFeature` target dependencies, `:486-498`)
- Modify: `app/Modules/LocationsFeature/Sources/LocationDetailView.swift`

**Interfaces:**
- Consumes: `BodyPortraitView`, `BodyPortrait` from Task 10; `PortraitFrame` from Task 2; `SiteGlyphPortrait` from Task 4; `LagrangeDiagram` from Task 3.

- [ ] **Step 1: Add the dependency**

In `app/Modules/Package.swift`, add `"NewStarMapFeature"` to the `LocationsFeature`
target's `dependencies` array (currently `GameModels`, `GameServices`, `TravelUI`,
`UI`, `UniverseModels`, plus the two products), keeping alphabetical order. There is no
cycle — `NewStarMapFeature` does not depend on `LocationsFeature`.

```bash
cd app/Modules && swift package resolve
```

Expected: resolves without error.

- [ ] **Step 2: Replace the placeholders**

Add `import NewStarMapFeature` to `LocationDetailView.swift`, then replace each
`PortraitFrame { Color.clear }`:

- `SystemInspector`: `portrait: system.star.map { AnyView(PortraitFrame { BodyPortraitView(.star($0)) }) },`
- `PlanetInspector`: `portrait: AnyView(PortraitFrame { BodyPortraitView(.planet(planet)) }),`
- `MoonInspector`: `portrait: AnyView(PortraitFrame { BodyPortraitView(.moon(moon)) }),`
- `BeltInspector`: `portrait: AnyView(PortraitFrame { BodyPortraitView(.belt(belt)) }),`

`ObjectInspector` routes by kind — add this computed property to it and pass
`portrait: portrait`:

```swift
    private var portrait: AnyView {
        switch site.kind {
        case .kuiper, .oort:
            AnyView(PortraitFrame { BodyPortraitView(.region(site)) })
        case .megastructure, .object, .lagrange:
            AnyView(PortraitFrame { SiteGlyphPortrait(site: site) })
        }
    }
```

`LagrangeInspector` keeps the `LagrangeDiagram` it got in Task 3, unchanged.

- [ ] **Step 3: Build and run the full suite**

```bash
cd app/Modules && swift build --build-tests 2>&1 | tail -20
cd app/Modules && swift test --event-stream-output-path /tmp/all.jsonl
jq -r 'select(.payload.kind=="issueRecorded") | .payload' /tmp/all.jsonl
```

Expected: build clean, no issues recorded. If the stream looks short, read the
`swift-test-event-stream` skill — one output path with many test processes truncates.

- [ ] **Step 4: Check the comment budget**

```bash
cd /Users/matt/Developer/replicant-macos && ./app/scripts/check-comments.sh \
  app/Modules/NewStarMapFeature/Sources/BodyPortraitRenderer.swift \
  app/Modules/NewStarMapFeature/Sources/BodyPortraitView.swift \
  app/Modules/NewStarMapFeature/Sources/BodyPortraitSubject.swift \
  app/Modules/NewStarMapFeature/Sources/BodyAppearance.swift \
  app/Modules/NewStarMapFeature/Sources/OrreryBodyRender.swift \
  app/Modules/LocationsFeature/Sources/BodyFacts.swift \
  app/Modules/LocationsFeature/Sources/LagrangeDiagram.swift \
  app/Modules/LocationsFeature/Sources/SiteGlyph.swift
```

Expected: exit 0. Exit 0 is a floor, not proof — also read each file header against the
10-line budget and each `///` against 3 lines by eye.

- [ ] **Step 5: Compile-check the app target**

```bash
cd /Users/matt/Developer/replicant-macos/app && \
  xcodebuild -project Replicould.xcodeproj -scheme Replicould \
  -destination 'platform=macOS' build 2>&1 | tail -20
```

Expected: `BUILD SUCCEEDED`. Running the app is blocked by the Keychain login wall from
a background job, so the rendering itself is verified by a human, by eye.

- [ ] **Step 6: Commit**

```bash
git add app/Modules/Package.swift \
        app/Modules/LocationsFeature/Sources/LocationDetailView.swift
git commit -m "feat(locations): show each location's own body in its detail header"
```
