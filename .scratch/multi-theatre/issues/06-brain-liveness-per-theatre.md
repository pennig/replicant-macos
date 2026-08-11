# 06 — Brain liveness per theatre

Type: task
Status: open
Blocked by: 04, 05
Labels: multi-theatre

`Brain.ensureOne` keeps one row of each kind alive across the whole account. Scope it to (kind, theatre) so a second theatre gets its own salvage, haul and relay runs.

**Files:**
- Modify: `app/Modules/DirectiveEngine/Sources/Brain.swift` (`ensureOne` at `:230`, and its callers)
- Test: `app/Modules/DirectiveEngine/Tests/TheatreLivenessTests.swift` (create)

**Interfaces:**
- Consumes: `Directive.theatreDepot` (05), `WorldView.theatres` (04).
- Produces: `Brain.ensureOne(_:theatre:matching:snapshot:database:build:)` — same function with a required `theatre: Theatre` parameter. Liveness is judged over rows carrying that theatre's depot.

`ensureOne` already takes a `matching:` predicate and already re-checks liveness inside the write transaction (`Brain.swift:252`). The theatre clause must be added in **both** places, or two theatres racing in one tick can each insert.

The device-reservation guard at `Brain.swift:258` stays account-wide and must not be narrowed to a theatre. A device has one location and one owner; scoping that guard per theatre would let two theatres commit the same hull.

---

- [ ] **Step 1: Write the failing test**

Create `app/Modules/DirectiveEngine/Tests/TheatreLivenessTests.swift`:

```swift
//
//  TheatreLivenessTests.swift
//  Replicould — DirectiveEngine
//
//  Liveness is per (kind, theatre): a live haul run in one theatre must not
//  suppress the other's, and the device reservation guard stays account-wide.
//

import Dependencies
import Foundation
import GameDatabase
import GameModels
import SQLiteData
import Testing
import UniverseModels
@testable import DirectiveEngine

@Suite("Theatre liveness")
struct TheatreLivenessTests {
    @Test("A live row in one theatre does not suppress the other's")
    func perTheatreLiveness() async throws {
        let database = try livenessDatabase()
        let home = Theatre(depot: "AINALRAM-BELT-1", system: "AINALRAM", origin: .derived,
                           readiness: .operational, stock: 40_000)
        let pocket = Theatre(depot: "DENEBED-BELT-1", system: "DENEBED", origin: .pinned,
                             readiness: .operational, stock: 900)

        try await database.write { db in
            try Directive.insert {
                directiveFixture(id: "D-HOME", kind: .haulRun, theatreDepot: home.depot)
            }.execute(db)
        }

        let brain = Brain()
        await brain.ensureOne(.haulRun, theatre: pocket, snapshot: snapshot(database),
                              database: database) {
            directiveFixture(id: "D-POCKET", kind: .haulRun, deviceCode: "T2",
                             theatreDepot: pocket.depot)
        }

        let rows = try await database.read { try Directive.all.fetchAll($0) }
        #expect(Set(rows.map(\.id)) == ["D-HOME", "D-POCKET"])
    }

    @Test("A live row in the SAME theatre still suppresses a second")
    func sameTheatreStillSingleton() async throws {
        let database = try livenessDatabase()
        let home = Theatre(depot: "AINALRAM-BELT-1", system: "AINALRAM", origin: .derived,
                           readiness: .operational, stock: 40_000)

        try await database.write { db in
            try Directive.insert {
                directiveFixture(id: "D-HOME", kind: .haulRun, theatreDepot: home.depot)
            }.execute(db)
        }

        let brain = Brain()
        await brain.ensureOne(.haulRun, theatre: home, snapshot: snapshot(database),
                              database: database) {
            directiveFixture(id: "D-SECOND", kind: .haulRun, deviceCode: "T2",
                             theatreDepot: home.depot)
        }

        let rows = try await database.read { try Directive.all.fetchAll($0) }
        #expect(rows.map(\.id) == ["D-HOME"])
    }

    @Test("A device already committed elsewhere is refused even in a fresh theatre")
    func reservationGuardStaysAccountWide() async throws {
        let database = try livenessDatabase()
        let pocket = Theatre(depot: "DENEBED-BELT-1", system: "DENEBED", origin: .pinned,
                             readiness: .operational, stock: 900)

        try await database.write { db in
            try Directive.insert {
                directiveFixture(id: "D-HOME", kind: .salvageRun, deviceCode: "T1",
                                 theatreDepot: "AINALRAM-BELT-1")
            }.execute(db)
        }

        let brain = Brain()
        await brain.ensureOne(.haulRun, theatre: pocket, snapshot: snapshot(database),
                              database: database) {
            directiveFixture(id: "D-POCKET", kind: .haulRun, deviceCode: "T1",
                             theatreDepot: pocket.depot)
        }

        let rows = try await database.read { try Directive.all.fetchAll($0) }
        #expect(rows.map(\.id) == ["D-HOME"])
    }
}
```

Build `livenessDatabase()`, `snapshot(_:)` and `directiveFixture(...)` following the end-to-end database idiom already in `BrainSalvageTests.swift` — that file drives `ensureOne` against a real database and is the pattern to copy.

- [ ] **Step 2: Run the test and confirm it fails**

```bash
cd app/Modules && swift test --filter TheatreLivenessTests --event-stream-output-path /tmp/t06.json
```

Expected: compile failure on the unknown `theatre:` argument.

- [ ] **Step 3: Add the theatre clause to both liveness checks**

In `Brain.ensureOne` (`Brain.swift:230`), add the parameter and fold it into both predicates:

```swift
    func ensureOne(
        _ kind: DirectiveKind,
        theatre: Theatre,
        matching: @escaping @Sendable (Directive) -> Bool = { _ in true },
        snapshot: Snapshot,
        database: any DatabaseWriter,
        build: () -> Directive?
    ) async {
        guard !Task.isCancelled else { return }
        let owns = { (row: Directive) in
            row.kind == kind && Self.owningStatuses.contains(row.status)
                && row.theatreDepot == theatre.depot && matching(row)
        }
        let live = snapshot.directives.contains(where: owns)
        guard !live else { return }
        …
                let live = rows.contains(where: owns)
```

Leave the `reservedDevices` guard below exactly as it is.

- [ ] **Step 4: Update every caller to loop over theatres**

Each `ensureOne` caller in `Brain` (salvage, haul, relay, restock, mine) becomes a loop over `view.theatres.filter(\.isOperational)`, passing the theatre through and stamping `theatreDepot` on the row it builds. A goal that cannot resolve a theatre does not run.

Use Swift-LSP `findReferences` on `ensureOne` to enumerate the callers rather than grepping, and confirm the index is warm first (`swift build --build-tests`, then `./scripts/link-index-store.sh`).

- [ ] **Step 5: Run the tests and confirm they pass**

```bash
cd app/Modules && swift test --filter TheatreLivenessTests --event-stream-output-path /tmp/t06.json
cd app/Modules && swift test --event-stream-output-path /tmp/t06-all.json
```

Expected: 3 new tests pass. Existing brain tests must also pass — with a single synthesised theatre they exercise the same path.

- [ ] **Step 6: Commit**

```bash
cd /Users/matt/Developer/replicant-macos && ./app/scripts/check-comments.sh app/Modules/DirectiveEngine/Sources/Brain.swift
git add app/Modules/DirectiveEngine
git commit -m "feat(theatre): brain liveness is per (kind, theatre)"
```
