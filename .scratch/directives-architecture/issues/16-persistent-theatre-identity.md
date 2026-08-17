# 16 — Persistent theatre identity (`theatres` table, sticky recognition)

Type: task
Status: resolved
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

- [x] **Step 1: Failing tests**

`TheatreRecognitionTests`: two print locations in one system, A richer than B, record says B → theatre depot is B; record says B but B has no printer any more → depot is A. `TheatreRecordTests`: migration + round trip. Brain test: tick over a world with a derived theatre and no records → one `TheatreRecord` row exists afterwards with `origin == "derived"`.

- [x] **Step 2: Implement; migration + golden schema; commit**

`feat(theatres): persisted theatre identity — recognition is sticky per system`. Memory note update: `theatre-recognition-model.md` gains one line saying identity is now persisted and where.

## Comments

Resolved in `e4d6f64` (table + sticky rule) and `f403c43` (review fixes).

Eight targets green: DirectiveEngine 1498, GameServices 285, GameSync 66, GameModels 129,
DirectivesFeature 270, DevicesFeature 153, GameDatabase 20, LogisticsFeature 31. From-scratch build
clean, and `xcodebuild -scheme Replicould` succeeds (the app target gained a logout clear for the new
table).

**Schema.** The migration appends last, after ticket 15's; no shipped migration was edited, renamed or
reordered. The regenerated golden fixture diff is one hunk, seven added lines, **zero deletions** — the
`CREATE TABLE "theatres"` block and nothing else. It lands last in the file correctly under BINARY
collation (`theatrePins` < `theatres`).

**`Theatre.Origin` needed a `recordValue`** rather than `rawValue`: `.systemHub(String)` carries a
payload, so the enum is not `RawRepresentable`. It produces exactly the three strings the ticket names.

**The proviso tests print-capability and deliberately not stock**, using the same `printLocations` set
that `readiness(of:)` uses, so there is one definition rather than two. That clause initially had no
test — every fixture gave the record's depot non-zero stock, so adding a stock guard left the whole
suite green. `aDryPersistedDepotKeepsTheIdentity` now pins it.

**The consequence of that clause, for the operator.** A sticky depot that runs dry reads
`.claimed(missing: [.noStock])` where the old rule would have hopped to a stocked sibling in the same
system. `readiness` is honest about it; **the run is not.** With a second theatre operational,
`theatreWentClaimed` sends seven mission guards to `.wait` — `HaulRun` ×2, `RelayRun`, `EventRun` ×2,
`MineRun`, `SalvageRun` — with no stall, no `attentionReason` and no operator surface. Nothing can
restock it either: the brain allocates only over operational theatres, and the haul run that would
refill the depot is itself one of the waiters. Recovery needs the operator to re-pin or deliver by hand.

Net this is still an improvement — the old rule fired the same silent `.wait` on any stock *shuffle*,
which is the bug class this ticket exists to retire, while the new one fires only on a depot going fully
dry. But it is a new failure mode in one configuration, and it is on the punch list beside the parked
`theatre-readiness-starves-richer-depots` decision.

**A pin race was found in self-review and closed.** `report()` reads the snapshot before
`persistTheatres` writes, so a pin landing in between would have had its `origin: "pinned"` row deleted
and replaced by a derived one. The write now re-reads `TheatrePin` inside its own transaction. The
sheet writes pin and record in one transaction, so checking the cheaper table is an equivalent proxy.

The `.derived` loop is per mesh component while the rule is per system, so two persisted systems in one
component are resolved by `.min()` on designation. The spec does not define that case; it is on the
punch list.
