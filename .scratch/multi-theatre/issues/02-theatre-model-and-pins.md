# 02 — Theatre model and pin storage

Type: task
Status: open
Blocked by: —
Labels: multi-theatre

The `Theatre` value type and the one piece of state that persists: an operator's pin. Recognition itself is ticket 03; this ticket only defines the vocabulary and the table.

**Files:**
- Create: `app/Modules/DirectiveEngine/Sources/Theatre.swift`
- Create: `app/Modules/GameModels/Sources/TheatrePin.swift`
- Modify: `app/Modules/GameDatabase/Sources/GameDatabase.swift` (append to `manifest`)
- Modify: `app/macOS/ReplicantApp.swift` (`registerSessionCleanup()`)
- Test: `app/Modules/DirectiveEngine/Tests/TheatreRecognitionTests.swift` (create; ticket 03 adds to it)

**Interfaces:**
- Produces:
  ```swift
  public struct Theatre: Equatable, Sendable, Identifiable {
      public var id: String { depot }
      public let depot: String
      public let system: String
      public let origin: Origin
      public let readiness: Readiness
      public let stock: Int
      public enum Origin: Equatable, Sendable { case pinned, systemHub(String), derived }
      public enum Readiness: Equatable, Sendable { case operational, claimed(missing: Set<Shortfall>) }
      public enum Shortfall: String, Equatable, Sendable, CaseIterable, Codable {
          case noPrintCapableDevice, noStock, offMesh
      }
      public var isOperational: Bool { readiness == .operational }
  }

  @Table public struct TheatrePin: Identifiable, Equatable, Sendable {
      @Column(primaryKey: true) public var location: String
      public var createdAt: Date
      public var id: String { location }
  }
  ```

---

- [ ] **Step 1: Write the failing test**

Create `app/Modules/DirectiveEngine/Tests/TheatreRecognitionTests.swift`:

```swift
//
//  TheatreRecognitionTests.swift
//  Replicould — DirectiveEngine
//
//  The `Theatre` vocabulary and, from ticket 03, the recognition rule that
//  produces it: pin beats hub claim beats derivation, per mesh component.
//

import Foundation
import GameModels
import Testing
import UniverseModels
@testable import DirectiveEngine

@Suite("Theatre vocabulary")
struct TheatreVocabularyTests {
    @Test("Identity is the depot location")
    func identityIsDepot() {
        let theatre = Theatre(
            depot: "AINALRAM-BELT-1", system: "AINALRAM",
            origin: .derived, readiness: .operational, stock: 12_000
        )
        #expect(theatre.id == "AINALRAM-BELT-1")
        #expect(theatre.system == "AINALRAM")
        #expect(theatre.isOperational)
    }

    @Test("A claimed theatre names every clause it fails, and is not operational")
    func claimedNamesShortfalls() {
        let theatre = Theatre(
            depot: "OMEROPE-BELT-1", system: "OMEROPE", origin: .pinned,
            readiness: .claimed(missing: [.noPrintCapableDevice, .noStock]),
            stock: 0
        )
        #expect(!theatre.isOperational)
        #expect(theatre.readiness == .claimed(missing: [.noPrintCapableDevice, .noStock]))
    }

    @Test("A hub-claimed theatre carries the claiming device code")
    func hubOriginCarriesCode() {
        let theatre = Theatre(
            depot: "DENEBED-BELT-1", system: "DENEBED",
            origin: .systemHub("SH8C2A1F"), readiness: .operational, stock: 500
        )
        #expect(theatre.origin == .systemHub("SH8C2A1F"))
    }
}
```

- [ ] **Step 2: Run the test and confirm it fails**

```bash
cd app/Modules && swift test --filter TheatreVocabularyTests --event-stream-output-path /tmp/t02.json
```

Expected: compile failure, `cannot find 'Theatre' in scope`.

- [ ] **Step 3: Create `Theatre.swift`**

