# 08 — Prune per theatre

Type: task
Status: open
Blocked by: 04
Labels: multi-theatre

`PrunePredicate.analyse` roots one path-union at the single hub's system. A relay in another component lies on no path from that root and reads as reclaimable — the whole-mesh-reclaim failure the file's own comment forbids. Root one union per theatre instead.

**Files:**
- Modify: `app/Modules/DirectiveEngine/Sources/PrunePredicate.swift` (`:99-130`, `:170-215`)
- Test: `app/Modules/DirectiveEngine/Tests/PrunePerTheatreTests.swift` (create)

**Interfaces:**
- Consumes: `WorldView.theatres`, `WorldView.components` (04).
- Produces: no signature change to `analyse`. Its behaviour changes; its shape does not.

**The rule.** Partition the relays by the component their system belongs to. For each component:
- No operational theatre in it → **pin every relay in it** and record `.noAnchor`. An unanchored component cannot be judged, and unjudged means pinned.
- Otherwise → root a union at that theatre's system over the targets whose systems fall in that component, exactly as today, and judge only that component's relays against it.

A relay is reclaimable only when its own component's union says so. Nothing is ever judged against another component's anchor.

Keep the census-coverage precondition global and unchanged (`PrunePredicate.swift:107-121`). It already fails closed, and per-component variants of it were explicitly rejected in the existing comment for reasons that still hold.

---

- [ ] **Step 1: Write the failing test**

Create `app/Modules/DirectiveEngine/Tests/PrunePerTheatreTests.swift`:

```swift
//
//  PrunePerTheatreTests.swift
//  Replicould — DirectiveEngine
//
//  Each component is judged against its own theatre. A relay must never be
//  offered up because a DIFFERENT component's anchor cannot reach it.
//

import Foundation
import GameModels
import Testing
import UniverseModels
@testable import DirectiveEngine

@Suite("Prune per theatre")
struct PrunePerTheatreTests {
    @Test("A disconnected component's relays are never reclaimable from the home anchor")
    func otherComponentIsNotReclaimable() {
        let view = twoComponentWorld()
        let analysis = PrunePredicate.analyse(view: view)

        let pocketRelays = ["REL-OMEROPE", "REL-DENEBED"]
        #expect(analysis.reclaimable.allSatisfy { !pocketRelays.contains($0.deviceCode) })
    }

    @Test("A component holding no operational theatre pins all its relays and declines")
    func unanchoredComponentDeclines() {
        let view = pocketWithoutTheatre()
        let analysis = PrunePredicate.analyse(view: view)

        #expect(analysis.pinned.contains("REL-OMEROPE"))
        #expect(analysis.reclaimable.isEmpty)
    }

    @Test("Within an anchored component a genuinely useless relay is still reclaimable")
    func usefulnessStillJudgedLocally() {
        let view = homeWithSpurRelay()
        let analysis = PrunePredicate.analyse(view: view)

        #expect(analysis.reclaimable.map(\.deviceCode) == ["REL-SPUR"])
    }

    @Test("Two theatres in ONE component judge against the union of both roots' paths")
    func sharedComponentUsesBothAnchors() {
        let view = twoTheatresOneComponent()
        let analysis = PrunePredicate.analyse(view: view)

        // A relay on the path from either theatre to live value stays pinned.
        #expect(analysis.pinned.contains("REL-BETWEEN"))
    }
}
```

Build the four world fixtures as private helpers in this file, modelled on the existing prune fixtures. Use the real geometry where it matters: `AINALRAM` at `(-11.25, -37.09, -7.68)` and `OMEROPE` at `(-291.87, -125.98, 106.32)` are 316 ly apart and cannot be joined at any hop range the game offers.

- [ ] **Step 2: Run the test and confirm it fails**

```bash
cd app/Modules && swift test --filter PrunePerTheatreTests --event-stream-output-path /tmp/t08.json
```

Expected: `otherComponentIsNotReclaimable` fails — the pocket relays come back reclaimable. That failure is the defect this ticket exists to fix; confirm you see it before writing the fix.

- [ ] **Step 3: Rewrite the anchoring**

Replace the single-anchor guard at `PrunePredicate.swift:99-103` and the single `pathUnion` call at `:123`:

```swift
        let anchors = view.theatres.filter(\.isOperational)
        guard !anchors.isEmpty else { return decline(.noAnchor) }

        let targets = servedSystems(in: view)
        // Census precondition stays global and unchanged — see the comment above.
        …

        var unionByComponent: [String: Set<String>] = [:]
        for anchor in anchors {
            guard let component = view.components[anchor.system] else { continue }
            let localTargets = targets.filter { view.components[$0] == component }
            var union = graph.pathUnion(to: localTargets, from: [anchor.system], free: view.meshSystems)
            union.insert(anchor.system)
            unionByComponent[component, default: []].formUnion(union)
        }
```

Then, in the per-relay loop, judge each relay against its own component's union and pin anything whose component has none:

```swift
            guard let component = view.components[system],
                  let union = unionByComponent[component]
            else {
                pinned.insert(relay.deviceCode)
                continue
            }
            if union.contains(system) { pinned.insert(relay.deviceCode) } else { … }
```

Note that unioning across several anchors in one component is the safe direction: more sources make paths cheaper and would shrink a single union, but taking the **union of separately-rooted searches** only ever adds pinned systems.

- [ ] **Step 4: Run the tests and confirm they pass**

```bash
cd app/Modules && swift test --filter PrunePerTheatreTests --event-stream-output-path /tmp/t08.json
cd app/Modules && swift test --event-stream-output-path /tmp/t08-all.json
```

Expected: 4 new tests pass and every existing prune test still passes. The existing whole-mesh-reclaim guard test is the one to watch — if it now fails, the fix has broken the property it was protecting.

- [ ] **Step 5: Commit**

```bash
cd /Users/matt/Developer/replicant-macos && ./app/scripts/check-comments.sh app/Modules/DirectiveEngine/Sources/PrunePredicate.swift
git add app/Modules/DirectiveEngine
git commit -m "fix(theatre): prune roots one union per theatre, judged per component"
```
