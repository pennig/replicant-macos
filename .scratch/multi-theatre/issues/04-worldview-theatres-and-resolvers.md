# 04 — WorldView theatres and resolvers

Type: task
Status: open
Blocked by: 03
Labels: multi-theatre

Put theatres into the brain's one-tick world read and give callers the two resolvers. `hubLocation` survives this ticket unchanged as a compatibility shim so the existing ~335 tests keep passing; ticket 10 retires it.

**Files:**
- Modify: `app/Modules/DirectiveEngine/Sources/WorldView.swift`
- Test: `app/Modules/DirectiveEngine/Tests/TheatreRecognitionTests.swift`

**Interfaces:**
- Consumes: `TheatreRegistry.recognise(...)` (03), `MeshGraph.components(of:)` (01), `TheatrePin` (02).
- Produces:
  ```swift
  extension WorldView {
      public var theatres: [Theatre] { get }             // stored
      public var components: [String: String] { get }    // stored, system -> component label
      /// Inward: same mesh component, then nearest. Operational only.
      public func theatre(servicing system: String) -> Theatre?
      /// Outward: nearest by straight-line distance, no component filter. Operational only.
      public func theatre(nearest system: String) -> Theatre?
  }
  ```

**Migration strategy — read this before writing code.** Many existing tests build a `WorldView` by passing `hubLocation:` directly. Keep that initialiser parameter and keep `hubLocation` a stored property. When `theatres:` is not supplied but `hubLocation:` is, the initialiser synthesises a single operational theatre at that depot. Existing fixtures then exercise the new resolvers for free, and no test file needs touching in this ticket.

---

- [ ] **Step 1: Write the failing tests**

Append to `app/Modules/DirectiveEngine/Tests/TheatreRecognitionTests.swift`:

```swift
private let ainalram = Position(x: -11.25, y: -37.09, z: -7.68)
private let graz = Position(x: -14.0, y: -30.0, z: -5.0)
private let omerope = Position(x: -291.87, y: -125.98, z: 106.32)
private let denebed = Position(x: -292.55, y: -125.42, z: 113.41)

private func twoTheatreView() -> WorldView {
    WorldView(
        devices: [:],
        starPositions: ["AINALRAM": ainalram, "GRAZ": graz, "OMEROPE": omerope, "DENEBED": denebed],
        meshSystems: ["AINALRAM", "GRAZ", "OMEROPE", "DENEBED"],
        salvageUnits: [:],
        eventSystems: [],
        hubLocation: nil,
        theatres: [
            Theatre(depot: "AINALRAM-BELT-1", system: "AINALRAM", origin: .derived,
                    readiness: .operational, stock: 40_000),
            Theatre(depot: "DENEBED-BELT-1", system: "DENEBED", origin: .pinned,
                    readiness: .operational, stock: 900),
        ],
        components: ["AINALRAM": "AINALRAM", "GRAZ": "AINALRAM",
                     "OMEROPE": "DENEBED", "DENEBED": "DENEBED"],
        now: Date(timeIntervalSince1970: 5_000)
    )
}

@Suite("Theatre resolvers")
struct TheatreResolverTests {
    @Test("Inward resolution refuses a theatre in another component")
    func inwardRespectsComponent() {
        let view = twoTheatreView()
        #expect(view.theatre(servicing: "GRAZ")?.depot == "AINALRAM-BELT-1")
        #expect(view.theatre(servicing: "OMEROPE")?.depot == "DENEBED-BELT-1")
    }

    @Test("Inward resolution returns nil for a system in no serviced component")
    func inwardNilOffComponent() {
        let view = twoTheatreView()
        #expect(view.theatre(servicing: "NOWHERE") == nil)
    }

    @Test("Outward resolution ignores components and takes the nearest")
    func outwardIgnoresComponents() {
        let view = twoTheatreView()
        #expect(view.theatre(nearest: "OMEROPE")?.depot == "DENEBED-BELT-1")
        #expect(view.theatre(nearest: "GRAZ")?.depot == "AINALRAM-BELT-1")
    }

    @Test("Two theatres in ONE component both pass the filter; distance decides")
    func sharedComponentResolvesByDistance() {
        let view = WorldView(
            devices: [:],
            starPositions: ["AINALRAM": ainalram, "GRAZ": graz],
            meshSystems: ["AINALRAM", "GRAZ"],
            salvageUnits: [:], eventSystems: [], hubLocation: nil,
            theatres: [
                Theatre(depot: "AINALRAM-BELT-1", system: "AINALRAM", origin: .derived,
                        readiness: .operational, stock: 40_000),
                Theatre(depot: "GRAZ-1-L4", system: "GRAZ", origin: .pinned,
                        readiness: .operational, stock: 100),
            ],
            components: ["AINALRAM": "AINALRAM", "GRAZ": "AINALRAM"],
            now: Date(timeIntervalSince1970: 5_000)
        )

        #expect(view.theatre(servicing: "GRAZ")?.depot == "GRAZ-1-L4")
        #expect(view.theatre(servicing: "AINALRAM")?.depot == "AINALRAM-BELT-1")
    }

    @Test("A claimed theatre is never returned by either resolver")
    func claimedIsInvisible() {
        let view = WorldView(
            devices: [:], starPositions: ["OMEROPE": omerope],
            meshSystems: [], salvageUnits: [:], eventSystems: [], hubLocation: nil,
            theatres: [
                Theatre(depot: "OMEROPE-BELT-1", system: "OMEROPE", origin: .pinned,
                        readiness: .claimed(missing: [.offMesh]), stock: 900),
            ],
            components: ["OMEROPE": "OMEROPE"],
            now: Date(timeIntervalSince1970: 5_000)
        )

        #expect(view.theatre(servicing: "OMEROPE") == nil)
        #expect(view.theatre(nearest: "OMEROPE") == nil)
    }

    @Test("Passing only hubLocation synthesises one operational theatre")
    func legacyInitStillWorks() {
        let view = WorldView(
            devices: [:], starPositions: ["AINALRAM": ainalram],
            meshSystems: ["AINALRAM"], salvageUnits: [:], eventSystems: [],
            hubLocation: "AINALRAM-BELT-1",
            now: Date(timeIntervalSince1970: 5_000)
        )

        #expect(view.theatres.map(\.depot) == ["AINALRAM-BELT-1"])
        #expect(view.theatre(servicing: "AINALRAM")?.depot == "AINALRAM-BELT-1")
    }
}
```