```swift
//
//  Theatre.swift
//  Replicould — DirectiveEngine
//
//  A logistics theatre: a depot to explore outward from and accrete inward to.
//  Recognised from world state every tick, never placed — `TheatreRegistry`
//  holds the rule.
//

import Foundation

public struct Theatre: Equatable, Sendable, Identifiable {
    /// The depot location IS the identity: a stateless brain must name the same
    /// theatre every tick from world state alone.
    public var id: String { depot }
    /// Where stock and printing live, e.g. `AINALRAM-BELT-1`.
    public let depot: String
    public let system: String
    public let origin: Origin
    public let readiness: Readiness
    /// Total units at the depot.
    public let stock: Int

    public enum Origin: Equatable, Sendable {
        case pinned
        /// Carries the claiming `system_hub` device's code.
        case systemHub(String)
        case derived
    }

    public enum Readiness: Equatable, Sendable {
        case operational
        case claimed(missing: Set<Shortfall>)
    }

    /// What a `.claimed` theatre lacks — the clauses of the recognition
    /// predicate reported individually rather than collapsed to nil.
    public enum Shortfall: String, Equatable, Sendable, CaseIterable, Codable {
        case noPrintCapableDevice
        case noStock
        case offMesh
    }

    public var isOperational: Bool { readiness == .operational }

    public init(
        depot: String, system: String, origin: Origin,
        readiness: Readiness, stock: Int
    ) {
        self.depot = depot
        self.system = system
        self.origin = origin
        self.readiness = readiness
        self.stock = stock
    }
}
```

- [ ] **Step 4: Create `TheatrePin.swift`**

```swift
//
//  TheatrePin.swift
//  Replicould — GameModels
//
//  An operator's declaration that a location is a theatre depot. The only
//  theatre state that persists; every other origin is re-derived each tick.
//

import Foundation
import SQLiteData

@Table
public struct TheatrePin: Identifiable, Equatable, Sendable {
    @Column(primaryKey: true) public var location: String
    public var createdAt: Date

    public var id: String { location }

    public init(location: String, createdAt: Date) {
        self.location = location
        self.createdAt = createdAt
    }

    public static let createTheatrePins = SchemaMigration("Create 'theatrePins'") { db in
        try #sql(
            """
            CREATE TABLE "theatrePins" (
              "location" TEXT PRIMARY KEY NOT NULL,
              "createdAt" TEXT NOT NULL
            ) STRICT
            """
        )
        .execute(db)
    }
}
```

- [ ] **Step 5: Append the migration and register session cleanup**

Append to the END of `GameDatabase.manifest` in `app/Modules/GameDatabase/Sources/GameDatabase.swift`:

```swift
        TheatrePin.createTheatrePins,
```

`theatrePins` is account-scoped, so per the note above `manifest` it also needs a clear registered in `ReplicantApp.registerSessionCleanup()` — otherwise a second account on this machine inherits the first's pins. Follow the existing registrations in that function exactly.

- [ ] **Step 6: Update the schema fixtures**

```bash
cd app/Modules && RC_REGENERATE_SCHEMA_FIXTURE=1 swift test --filter GoldenSchemaTests --event-stream-output-path /tmp/t02-schema.json
```

Then add the new identifier to `SchemaManifestTests`' frozen list. Both are intended changes here; confirm the diff shows only the new table and the new identifier at the end.

- [ ] **Step 7: Run the tests and confirm they pass**

```bash
cd app/Modules && swift test --event-stream-output-path /tmp/t02-all.json
```

Expected: the three new vocabulary tests pass, `SchemaManifestTests` and `GoldenSchemaTests` pass against the regenerated fixture, and nothing else regresses.

- [ ] **Step 8: Check comments and commit**

```bash
cd /Users/matt/Developer/replicant-macos && ./app/scripts/check-comments.sh app/Modules/DirectiveEngine/Sources/Theatre.swift app/Modules/GameModels/Sources/TheatrePin.swift
git add -A
git commit -m "feat(theatre): Theatre value type and theatrePins table"
```
