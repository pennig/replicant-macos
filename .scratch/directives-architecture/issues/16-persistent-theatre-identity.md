# 16 — Persistent theatre identity (`theatres` table, sticky recognition)

Type: task
Status: open
Blocked by: 11
Labels: directives-architecture, stage-1

Spec S1.7 / D4. `Theatre.id` is the depot string; for `.systemHub`/`.derived` tiers that is "the richest stocked print-capable location in the system" (`TheatreRegistry.swift` was `:41-48, :64, :80`), which flips when stock shifts between two print locations — and then every `auto:x:<old-depot>` tag stops matching and every row stamped `theatreDepot: old` reads `theatreWentClaimed` → `.wait` forever. Only `.pinned` is stable today. The operator agreed theatre identity may persist: once a system's depot is recognised it stays that system's depot until re-pinned.

**Files:**
- Create: `app/Modules/GameModels/Sources/TheatreRecord.swift` (+ migration), `app/Modules/GameModels/Tests/TheatreRecordTests.swift`
- Modify: `GameDatabase.swift` (append), `TheatreRegistry.swift` (`recognise` takes `records: [TheatreRecord]`), `WorldView.swift` + `WorldSnapshot.swift` (read the table, pass it), `Brain.swift` (`persistTheatres` — one write site on the tick, after `report()`'s snapshot read), `LogisticsFeature/Sources/EstablishTheatreSheet.swift` (a pin writes/overwrites the record too)
- Test: `TheatreRecognitionTests` (extend), `Brain*Tests` (one: a newly recognised theatre is persisted after a tick)

**Interfaces:**
- Produces:
  ```swift
  @Table public struct TheatreRecord: Identifiable, Equatable, Sendable {
      @Column(primaryKey: true) public var depot: String    // == Theatre.id
      public var system: String
      public var origin: String        // "pinned" | "systemHub" | "derived" — Theatre.Origin.rawValue
      public var establishedAt: Date
  }
  // TheatreRegistry
  public static func recognise(devices:, pins:, records: [TheatreRecord], meshSystems:, components:, stockByLocation:) -> [Theatre]
  ```
  Rule inside `recognise`: for the `.systemHub` and `.derived` tiers, if `records` has a row whose `system` matches, use ITS `depot` (even if another location in the system is now richer) provided that depot still holds a print-capable device; if it no longer does, fall through to today's derivation and the brain will persist the new depot. Pins always win and `EstablishTheatreSheet` upserts the record with `origin: "pinned"`.
- Consumes: 11.

---

- [ ] **Step 1: Failing tests**

`TheatreRecognitionTests`: two print locations in one system, A richer than B, record says B → theatre depot is B; record says B but B has no printer any more → depot is A. `TheatreRecordTests`: migration + round trip. Brain test: tick over a world with a derived theatre and no records → one `TheatreRecord` row exists afterwards with `origin == "derived"`.

- [ ] **Step 2: Implement; migration + golden schema; commit**

`feat(theatres): persisted theatre identity — recognition is sticky per system`. Memory note update: `theatre-recognition-model.md` gains one line saying identity is now persisted and where.
