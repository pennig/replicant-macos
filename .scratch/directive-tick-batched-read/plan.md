# One Batched World Read Per Directive Tick — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cut idle app CPU from ~53% of a core to ~18% by reading the world once per 5s tick instead of once per running directive per tick.

**Architecture:** Split `WorldSnapshot` along the line its data already follows — 13 global fields into `WorldCore`, 5 directive-scoped fields into `DirectiveSlice`. One `WorldTick.read` opens a single transaction per tick producing the core, a slice per running directive, and the brain's `WorldView`. Executors stay one-`Task`-per-directive and keep applying their own writes; only where the snapshot comes from changes.

**Tech Stack:** Swift 6, SQLiteData / StructuredQueries, Swift Testing, GRDB `DatabasePool`.

**Spec:** `.scratch/directive-tick-batched-read/spec.md`

## Global Constraints

- `WorldSnapshot`'s public shape does not change. No fields added, removed, renamed, or retyped. 25 source files and 56 test files read it; they must not be edited.
- `WorldView`'s public shape does not change, for the same reason.
- `WorldSnapshot.read(from:now:directive:)` keeps its signature and stays public. It is reimplemented, never deleted.
- Every existing test must pass unchanged at the end of every task. A task that requires editing an existing test assertion has changed behaviour and must stop and report instead.
- Swift Testing only: `@Test`, `#expect`, `try GameDatabase.bootstrap()`. No XCTest.
- Read test results via the event stream, not console text — use the repo's `swift-test-event-stream` skill. `swift test` console output is not a stable interface.
- Fixtures must pin excluded rows explicitly, not only included ones, and every exclusion must be proved by mutation (delete the filter, watch the test fail).
- Commit after every task. Never open a PR; land on the local branch.
- `Operation.kind` is a `String` column. Compare against `OperationKind.print.rawValue`, never a bare literal.

## File Structure

| File | Responsibility |
|---|---|
| `app/Modules/DirectiveEngine/Sources/WorldSnapshot.swift` | The snapshot value + its composing init. Loses the read body. |
| `app/Modules/DirectiveEngine/Sources/WorldCore.swift` *(new)* | The 13 global fields and their single read. |
| `app/Modules/DirectiveEngine/Sources/DirectiveSlice.swift` *(new)* | The 5 scoped fields, `read` and batched `readAll`. |
| `app/Modules/DirectiveEngine/Sources/WorldTick.swift` *(new)* | One transaction → `(core, slices, view, running)`. |
| `app/Modules/DirectiveEngine/Sources/WorldView.swift` | Keeps its shape; gains an init from `WorldCore`. |
| `app/Modules/DirectiveEngine/Sources/DirectiveEngine.swift` | Three loops collapse into one tick loop. |
| `app/Modules/DirectiveEngine/Sources/DirectiveExecutor.swift` | `recordCompletedOps` loses `alreadyLogged`. |
| `app/Modules/DirectiveEngine/Tests/WorldCoreTests.swift` *(new)* | Core equivalence + one-transaction proof. |
| `app/Modules/DirectiveEngine/Tests/DirectiveSliceTests.swift` *(new)* | Narrowing exclusions, batched == individual. |
| `app/Modules/DirectiveEngine/Tests/WorldTickTests.swift` *(new)* | Tick loop behaviour, paused-directive delta. |

## Task Order

Tasks 1–2 narrow the two unbounded queries and are independent of the restructure; they land ~9% of app CPU on their own and de-risk the rest. Tasks 3–7 build the seam without changing any behaviour. Task 8 is the only one that rewires control flow. Task 9 measures.

---

### Task 1: Narrow `auditLog` to unmatched dispatches

`auditLog` fetches 7,954 rows per directive per tick so `recordCompletedOps` can find the 4 that matter. Push the matching into SQL.

**Files:**
- Modify: `app/Modules/DirectiveEngine/Sources/WorldSnapshot.swift:36-39` (doc comment), `:264-282` (the query)
- Modify: `app/Modules/DirectiveEngine/Sources/DirectiveExecutor.swift:299-311`
- Test: `app/Modules/DirectiveEngine/Tests/DirectiveSliceTests.swift` *(new file)*

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `WorldSnapshot.auditLog` now contains ONLY `.commandDispatched` entries with no matching `.opCompleted`, ascending by `occurredAt`. Task 2 reads `auditLog` to build its audit operation set.

- [ ] **Step 1: Write the failing test**

Create `app/Modules/DirectiveEngine/Tests/DirectiveSliceTests.swift`:

