# 05 — Directive theatre column and adoption

Type: task
Status: open
Blocked by: 04
Labels: multi-theatre

Give every directive row the theatre it serves, and adopt the rows that predate the column.

**Files:**
- Modify: `app/Modules/GameModels/Sources/Directive.swift`
- Modify: `app/Modules/GameDatabase/Sources/GameDatabase.swift` (append to `manifest`)
- Modify: `app/Modules/DirectiveEngine/Sources/Brain.swift` (adoption pass)
- Test: `app/Modules/DirectiveEngine/Tests/TheatreAdoptionTests.swift` (create)

**Interfaces:**
- Produces: `Directive.theatreDepot: String?` — the depot designation of the theatre this row serves. Nil means unadopted; the adoption pass fills it.
- Produces: `Brain.adoptTheatres(directives:view:) -> [(id: String, depot: String)]` — the rows to stamp and what to stamp them with. Pure; the caller writes.

**Why a depot designation rather than a component label:** components are recomputed every tick and their labels can move when a relay is planted. A depot is a location that only changes when the operator moves it, so a row stamped today still resolves tomorrow.

---

- [ ] **Step 1: Write the failing test**

Create `app/Modules/DirectiveEngine/Tests/TheatreAdoptionTests.swift`:

```swift
//
//  TheatreAdoptionTests.swift
//  Replicould — DirectiveEngine
//
//  Rows written before `theatreDepot` existed adopt the theatre that services
//  where they are working, and a row already stamped is left alone.
//

import Foundation
import GameModels
import Testing
import UniverseModels
@testable import DirectiveEngine

@Suite("Theatre adoption")
struct TheatreAdoptionTests {
    @Test("An unstamped row adopts the theatre servicing its origin")
    func adoptsFromOrigin() {
        let view = singleTheatreView()
        let row = directiveFixture(id: "D1", kind: .haulRun, originDesignation: "AINALRAM", theatreDepot: nil)

        let stamps = Brain.adoptTheatres(directives: [row], view: view)

        #expect(stamps.count == 1)
        #expect(stamps[0].id == "D1")
        #expect(stamps[0].depot == "AINALRAM-BELT-1")
    }

    @Test("An already-stamped row is left alone")
    func stampedRowUntouched() {
        let view = singleTheatreView()
        let row = directiveFixture(id: "D1", kind: .haulRun, originDesignation: "AINALRAM",
                                   theatreDepot: "GRAZ-1-L4")

        #expect(Brain.adoptTheatres(directives: [row], view: view).isEmpty)
    }

    @Test("With exactly one theatre, a row with no origin still adopts it")
    func singleTheatreAdoptsWithoutOrigin() {
        let view = singleTheatreView()
        let row = directiveFixture(id: "D1", kind: .haulRun, originDesignation: nil, theatreDepot: nil)

        #expect(Brain.adoptTheatres(directives: [row], view: view).map(\.depot) == ["AINALRAM-BELT-1"])
    }

    @Test("With several theatres and no origin, the row is left for the operator")
    func ambiguousRowNotGuessed() {
        let view = twoTheatreView()
        let row = directiveFixture(id: "D1", kind: .haulRun, originDesignation: nil, theatreDepot: nil)

        #expect(Brain.adoptTheatres(directives: [row], view: view).isEmpty)
    }
}
```

Write `singleTheatreView()`, `twoTheatreView()` and `directiveFixture(...)` as private helpers in this file, following the fixture idiom in `BrainSalvageTests.swift`. `twoTheatreView()` may be lifted from ticket 04's test file if you make it non-private there.

- [ ] **Step 2: Run the test and confirm it fails**

```bash
cd app/Modules && swift test --filter TheatreAdoptionTests --event-stream-output-path /tmp/t05.json
```

Expected: compile failure on `theatreDepot` and `Brain.adoptTheatres`.

- [ ] **Step 3: Add the column and its migration**

Add to `Directive` in `app/Modules/GameModels/Sources/Directive.swift`:

```swift
    /// The depot of the theatre this row serves. Nil on rows written before the
    /// column existed; `Brain.adoptTheatres` fills those in.
    public var theatreDepot: String?
```

Add the migration beside the existing `addRoamCentre` / `addFleetTag` ones, following their shape exactly:

```swift
    public static let addTheatreDepot = SchemaMigration("Add 'theatreDepot' to 'directives'") { db in
        try #sql(
            """
            ALTER TABLE "directives" ADD COLUMN "theatreDepot" TEXT
            """
        )
        .execute(db)
    }
```

Append `Directive.addTheatreDepot,` to the END of `GameDatabase.manifest`. Update `Directive.init` and every fixture that constructs one positionally.

- [ ] **Step 4: Implement adoption**

Add to `Brain` in `app/Modules/DirectiveEngine/Sources/Brain.swift`:

```swift
    /// Rows needing a `theatreDepot` and the depot to stamp on each. Pure — the
    /// caller writes. A row whose theatre cannot be decided is left for the
    /// operator rather than guessed: a wrong stamp sends a carrier to the wrong
    /// depot, and an absent one only declines to act.
    static func adoptTheatres(
        directives: [Directive], view: WorldView
    ) -> [(id: String, depot: String)] {
        let operational = view.theatres.filter(\.isOperational)
        return directives.compactMap { row in
            guard row.theatreDepot == nil else { return nil }
            if let origin = row.originDesignation,
               let theatre = view.theatre(servicing: origin) {
                return (row.id, theatre.depot)
            }
            guard operational.count == 1 else { return nil }
            return (row.id, operational[0].depot)
        }
    }
```

- [ ] **Step 5: Call it from the brain's tick**

Inside the brain's existing write transaction, before any goal runs, apply each stamp with an `UPDATE`. Every goal after this point may assume a live row it owns carries a depot.

- [ ] **Step 6: Regenerate the schema fixtures and run the suite**

```bash
cd app/Modules && RC_REGENERATE_SCHEMA_FIXTURE=1 swift test --filter GoldenSchemaTests --event-stream-output-path /tmp/t05-schema.json
cd app/Modules && swift test --event-stream-output-path /tmp/t05-all.json
```

Add the new identifier to `SchemaManifestTests`' frozen list. Expected: 4 new adoption tests pass, nothing else regresses.

- [ ] **Step 7: Commit**

```bash
cd /Users/matt/Developer/replicant-macos && ./app/scripts/check-comments.sh app/Modules/GameModels/Sources/Directive.swift app/Modules/DirectiveEngine/Sources/Brain.swift
git add -A
git commit -m "feat(theatre): directives carry the theatre they serve"
```