- [ ] **Step 2: Run the tests and confirm they fail**

```bash
cd app/Modules && swift test --filter TheatreResolverTests --event-stream-output-path /tmp/t04.json
```

Expected: compile failure on the unknown `theatres:` and `components:` initialiser labels.

- [ ] **Step 3: Add the stored properties and the back-compatible initialiser**

In `app/Modules/DirectiveEngine/Sources/WorldView.swift`, add beside the existing stored properties:

```swift
    /// Every recognised theatre this tick, ordered by depot. Replaces the single
    /// `hubLocation`, which remains only until ticket 10 retires it.
    public let theatres: [Theatre]
    /// System → mesh-component label, from `MeshGraph.components(of:)`.
    public let components: [String: String]
```

Extend the initialiser with `theatres: [Theatre]? = nil` and `components: [String: String] = [:]`, placed after `hubLocation:` so existing call sites are unaffected, and synthesise when absent:

```swift
        self.components = components
        self.theatres = theatres ?? hubLocation.map {
            [Theatre(depot: $0, system: SiteAssay.system(of: $0), origin: .derived,
                     readiness: .operational, stock: 0)]
        } ?? []
```

- [ ] **Step 4: Add the resolvers**

Append to `WorldView`:

```swift
    /// The theatre that can actually service `system`: same mesh component,
    /// then nearest. nil when nothing operational reaches it.
    public func theatre(servicing system: String) -> Theatre? {
        let component = components[system]
        return nearestTheatre(to: system) { components[$0.system] != nil && components[$0.system] == component }
    }

    /// The nearest operational theatre by straight-line distance, meshed or not.
    public func theatre(nearest system: String) -> Theatre? {
        nearestTheatre(to: system) { _ in true }
    }

    /// One ranking for both resolvers — they differ only by `admits`, and
    /// keeping them one function is what stops them drifting apart. Ordered by
    /// (distance, depot) so the result is total and stable across ticks.
    private func nearestTheatre(
        to system: String, admits: (Theatre) -> Bool
    ) -> Theatre? {
        guard let origin = starPositions[system] else { return nil }
        return theatres
            .filter { $0.isOperational && admits($0) }
            .compactMap { theatre -> (Double, Theatre)? in
                guard let position = starPositions[theatre.system] else { return nil }
                return (origin.distance(to: position), theatre)
            }
            .min { lhs, rhs in
                lhs.0 == rhs.0 ? lhs.1.depot < rhs.1.depot : lhs.0 < rhs.0
            }?.1
    }
```

If `Position` has no `distance(to:)`, add one to `UniverseModels` rather than inlining the arithmetic here — `SurveyRoamPlanner` and `SurveyTargetSuggestions` both compute it by hand today, so a shared helper is the correct home.

- [ ] **Step 5: Build the theatres inside `read(from:now:)`**

In `WorldView.read(from:now:)`, in the same transaction as everything else, after `mesh` and `hubStock` are computed and before the `WorldView(...)` construction:

```swift
        let pins = try TheatrePin.all.fetchAll(db)
        let graph = MeshGraph(positions: starPositions)
        let componentLabels = graph.components(of: mesh)
        let theatres = TheatreRegistry.recognise(
            devices: allDevices, pins: pins, meshSystems: mesh,
            components: componentLabels, stockByLocation: hubStock
        )
```

Pass both into the initialiser. **`hubStock` is presently computed only for print locations** (`WorldView.swift:151`) — confirm it still covers every candidate depot a pin can name, and widen that query if a pinned location outside the print set would otherwise read as zero stock.

- [ ] **Step 6: Run the tests and confirm they pass**

```bash
cd app/Modules && swift test --filter "TheatreResolverTests" --event-stream-output-path /tmp/t04.json
cd app/Modules && swift test --event-stream-output-path /tmp/t04-all.json
```

Expected: 6 new resolver tests pass and the full suite is unchanged from before this ticket — that is the whole point of keeping `hubLocation`.

- [ ] **Step 7: Check comments and commit**

```bash
cd /Users/matt/Developer/replicant-macos && ./app/scripts/check-comments.sh app/Modules/DirectiveEngine/Sources/WorldView.swift
git add app/Modules/DirectiveEngine
git commit -m "feat(theatre): WorldView carries theatres and the two resolvers"
```