```swift
//
//  DirectiveSliceTests.swift
//  Replicould — DirectiveEngine
//
//  The directive-scoped half of a world read: what each query must EXCLUDE is
//  pinned here as explicitly as what it includes, because a fixture that only
//  lists kept rows cannot fail when a filter is deleted.
//

import Foundation
import GameDatabase
import GameModels
import SQLiteData
import Testing
import UniverseModels
@testable import DirectiveEngine

private typealias Operation = GameModels.Operation

private func dispatchEntry(_ id: String, op: String, at: Double) -> DirectiveLogEntry {
    DirectiveLogEntry(
        id: id, directiveID: "D1", deviceCode: nil, kind: .commandDispatched,
        summary: "dispatched \(op)", step: nil, operationID: op, eventID: nil,
        occurredAt: Date(timeIntervalSince1970: at)
    )
}

private func completedEntry(_ id: String, op: String, at: Double) -> DirectiveLogEntry {
    DirectiveLogEntry(
        id: id, directiveID: "D1", deviceCode: nil, kind: .opCompleted,
        summary: "closed \(op)", step: nil, operationID: op, eventID: nil,
        occurredAt: Date(timeIntervalSince1970: at)
    )
}

private func sliceDirective() -> Directive {
    Directive(
        id: "D1", kind: .haulRun, status: .running, deviceCode: "V1",
        targets: ["SOL"], currentTarget: "SOL"
    )
}

@Suite struct AuditLogNarrowing {
    /// A dispatch that already has its `.opCompleted` counterpart is settled
    /// business — re-reading it every tick forever is what made this query
    /// 7,954 rows. Only the UNMATCHED dispatch survives.
    @Test func excludesDispatchesThatAlreadyHaveACompletion() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try DirectiveLogEntry.insert { dispatchEntry("L1", op: "OP-SETTLED", at: 1) }.execute(db)
            try DirectiveLogEntry.insert { completedEntry("L2", op: "OP-SETTLED", at: 2) }.execute(db)
            try DirectiveLogEntry.insert { dispatchEntry("L3", op: "OP-PENDING", at: 3) }.execute(db)
        }
        let world = try await WorldSnapshot.read(
            from: database, now: Date(timeIntervalSince1970: 100), directive: sliceDirective()
        )
        #expect(world.auditLog.map(\.id) == ["L3"])
    }

    /// `.opCompleted` rows are the matcher, never the payload: none may appear
    /// in the result, or `recordCompletedOps` would iterate its own output.
    @Test func excludesCompletionEntriesThemselves() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try DirectiveLogEntry.insert { completedEntry("L1", op: "OP-A", at: 1) }.execute(db)
        }
        let world = try await WorldSnapshot.read(
            from: database, now: Date(timeIntervalSince1970: 100), directive: sliceDirective()
        )
        #expect(world.auditLog.isEmpty)
    }

    /// Another directive's unmatched dispatch is not ours to close.
    @Test func excludesOtherDirectivesDispatches() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try DirectiveLogEntry.insert {
                DirectiveLogEntry(
                    id: "L1", directiveID: "D2", deviceCode: nil, kind: .commandDispatched,
                    summary: "theirs", step: nil, operationID: "OP-THEIRS", eventID: nil,
                    occurredAt: Date(timeIntervalSince1970: 1)
                )
            }.execute(db)
            try DirectiveLogEntry.insert { dispatchEntry("L2", op: "OP-OURS", at: 2) }.execute(db)
        }
        let world = try await WorldSnapshot.read(
            from: database, now: Date(timeIntervalSince1970: 100), directive: sliceDirective()
        )
        #expect(world.auditLog.map(\.id) == ["L2"])
    }

    /// A dispatch naming no operation cannot be matched or closed.
    @Test func excludesDispatchesNamingNoOperation() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try DirectiveLogEntry.insert {
                DirectiveLogEntry(
                    id: "L1", directiveID: "D1", deviceCode: nil, kind: .commandDispatched,
                    summary: "no op", step: nil, operationID: nil, eventID: nil,
                    occurredAt: Date(timeIntervalSince1970: 1)
                )
            }.execute(db)
        }
        let world = try await WorldSnapshot.read(
            from: database, now: Date(timeIntervalSince1970: 100), directive: sliceDirective()
        )
        #expect(world.auditLog.isEmpty)
    }
}
```

If `Directive`'s memberwise init in this repo needs more arguments, copy the exact `directive()` helper from `WorldSnapshotTests.swift:55` rather than inventing one.

- [ ] **Step 2: Run the tests to verify they fail**

```bash
swift test --package-path app --filter AuditLogNarrowing \
  --event-stream-output-path /tmp/audit-red.jsonl
```

Expected: `excludesDispatchesThatAlreadyHaveACompletion` and `excludesCompletionEntriesThemselves` FAIL — today's query returns both `.opCompleted` rows and settled dispatches. The other two already pass; that is fine and expected.

- [ ] **Step 3: Replace the query**

In `WorldSnapshot.swift`, replace the `auditLog` fetch:

```swift
            // Only dispatches with no `.opCompleted` counterpart — the rows the
            // audit pass can still act on. Matching in SQL rather than fetching
            // the whole history and diffing it in Swift: settled dispatches are
            // the overwhelming majority (7,954 rows to find 4) and re-reading
            // them every tick is pure waste. Unbounded only in the pending
            // sense, which is bounded by how many ops are actually in flight.
            let auditLog = try DirectiveLogEntry
                .where { entry in
                    entry.directiveID.eq(directiveID)
                        && entry.kind.eq(DirectiveLogKind.commandDispatched)
                        && entry.operationID.isNot(nil)
                        && (entry.operationID ?? "").notIn(
                            DirectiveLogEntry
                                .where {
                                    $0.directiveID.eq(directiveID)
                                        && $0.kind.eq(DirectiveLogKind.opCompleted)
                                        && $0.operationID.isNot(nil)
                                }
                                .select { $0.operationID ?? "" }
                        )
                }
                .order { $0.occurredAt }
                .fetchAll(db)
```

The `isNot(nil)` guard inside the subquery is load-bearing: SQL `NOT IN` over a set containing NULL matches nothing at all.

- [ ] **Step 4: Update the property's doc comment**

Replace `WorldSnapshot.swift:36-39` with:

```swift
    /// Every `.commandDispatched` entry that NAMES an operation and has no
    /// `.opCompleted` counterpart yet — the audit pass's worklist, matched in
    /// SQL. Unlike `log`, never windowed by count: an op dispatched long before
    /// `log`'s cutoff still resolves here. Bounded by ops in flight, not by
    /// directive age.
```

- [ ] **Step 5: Simplify `recordCompletedOps`**

In `DirectiveExecutor.swift`, delete the `alreadyLogged` set and its guard — SQL now does that filtering:

```swift
        var entries: [DirectiveLogEntry] = []
        for dispatch in world.auditLog where dispatch.kind == .commandDispatched {
            guard let operationID = dispatch.operationID,
                  let operation = world.dispatchedOperations[operationID],
                  operation.status.isTerminal
            else { continue }
```

Delete the `let alreadyLogged = Set(...)` binding above it and the `!alreadyLogged.contains(operationID),` line. Update the comment at `:299-300` that says "Reads `auditLog`, not the windowed `log`" to note the matching now happens in SQL. Keep the `where dispatch.kind == .commandDispatched` filter: it costs nothing and stops this loop silently changing meaning if the query widens later.

- [ ] **Step 6: Run the full DirectiveEngine suite**

```bash
swift test --package-path app --filter DirectiveEngine \
  --event-stream-output-path /tmp/audit-green.jsonl
```

Expected: all pass, including every pre-existing test. If any pre-existing assertion needs editing, STOP — that means behaviour changed and the design says it must not.

- [ ] **Step 7: Prove the exclusions by mutation**

