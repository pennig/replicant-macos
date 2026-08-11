# 09 — Mission theatre resolution

Type: task
Status: open
Blocked by: 05
Labels: multi-theatre

Six missions ask the world for "the hub". Each must instead ask for the theatre named on its own directive row. Mechanically the same edit six times, which is why it is one ticket and one review gate.

**Files:**
- Modify: `app/Modules/DirectiveEngine/Sources/RelayRun.swift` (`:904`, `:925`)
- Modify: `app/Modules/DirectiveEngine/Sources/SalvageRun.swift` (`:216-219`)
- Modify: `app/Modules/DirectiveEngine/Sources/MineRun.swift` (`:287`)
- Modify: `app/Modules/DirectiveEngine/Sources/MineSitePlanner.swift` (`:42`)
- Modify: `app/Modules/DirectiveEngine/Sources/HaulRun.swift` (`:119`)
- Modify: `app/Modules/DirectiveEngine/Sources/RestockRun.swift`
- Test: `app/Modules/DirectiveEngine/Tests/MissionTheatreTests.swift` (create)

**Interfaces:**
- Consumes: `Directive.theatreDepot` (05), `WorldSnapshot`.
- Produces:
  ```swift
  extension WorldSnapshot {
      /// The depot of the theatre this directive serves, re-derived from the
      /// row rather than from world-wide state.
      func theatreDepot(for directive: Directive) -> String?
  }
  ```
  `RelayRun.hubLocation(in:)` is renamed `RelayRun.theatreDepot(in:for:)` and takes the directive. Every other site calls through it.

**Which resolver each site wants:**

| Site | Direction | Resolver |
| --- | --- | --- |
| `RelayRun` return leg | inward | the row's own depot |
| `RestockRun` target | inward | the row's own depot |
| `SalvageRun.hubSystem` | inward | the row's own depot, `SiteAssay.system(of:)` |
| `MineRun` | inward | the row's own depot |
| `HaulRun` delivery | inward | the row's own depot |
| `MineSitePlanner` ranking origin | **outward** | `view.theatre(nearest:)` — it ranks candidate belts nobody has reached yet |

`MineSitePlanner` is the one that differs, and getting it wrong is silent: an inward resolver there would refuse every unmeshed belt, which is every belt worth installing.

---

- [ ] **Step 1: Write the failing test**

Create `app/Modules/DirectiveEngine/Tests/MissionTheatreTests.swift`:

```swift
//
//  MissionTheatreTests.swift
//  Replicould — DirectiveEngine
//
//  Each mission resolves the theatre named on its OWN row. Two rows in two
//  theatres must not resolve to the same depot.
//

import Foundation
import GameModels
import Testing
import UniverseModels
@testable import DirectiveEngine

@Suite("Mission theatre resolution")
struct MissionTheatreTests {
    @Test("Two relay runs in two theatres return to their own depots")
    func relayReturnsToOwnDepot() {
        let snapshot = twoTheatreSnapshot()
        let home = directiveFixture(id: "D1", kind: .relayRun, theatreDepot: "AINALRAM-BELT-1")
        let pocket = directiveFixture(id: "D2", kind: .relayRun, theatreDepot: "DENEBED-BELT-1")

        #expect(RelayRun.theatreDepot(in: snapshot, for: home) == "AINALRAM-BELT-1")
        #expect(RelayRun.theatreDepot(in: snapshot, for: pocket) == "DENEBED-BELT-1")
    }

    @Test("A salvage run's hub system comes from its own row")
    func salvageSystemFromOwnRow() {
        let snapshot = twoTheatreSnapshot()
        let pocket = directiveFixture(id: "D2", kind: .salvageRun, theatreDepot: "DENEBED-BELT-1")

        #expect(SalvageRun.hubSystem(in: snapshot, for: pocket) == "DENEBED")
    }

    @Test("An unstamped row resolves to nothing rather than to the first theatre")
    func unstampedResolvesNil() {
        let snapshot = twoTheatreSnapshot()
        let orphan = directiveFixture(id: "D3", kind: .relayRun, theatreDepot: nil)

        #expect(RelayRun.theatreDepot(in: snapshot, for: orphan) == nil)
    }

    @Test("A row naming a depot that no longer exists resolves to nothing")
    func staleDepotResolvesNil() {
        let snapshot = twoTheatreSnapshot()
        let stale = directiveFixture(id: "D4", kind: .relayRun, theatreDepot: "GONE-BELT-1")

        #expect(RelayRun.theatreDepot(in: snapshot, for: stale) == nil)
    }

    @Test("Mine site ranking uses the NEAREST theatre, including for unmeshed belts")
    func mineRankingIsOutward() {
        let view = twoTheatreView()
        let ranked = MineSitePlanner.rank(view: view, candidates: ["DENEBED-BELT-2"])

        #expect(!ranked.isEmpty)
    }
}
```

Adapt `MineSitePlanner.rank`'s call shape to whatever the real signature is — read it before writing the test rather than assuming.

- [ ] **Step 2: Run the test and confirm it fails**

```bash
cd app/Modules && swift test --filter MissionTheatreTests --event-stream-output-path /tmp/t09.json
```

- [ ] **Step 3: Add the shared resolver**

```swift
extension WorldSnapshot {
    /// The depot this directive serves, resolved through the row rather than
    /// through world-wide state. nil when the row is unstamped or names a depot
    /// that no longer exists — both mean "do not act", never "pick another".
    func theatreDepot(for directive: Directive) -> String? {
        guard let depot = directive.theatreDepot else { return nil }
        return theatres.first { $0.depot == depot && $0.isOperational }?.depot
    }
}
```

`WorldSnapshot` needs the theatres too. It is the directive-scoped read (`WorldSnapshot.swift`); give it the same `theatres` array `WorldView` carries, populated from the same `TheatreRegistry` call.

- [ ] **Step 4: Migrate the six call sites**

Work through the table above. `RelayRun.hubLocation(in:)` becomes `RelayRun.theatreDepot(in:for:)` and every other inward site calls it. Delete the old function once `findReferences` shows no callers — with a warm index, confirmed by a clean `swift build --build-tests`.

The agreement test at `RelayReturnAndRestockTests.swift:266` pins that the mission's resolver and the brain's agree, warning that a disagreement flies a carrier to the wrong place. Generalise it to "for each directive, both resolvers name the same depot" rather than deleting it.

- [ ] **Step 5: Run the tests and confirm they pass**

```bash
cd app/Modules && swift test --filter MissionTheatreTests --event-stream-output-path /tmp/t09.json
cd app/Modules && swift test --event-stream-output-path /tmp/t09-all.json
```

- [ ] **Step 6: Commit**

```bash
cd /Users/matt/Developer/replicant-macos && ./app/scripts/check-comments.sh app/Modules/DirectiveEngine/Sources
git add app/Modules/DirectiveEngine
git commit -m "feat(theatre): missions resolve the theatre on their own row"
```