Delete the `.notIn(...)` clause, re-run `AuditLogNarrowing`, confirm `excludesDispatchesThatAlreadyHaveACompletion` fails. Restore it. Then delete the `entry.kind.eq(DirectiveLogKind.commandDispatched)` clause, confirm `excludesCompletionEntriesThemselves` fails. Restore it. A filter no test can kill is not defended.

- [ ] **Step 8: Commit**

```bash
git add app/Modules/DirectiveEngine/Sources/WorldSnapshot.swift app/Modules/DirectiveEngine/Sources/DirectiveExecutor.swift app/Modules/DirectiveEngine/Tests/DirectiveSliceTests.swift
git commit -m "perf(directives): match the audit worklist in SQL, not in Swift"
```

---

### Task 2: Narrow `dispatchedOperations` to the kinds anyone reads

`dispatchedOperations` fetches every operation a directive has ever dispatched — 1424 rows for the oldest running directive, 3,867 across all 22, re-decoded with their JSON `detail` every 5s. Every consumer outside the audit pass filters on `kind == print` or `kind == travel`.

**Files:**
- Modify: `app/Modules/DirectiveEngine/Sources/WorldSnapshot.swift:40-48` (doc comment), `:276-296` (the query)
- Test: `app/Modules/DirectiveEngine/Tests/DirectiveSliceTests.swift`

**Interfaces:**
- Consumes: `auditLog` from Task 1 — already narrowed to unmatched dispatches, and read before this query so its operation ids are available in Swift.
- Produces: `WorldSnapshot.dispatchedOperations` — still `[String: GameModels.Operation]`, now the union of (a) ops of kind `print`/`travel` this directive dispatched or owns, and (b) the ops named by `auditLog`, any kind. Type and field name unchanged.

- [ ] **Step 1: Write the failing test**

Append to `DirectiveSliceTests.swift`:

```swift
@Suite struct DispatchedOperationsNarrowing {
    private func operation(_ id: String, kind: OperationKind, status: OperationStatus) -> Operation {
        Operation(
            id: id, entityCode: "V1", kind: kind.rawValue, status: status,
            source: OperationSource.optimistic,
            startedAt: Date(timeIntervalSince1970: 0), completesAt: nil,
            lastConfirmedAt: Date(timeIntervalSince1970: 0), detail: .object([:]),
            directiveID: "D1"
        )
    }

    /// The kinds every mission consumer actually filters for survive; the rest
    /// are dead weight that grows for the life of the directive.
    @Test func keepsPrintAndTravelAndDropsOtherKinds() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Operation.insert { operation("OP-P", kind: .print, status: .completed) }.execute(db)
            try Operation.insert { operation("OP-T", kind: .travel, status: .completed) }.execute(db)
            try Operation.insert { operation("OP-L", kind: OperationKind(rawValue: "launch"), status: .completed) }.execute(db)
            try Operation.insert { operation("OP-R", kind: OperationKind(rawValue: "recall"), status: .completed) }.execute(db)
        }
        let world = try await WorldSnapshot.read(
            from: database, now: Date(timeIntervalSince1970: 100), directive: sliceDirective()
        )
        #expect(world.dispatchedOperations.keys.sorted() == ["OP-P", "OP-T"])
    }

    /// A print keeps every status, `.superseded` included: `printDiagnosis`
    /// distinguishes "superseded" from "never dispatched", and
    /// `printedRelayCode` reads the COMPLETED print to name the clone hours
    /// after it closed. The kind filter must never become a status filter.
    @Test func keepsPrintsOfEveryStatus() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Operation.insert { operation("OP-DONE", kind: .print, status: .completed) }.execute(db)
            try Operation.insert { operation("OP-OPEN", kind: .print, status: .active) }.execute(db)
            try Operation.insert { operation("OP-SUP", kind: .print, status: .superseded) }.execute(db)
        }
        let world = try await WorldSnapshot.read(
            from: database, now: Date(timeIntervalSince1970: 100), directive: sliceDirective()
        )
        #expect(world.dispatchedOperations.keys.sorted() == ["OP-DONE", "OP-OPEN", "OP-SUP"])
    }

    /// The whole reason the two sets stay separate: a terminal `launch` is
    /// dropped by the kind filter, but the audit pass still has to close it, so
    /// the ops named by an unmatched dispatch come back regardless of kind.
    @Test func keepsAnyKindNamedByAnUnmatchedDispatch() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Operation.insert { operation("OP-L", kind: OperationKind(rawValue: "launch"), status: .completed) }.execute(db)
            try DirectiveLogEntry.insert { dispatchEntry("L1", op: "OP-L", at: 1) }.execute(db)
        }
        let world = try await WorldSnapshot.read(
            from: database, now: Date(timeIntervalSince1970: 100), directive: sliceDirective()
        )
        #expect(world.dispatchedOperations["OP-L"] != nil)
    }

    /// …and once it is closed, it stops coming back.
    @Test func dropsAnAuditedKindOnceItsCompletionIsLogged() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Operation.insert { operation("OP-L", kind: OperationKind(rawValue: "launch"), status: .completed) }.execute(db)
            try DirectiveLogEntry.insert { dispatchEntry("L1", op: "OP-L", at: 1) }.execute(db)
            try DirectiveLogEntry.insert { completedEntry("L2", op: "OP-L", at: 2) }.execute(db)
        }
        let world = try await WorldSnapshot.read(
            from: database, now: Date(timeIntervalSince1970: 100), directive: sliceDirective()
        )
        #expect(world.dispatchedOperations["OP-L"] == nil)
    }
}
```

`OperationStatus.superseded` must exist; if the case is spelled differently, read `app/Modules/GameModels/Sources/Operation.swift` and use the real name rather than adding one.

- [ ] **Step 2: Run the tests to verify they fail**

```bash
swift test --package-path app --filter DispatchedOperationsNarrowing \
  --event-stream-output-path /tmp/dispatch-red.jsonl
```

Expected: `keepsPrintAndTravelAndDropsOtherKinds` and `dropsAnAuditedKindOnceItsCompletionIsLogged` FAIL — today every kind is returned unconditionally.

- [ ] **Step 3: Add the kind constant**

Near `logWindow` in `WorldSnapshot.swift`:

```swift
    /// The operation kinds `dispatchedOperations` carries for the mission
    /// machines. Every consumer outside the audit pass filters to exactly one
    /// of these (`EventRun`, `RelayRun`, `Steps/PrintJob` on `print`;
    /// `Steps/TravelTo` on `travel`), so anything else is fetched, decoded and
    /// discarded. Widen this only alongside a consumer that reads the new kind.
    static let dispatchedKinds = [OperationKind.print.rawValue, OperationKind.travel.rawValue]
```

- [ ] **Step 4: Replace the query**

Replace the `dispatched` binding. It must sit AFTER the `auditLog` binding from Task 1, since it reads it:

```swift
            // The ids this directive is on record as dispatching. One query, so
            // the ids never cross into Swift to come back as a host-parameter
            // list.
            let dispatchedIDs = DirectiveLogEntry
                .where {
                    $0.directiveID.eq(directiveID)
                        && $0.kind.eq(DirectiveLogKind.commandDispatched)
                        && $0.operationID.isNot(nil)
                }
                .select { $0.operationID ?? "" }

            // The mission half: only the kinds a machine reads. The owner
            // column is the source of truth; the log is a fallback for rows
            // written before it existed.
            let missionOps = try GameModels.Operation
                .where { operation in
                    (operation.directiveID.eq(directiveID) || operation.id.in(dispatchedIDs))
                        && operation.kind.in(Self.dispatchedKinds)
                }
                .fetchAll(db)

            // The audit half: whatever `auditLog` still needs closed, of ANY
            // kind. Kept out of the kind filter deliberately — filtering it
            // would silently stop `recordCompletedOps` writing `.opCompleted`
            // for `launch`, `recall`, `deploy` and every other kind. This is
            // the single reason the two halves cannot be merged into one query.
            let auditOperationIDs = auditLog.compactMap(\.operationID)
            let auditOps = auditOperationIDs.isEmpty
                ? []
                : try GameModels.Operation.where { $0.id.in(auditOperationIDs) }.fetchAll(db)

            let dispatched = Dictionary(
                (missionOps + auditOps).map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
```

- [ ] **Step 5: Rewrite the property's doc comment**

Replace `WorldSnapshot.swift:40-48`. The existing comment names only the audit pass as the reason closed rows are kept, which has been out of date since `printedRelayCode` and `lastTravelCompletion` started reading it:

```swift
    /// The operations this directive dispatched, by operation id — **including
    /// closed ones**. Two sets in one lookup:
    ///
    /// - kinds any mission machine reads (`dispatchedKinds`), every status:
    ///   `RelayRun.printedRelayCode` names its clone from the COMPLETED print
    ///   hours after it closed, `printDiagnosis` needs `.superseded` to tell a
    ///   superseded print from one never dispatched, and
    ///   `Steps/TravelTo.lastTravelCompletion` post-dates a device row against
    ///   its last completed travel;
    /// - whatever `auditLog` still has open, of ANY kind, so the audit pass can
    ///   notice a dispatched op reaching a terminal state and write its
    ///   `.opCompleted` entry.
    ///
    /// Never fold these into `openOperations`: a mission asking "is this device
    /// busy?" reads that lookup, and a closed op inside it reads as in-flight.
```

- [ ] **Step 6: Run the full DirectiveEngine suite**

```bash
swift test --package-path app --filter DirectiveEngine \
  --event-stream-output-path /tmp/dispatch-green.jsonl
```

Expected: all pass. Pay attention to `RelayRun` and `TravelTo` tests — they are the consumers most likely to notice a wrong filter.

- [ ] **Step 7: Prove the exclusions by mutation**

Delete `&& operation.kind.in(Self.dispatchedKinds)`, confirm `keepsPrintAndTravelAndDropsOtherKinds` fails. Restore. Delete the `auditOps` union, confirm `keepsAnyKindNamedByAnUnmatchedDispatch` fails. Restore.

- [ ] **Step 8: Commit**

```bash
git add app/Modules/DirectiveEngine/Sources/WorldSnapshot.swift app/Modules/DirectiveEngine/Tests/DirectiveSliceTests.swift
git commit -m "perf(directives): fetch only the dispatched op kinds a machine reads"
```

---

### Task 3: Extract `WorldCore`

Pure refactor, no behaviour change. Move the 13 global fields and their fetches into their own type so the next tasks have a seam to read once per tick.

**Files:**
- Create: `app/Modules/DirectiveEngine/Sources/WorldCore.swift`
- Modify: `app/Modules/DirectiveEngine/Sources/WorldSnapshot.swift` (read body)
- Test: `app/Modules/DirectiveEngine/Tests/WorldCoreTests.swift` *(new)*

**Interfaces:**
- Consumes: nothing from Tasks 1–2 (those touched only scoped queries).
- Produces:
  - `struct WorldCore: Equatable, Sendable` with exactly these 13 `public let` properties, types copied verbatim from `WorldSnapshot`: `devices: [String: Device]`, `openOperations: [String: GameModels.Operation]`, `queuedOperations: [String: [GameModels.Operation]]`, `footprints: [String: LocationFootprint]`, `starPositions: [String: Position]`, `components: [String: String]`, `blueprintBills: [String: ResourceCost]`, `blueprintComponents: [String: [String: Int]]`, `blueprintPrintTimes: [String: Int]`, `theatres: [Theatre]`, `locationEvents: [String: LocationEvent]`, `replicantHostDevices: Set<String>`, `peers: [Directive]`.
  - `static func WorldCore.read(_ db: Database) throws -> WorldCore` — synchronous, takes an open `Database`, does no transaction management of its own.

- [ ] **Step 1: Write the failing test**

Create `app/Modules/DirectiveEngine/Tests/WorldCoreTests.swift`:

```swift
//
//  WorldCoreTests.swift
//  Replicould — DirectiveEngine
//
//  The global half of a world read — the 13 fields identical for every
//  directive, and therefore the half worth reading once per tick.
//

import Foundation
import GameDatabase
import GameModels
import SQLiteData
import Testing
import UniverseModels
@testable import DirectiveEngine

@Suite struct WorldCoreEquivalence {
    /// The extraction is a refactor: a core read inside the same transaction
    /// must produce exactly the fields the composed snapshot exposes. This is
    /// the test that makes Tasks 4-8 safe to attempt.
    @Test func matchesTheSnapshotItComposes() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Device.insert {
                Device(
                    deviceCode: "V1", deviceType: "transport_hauler", replicantCode: "R1",
                    status: "idle", location: "SOL-3", locationName: nil,
                    operationalCapacity: 100, queueSize: 0, stowedInDeviceCode: nil,
                    controllerDeviceCode: nil, attachedToDeviceCode: nil,
                    createdAt: Date(timeIntervalSince1970: 0), availableCommands: [],
                    features: [], tags: [], detail: .object([:]),
                    updatedAt: Date(timeIntervalSince1970: 0),
                    firstSeenAt: Date(timeIntervalSince1970: 0)
                )
            }.execute(db)
            try LocationFootprint.insert {
                LocationFootprint(
                    location: "SOL-3", devices: 1, resources: 500, resourceSites: 0,
                    locationEvents: 0, replicants: 0,
                    fetchedAt: Date(timeIntervalSince1970: 0)
                )
            }.execute(db)
        }

        let core = try await database.read { db in try WorldCore.read(db) }
        let world = try await WorldSnapshot.read(
            from: database, now: Date(timeIntervalSince1970: 100),
            directive: Directive(
                id: "D1", kind: .haulRun, status: .running, deviceCode: "V1",
                targets: ["SOL"], currentTarget: "SOL"
            )
        )

        #expect(core.devices == world.devices)
        #expect(core.footprints == world.footprints)
        #expect(core.openOperations == world.openOperations)
        #expect(core.queuedOperations == world.queuedOperations)
        #expect(core.starPositions == world.starPositions)
        #expect(core.components == world.components)
        #expect(core.blueprintBills == world.blueprintBills)
        #expect(core.blueprintComponents == world.blueprintComponents)
        #expect(core.blueprintPrintTimes == world.blueprintPrintTimes)
        #expect(core.theatres == world.theatres)
        #expect(core.locationEvents == world.locationEvents)
        #expect(core.replicantHostDevices == world.replicantHostDevices)
        #expect(core.peers == world.peers)
    }
}
```

Use the real memberwise inits — read `LocationFootprint` and `Device` in `app/Modules/GameModels/Sources/` and copy the argument lists rather than trusting the ones above if they differ.

- [ ] **Step 2: Run the test to verify it fails**

```bash
swift test --package-path app --filter WorldCoreEquivalence \
  --event-stream-output-path /tmp/core-red.jsonl
```

Expected: FAIL to compile — `WorldCore` does not exist.

- [ ] **Step 3: Create `WorldCore`**

Create `WorldCore.swift`. Move the global fetches out of `WorldSnapshot.read`'s closure **verbatim** — `devices`, `operations`, `footprints`, `starRows`/`starPositions`, `mesh`, `components`, `blueprintRows` and its three dictionaries, `pins`/`theatres`, `eventRows`/`locationEvents`, `replicantHostDevices`, `peers`. Do not re-order them, do not "improve" them, do not change a query. The file header should say what the type is for:

```swift
//
//  WorldCore.swift
//  Replicould — DirectiveEngine
//
//  The half of a world read that does not depend on which directive is asking:
//  13 fields, identical for all of them, and therefore read ONCE per tick
//  rather than once per directive. Splitting this out is what took the engine
//  from 22 whole-table reads every five seconds to one.
//
```

`theatres` depends on `devices`, `mesh`, `components` and `footprints`, so its construction stays where it is relative to them.

- [ ] **Step 4: Recompose `WorldSnapshot.read`**

`WorldSnapshot.read` keeps its signature. Its closure becomes: `let core = try WorldCore.read(db)`, then the five scoped fetches unchanged, then the existing `WorldSnapshot(...)` init drawing global values from `core`. The `wanted`/`decoded` computation reads `core.devices` where it used to read the local `devices`.

- [ ] **Step 5: Run the full suite**

```bash
swift test --package-path app --filter DirectiveEngine \
  --event-stream-output-path /tmp/core-green.jsonl
```

Expected: all pass, including every pre-existing `WorldSnapshotTests` case. This task changes no behaviour, so any failure is a transcription error in the move — diff the moved code against git history rather than debugging forward.

- [ ] **Step 6: Commit**

```bash
git add app/Modules/DirectiveEngine/Sources/WorldCore.swift app/Modules/DirectiveEngine/Sources/WorldSnapshot.swift app/Modules/DirectiveEngine/Tests/WorldCoreTests.swift
git commit -m "refactor(directives): split the global half of a world read into WorldCore"
```

---

### Task 4: Extract `DirectiveSlice`

The mirror of Task 3 for the five scoped fields. Still no behaviour change.

**Files:**
- Create: `app/Modules/DirectiveEngine/Sources/DirectiveSlice.swift`
- Modify: `app/Modules/DirectiveEngine/Sources/WorldSnapshot.swift`
- Test: `app/Modules/DirectiveEngine/Tests/DirectiveSliceTests.swift` (existing from Task 1)

**Interfaces:**
- Consumes: `WorldCore` from Task 3.
- Produces:
  - `struct DirectiveSlice: Equatable, Sendable` with `log: [DirectiveLogEntry]`, `auditLog: [DirectiveLogEntry]`, `dispatchedOperations: [String: GameModels.Operation]`, `systems: [String: StarSystem]`, `siteAssays: [String: [String: Double]]`.
  - `static func DirectiveSlice.read(_ db: Database, core: WorldCore, directive: Directive) throws -> DirectiveSlice`.
  - `WorldSnapshot.init(core:slice:now:)` — internal, composing the public shape.

- [ ] **Step 1: Write the failing test**

Append to `DirectiveSliceTests.swift`:

```swift
@Suite struct DirectiveSliceComposition {
    /// The composed snapshot is the core plus the slice and nothing else — the
    /// invariant every later task leans on.
    @Test func composesTheSameSnapshotAsTheDirectRead() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try DirectiveLogEntry.insert { dispatchEntry("L1", op: "OP-A", at: 1) }.execute(db)
        }
        let directive = sliceDirective()
        let now = Date(timeIntervalSince1970: 100)

        let composed = try await database.read { db -> WorldSnapshot in
            let core = try WorldCore.read(db)
            let slice = try DirectiveSlice.read(db, core: core, directive: directive)
            return WorldSnapshot(core: core, slice: slice, now: now)
        }
        let direct = try await WorldSnapshot.read(from: database, now: now, directive: directive)

        #expect(composed == direct)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
swift test --package-path app --filter DirectiveSliceComposition \
  --event-stream-output-path /tmp/slice-red.jsonl
```

Expected: FAIL to compile — `DirectiveSlice` does not exist.

- [ ] **Step 3: Create `DirectiveSlice`**

Move the five scoped fetches verbatim, including the `baseWanted`/`baseDecoded`/`wanted`/`decoded` computation, which belongs to the slice. It reads `core.devices` to find the vessel.

- [ ] **Step 4: Add the composing init and re-point `WorldSnapshot.read`**

`WorldSnapshot.init(core:slice:now:)` assigns each field from one of the two. `WorldSnapshot.read` becomes core + slice + compose, all in the one existing transaction.

- [ ] **Step 5: Run the full suite**

```bash
swift test --package-path app --filter DirectiveEngine \
  --event-stream-output-path /tmp/slice-green.jsonl
```

Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add app/Modules/DirectiveEngine/Sources/DirectiveSlice.swift app/Modules/DirectiveEngine/Sources/WorldSnapshot.swift app/Modules/DirectiveEngine/Tests/DirectiveSliceTests.swift
git commit -m "refactor(directives): split the scoped half of a world read into DirectiveSlice"
```

---

### Task 5: Batch the slice reads

One `readAll` that answers for every running directive at once, so the scoped queries go from 22 round trips to 3.

**Files:**
- Modify: `app/Modules/DirectiveEngine/Sources/DirectiveSlice.swift`
- Test: `app/Modules/DirectiveEngine/Tests/DirectiveSliceTests.swift`

**Interfaces:**
- Consumes: `DirectiveSlice.read` from Task 4.
- Produces: `static func DirectiveSlice.readAll(_ db: Database, core: WorldCore, directives: [Directive]) throws -> [String: DirectiveSlice]`, keyed by `directive.id`. `read` is reimplemented as `readAll` with one element so there is exactly one implementation.

- [ ] **Step 1: Write the failing test**

```swift
@Suite struct DirectiveSliceBatching {
    /// Batched must equal individual for every directive, or the tick is
    /// quietly handing missions a different world than they get today.
    @Test func batchedMatchesIndividualForEachDirective() async throws {
        let database = try GameDatabase.bootstrap()
        let a = Directive(id: "D1", kind: .haulRun, status: .running, deviceCode: "V1", targets: ["SOL"], currentTarget: "SOL")
        let b = Directive(id: "D2", kind: .haulRun, status: .running, deviceCode: "V2", targets: ["VEGA"], currentTarget: "VEGA")
        try await database.write { db in
            try DirectiveLogEntry.insert { dispatchEntry("L1", op: "OP-A", at: 1) }.execute(db)
            try DirectiveLogEntry.insert {
                DirectiveLogEntry(
                    id: "L2", directiveID: "D2", deviceCode: nil, kind: .commandDispatched,
                    summary: "theirs", step: nil, operationID: "OP-B", eventID: nil,
                    occurredAt: Date(timeIntervalSince1970: 2)
                )
            }.execute(db)
        }

        try await database.read { db in
            let core = try WorldCore.read(db)
            let batched = try DirectiveSlice.readAll(db, core: core, directives: [a, b])
            #expect(batched["D1"] == (try DirectiveSlice.read(db, core: core, directive: a)))
            #expect(batched["D2"] == (try DirectiveSlice.read(db, core: core, directive: b)))
        }
    }

    /// An empty directive list must not emit `IN ()` or read anything.
    @Test func readsNothingForNoDirectives() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.read { db in
            #expect(try DirectiveSlice.readAll(db, core: WorldCore.read(db), directives: []).isEmpty)
        }
    }
}
```

- [ ] **Step 2: Run to verify it fails**

```bash
swift test --package-path app --filter DirectiveSliceBatching \
  --event-stream-output-path /tmp/batch-red.jsonl
```

Expected: FAIL to compile — `readAll` does not exist.

- [ ] **Step 3: Implement `readAll`**

Three batched queries, then a per-directive assembly pass in memory:

- `log`: one query `WHERE directiveID IN (ids)` ordered by `directiveID, occurredAt DESC`, then group and take the newest `logWindow` per directive, restoring ascending order. The per-directive `LIMIT` cannot be expressed in one plain query, so do the truncation in Swift after grouping.
- `auditLog`: the Task 1 query with `directiveID IN (ids)` and the `notIn` subquery correlated on the same directive. Group by `directiveID` afterwards.
- `dispatchedOperations`: the Task 2 queries with the id sets unioned across all directives, then split per directive by `directiveID` and by which ids each directive's dispatch entries name.
- `systems`/`siteAssays`: fetch the UNION of every directive's `decoded`/`wanted` designation sets once, then hand each slice its subset.

Guard the empty-directives case before building any `IN` list.

- [ ] **Step 4: Reimplement `read` in terms of `readAll`**

```swift
    static func read(_ db: Database, core: WorldCore, directive: Directive) throws -> DirectiveSlice {
        try readAll(db, core: core, directives: [directive])[directive.id] ?? .empty
    }
```

Add a `static let empty` with all five fields empty. One implementation means the equivalence test in Step 1 cannot drift.

- [ ] **Step 5: Run the full suite**

```bash
swift test --package-path app --filter DirectiveEngine \
  --event-stream-output-path /tmp/batch-green.jsonl
```

Expected: all pass, `WorldSnapshotTests`'s log-window cases especially — they are the ones that catch a per-directive `LIMIT` done wrong.

- [ ] **Step 6: Commit**

```bash
git add app/Modules/DirectiveEngine/Sources/DirectiveSlice.swift app/Modules/DirectiveEngine/Tests/DirectiveSliceTests.swift
git commit -m "perf(directives): answer every directive's scoped read in one pass"
```

---

### Task 6: `WorldTick.read` — one transaction for the whole tick

**Files:**
- Create: `app/Modules/DirectiveEngine/Sources/WorldTick.swift`
- Test: `app/Modules/DirectiveEngine/Tests/WorldTickTests.swift` *(new)*

**Interfaces:**
- Consumes: `WorldCore.read`, `DirectiveSlice.readAll`.
- Produces:
  - `struct WorldTick: Sendable` with `let generation: UInt64`, `let core: WorldCore`, `let slices: [String: DirectiveSlice]`, `let running: [Directive]`, `let now: Date`.
  - `static func WorldTick.read(from database: any DatabaseReader, now: Date, generation: UInt64) async throws -> WorldTick`.
  - `func WorldTick.snapshot(for directiveID: String) -> WorldSnapshot?` — composes `WorldSnapshot(core:slice:now:)`, returning `nil` when the directive has no slice.

- [ ] **Step 1: Write the failing test**

```swift
@Suite struct WorldTickReads {
    /// The whole point: one transaction, however many directives are running.
    /// Counting reads is what makes the 22x regression impossible to reintroduce
    /// without a red test.
    @Test func opensExactlyOneReadTransaction() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            for i in 1...5 {
                try Directive.insert {
                    Directive(id: "D\(i)", kind: .haulRun, status: .running,
                              deviceCode: "V\(i)", targets: ["SOL"], currentTarget: "SOL")
                }.execute(db)
            }
        }
        let counter = ReadCounter()
        let tick = try await WorldTick.read(
            from: counter.wrapping(database), now: Date(timeIntervalSince1970: 100), generation: 1
        )
        #expect(tick.running.count == 5)
        #expect(counter.reads == 1)
    }

    /// A running directive gets a snapshot; anything else gets none.
    @Test func composesASnapshotPerRunningDirective() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Directive.insert {
                Directive(id: "D1", kind: .haulRun, status: .running,
                          deviceCode: "V1", targets: ["SOL"], currentTarget: "SOL")
            }.execute(db)
            try Directive.insert {
                Directive(id: "D2", kind: .haulRun, status: .paused,
                          deviceCode: "V2", targets: ["SOL"], currentTarget: "SOL")
            }.execute(db)
        }
        let tick = try await WorldTick.read(
            from: database, now: Date(timeIntervalSince1970: 100), generation: 1
        )
        #expect(tick.snapshot(for: "D1") != nil)
        #expect(tick.snapshot(for: "D2") == nil)
    }
}
```

`ReadCounter` is a small test double wrapping `DatabaseReader` and incrementing on each `read`. If the codebase already has one, use it; otherwise write it in this test file — it is test-only and belongs there.

- [ ] **Step 2: Run to verify it fails**

```bash
swift test --package-path app --filter WorldTickReads \
  --event-stream-output-path /tmp/tick-red.jsonl
```

Expected: FAIL to compile — `WorldTick` does not exist.

- [ ] **Step 3: Implement `WorldTick.read`**

One `database.read { db in ... }` that fetches `running` (`Directive.where { $0.status.eq(DirectiveStatus.running) }`), then `WorldCore.read(db)`, then `DirectiveSlice.readAll(db, core:, directives: running)`. Nothing else opens a transaction.

- [ ] **Step 4: Run the full suite and commit**

```bash
swift test --package-path app --filter DirectiveEngine \
  --event-stream-output-path /tmp/tick-green.jsonl
git add app/Modules/DirectiveEngine/Sources/WorldTick.swift app/Modules/DirectiveEngine/Tests/WorldTickTests.swift
git commit -m "perf(directives): read the whole tick's world in one transaction"
```

---

### Task 7: Derive `WorldView` from `WorldCore`

**Files:**
- Modify: `app/Modules/DirectiveEngine/Sources/WorldView.swift`, `app/Modules/DirectiveEngine/Sources/WorldTick.swift`
- Test: `app/Modules/DirectiveEngine/Tests/WorldTickTests.swift`

**Interfaces:**
- Consumes: `WorldCore`.
- Produces: `WorldView.init(core: WorldCore, now: Date)` plus `WorldTick.view` populated from the same transaction. `WorldView.read(from:now:)` stays for any caller outside the engine.

- [ ] **Step 1: Write the failing test**

```swift
@Suite struct WorldViewFromCore {
    /// The brain's view and the directives' core must be the same world. Built
    /// from one read, they cannot disagree; built from two, they routinely did.
    @Test func matchesTheStandaloneRead() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Device.insert { /* the same Device fixture as WorldCoreTests */ }.execute(db)
        }
        let now = Date(timeIntervalSince1970: 100)
        let (fromCore, standalone) = try await database.read { db in
            (WorldView(core: try WorldCore.read(db), now: now), try WorldView.read(from: db, now: now))
        }
        #expect(fromCore == standalone)
    }
}
```

`WorldView` must be `Equatable` for this. If it is not, add the conformance — it is a value type of value types, so a synthesised conformance is enough.

- [ ] **Step 2: Run to verify it fails, then implement**

`WorldView`'s eight overlapping tables come from `core`. Its own extras — the `SiteAssay` salvage filter at `WorldView.swift:177`, the `stockLocations`/`operationalDepots` scoped reads at `:211` and `:224`, and the `stockpiles` filter at `:232` — are NOT in `core` and must keep their own fetches inside the same transaction. Do not widen `core` to hold them; they are `WorldView`-shaped, and `footprints` already carries the unfiltered rows `stockpiles` narrows.

- [ ] **Step 3: Run the full suite and commit**

```bash
swift test --package-path app --filter DirectiveEngine \
  --event-stream-output-path /tmp/view-green.jsonl
git add app/Modules/DirectiveEngine/Sources/WorldView.swift app/Modules/DirectiveEngine/Sources/WorldTick.swift app/Modules/DirectiveEngine/Tests/WorldTickTests.swift
git commit -m "perf(directives): build the brain's view from the tick's own read"
```

---

### Task 8: Rewire the engine to one tick loop

The only task that changes control flow, and the only one with a behaviour delta.

**Files:**
- Modify: `app/Modules/DirectiveEngine/Sources/DirectiveEngine.swift:96-232`
- Modify: `app/Modules/DirectiveEngine/Sources/WorldSnapshot.swift:118-140` (the `peers` doc comment)
- Test: `app/Modules/DirectiveEngine/Tests/WorldTickTests.swift`

**Interfaces:**
- Consumes: `WorldTick.read`, `WorldTick.snapshot(for:)`.
- Produces: no new public API. `evaluateOnce(directiveID:)` gains a `tick: WorldTick` parameter; `makeExecutor` no longer sleeps on its own clock.

- [ ] **Step 1: Write the failing test**

```swift
@Suite struct PausedDirectiveDelta {
    /// The one accepted behaviour change, pinned rather than left to
    /// inspection: the directive row now comes from the tick's read, so a pause
    /// that lands mid-tick is honoured on the NEXT tick, up to 5s later. The
    /// guarantee that survives is that it is never advanced AFTER being seen
    /// paused.
    @Test func advancesNoDirectivePausedBeforeTheTickRead() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Directive.insert {
                Directive(id: "D1", kind: .haulRun, status: .paused,
                          deviceCode: "V1", targets: ["SOL"], currentTarget: "SOL")
            }.execute(db)
        }
        let tick = try await WorldTick.read(
            from: database, now: Date(timeIntervalSince1970: 100), generation: 1
        )
        #expect(tick.running.isEmpty)
        #expect(tick.snapshot(for: "D1") == nil)
    }
}
```

- [ ] **Step 2: Run to verify it passes already**

This one may pass on Task 6's work alone. That is fine — it exists to pin the delta, not to drive new code. Note in the commit message that it is a characterisation test.

- [ ] **Step 3: Collapse the loops**

Replace the `supervisor` and `brain` Tasks in `start()` with a single `tickLoop`:

```swift
            tickLoop = Task { [weak self] in
                var generation: UInt64 = 0
                while !Task.isCancelled {
                    generation &+= 1
                    await self?.runTick(generation: generation)
                    try? await clock.sleep(for: tick)
                }
            }
```

`runTick` reads the world once, reconciles executors from `tick.running` (its own `Directive` read disappears), hands each executor its snapshot, and calls the brain with `tick.view`. `makeExecutor`'s `while !Task.isCancelled { evaluateOnce; sleep }` becomes a Task that awaits one snapshot delivery, evaluates, and returns — the tick loop drives the cadence now. Keep `executors` keyed by directive id so `stop()` and per-directive cancellation work exactly as they do today.

`evaluateOnce` drops its own `database.read` for the directive row and its `WorldSnapshot.read` call, taking both from the tick. Its `guard directive.status == .running` stays: `tick.running` already filters, but the guard is the check the comment at `:236` describes and it costs nothing.

- [ ] **Step 4: Correct the `peers` doc comment**

`WorldSnapshot.swift:118-140` argues `RelayRun.isNextInLine` is needed because runs are "independent `Task`s on independent five-second clocks... so 'whoever asks first' is a real race with no serialising authority above it". The tick loop is now that authority. Rewrite the paragraph to say every run in a tick sees the same `peers` from one read, which makes the FIFO answer identical across runs rather than dependent on who asked when — and that `isNextInLine` still does the arbitration, now deterministically. Do not delete `isNextInLine` or change `RelayRun`.

- [ ] **Step 5: Run the whole app test suite, not just DirectiveEngine**

```bash
swift test --package-path app \
  --event-stream-output-path /tmp/engine-green.jsonl
```

Expected: all pass. This is the task most likely to break something outside the module — `stop()` ordering, `@Shared(.brainReport)` clearing, and any test driving the engine with a `TestClock`.

- [ ] **Step 6: Commit**

```bash
git add app/Modules/DirectiveEngine/Sources/DirectiveEngine.swift app/Modules/DirectiveEngine/Sources/WorldSnapshot.swift app/Modules/DirectiveEngine/Tests/WorldTickTests.swift
git commit -m "perf(directives): drive every executor from one tick read"
```

---

### Task 9: Re-profile and record the real number

**Files:**
- Modify: `.scratch/directive-tick-batched-read/spec.md` (the "Expected result" section)

- [ ] **Step 1: Ask Matt for a fresh Time Profiler trace**

The estimate is ~18% of a core against today's 53%. Only Matt can capture the trace — the app needs a Keychain login a background job cannot complete. Ask for a trace of at least 90s of idle app time and the path to it.

- [ ] **Step 2: Attribute it the same way**

Export the `time-profile` table and aggregate. The parser must resolve `<tagged-backtrace ref="N"/>` — 147,218 of 280,546 rows in the original trace reused a deduplicated backtrace by ref, and dropping them silently attributes 47% of samples to "empty stack".

```bash
xcrun xctrace export --input <trace> \
  --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]' \
  --output tp.xml
```

- [ ] **Step 3: Record the measured result**

Replace the "Expected result" section's estimate with the measured split, and say plainly whether the arithmetic held. If it did not, the gap is the next investigation, not a rounding note.

- [ ] **Step 4: Commit**

```bash
git add .scratch/directive-tick-batched-read/spec.md
git commit -m "docs(directives): record the measured CPU after the batched tick read"
```

---

## Self-Review Notes

- **Spec coverage.** Decision 1 (batched read) → Tasks 5–6, 8. Decision 2 (executors stay concurrent) → Task 8. Decision 3 (brain shares the batch) → Task 7. Decision 4 (two scoped sets) → Tasks 1–2. Verification section → the mutation steps in Tasks 1–2, the read-counting test in Task 6, the paused-directive test in Task 8, the `launch` test in Task 2, and Task 9.
- **Spec correction made here.** The spec says `WorldSnapshot`'s shape is unchanged AND that the audit pass gets "its own set". Both cannot be true if the audit set is a new field. Resolved in Task 2: `dispatchedOperations` is the union of the kind-filtered mission set and the audit set, so it stays one field of one type. Two queries, one lookup.
- **Known gap.** Task 5's per-directive `logWindow` truncation is described but not written as code, because the right shape depends on whether the codebase prefers a window function or a Swift-side group-and-take. The task names both the constraint and the test that catches it wrong.
