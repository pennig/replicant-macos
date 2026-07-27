# Append-Only Database Migrations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop schema changes from wiping the local database, so the rate-limited stars catalogue and the click-to-rehydrate location tables survive adding a table.

**Architecture:** Migration *order* moves out of the identifier and into a single ordered array (`GameDatabase.manifest`), whose index is the order — so there is no ordering key that can collide and a new migration is always an append. Identifiers stay byte-for-byte unchanged, so existing databases see every migration still applied and nothing re-runs. `eraseDatabaseOnSchemaChange` is deleted and replaced by a deliberate reset that only ever runs at bootstrap.

**Tech Stack:** Swift 6, SwiftPM (`app/Modules/Package.swift`), SQLiteData (Point-Free) over GRDB, Swift Testing.

## Global Constraints

- Design spec: `app/docs/superpowers/specs/2026-07-26-database-migrations-design.md`. Read it before Task 1.
- **Migration identifier strings must never change.** GRDB persists only the identifier; renaming one makes an existing database treat it as unapplied and re-run its `CREATE TABLE` against a table that already exists. Every identifier in this plan is copied verbatim from the current source.
- **Migrations are append-only.** Never edit the body of a migration that already exists. New schema changes append to `GameDatabase.manifest`.
- Logging is `os.Logger` only, subsystem `name.pennig.replicould`, category = module name. No `print`.
- All package work happens in `app/Modules` (where `Package.swift` lives).
- `swift test` results are read from the Swift Testing JSON event stream, never by parsing console text. Use the invocation in "Running tests" below.
- Commits go directly to the working branch. No PRs, no pushing to `origin`.

## Running tests

Every test step in this plan uses this form. `--test-product` is required: under the default `swiftbuild` backend, one process per test product truncates a shared event-stream file, so a whole-package run would silently report only the last target's results.

```bash
cd app/Modules
swift test --test-product GameDatabaseTests \
  --disable-xctest \
  --event-stream-version "6.3" \
  --event-stream-output-path .build/events.jsonl \
  --filter '<TestNameRegex>'
```

Then read the result — never the console text:

```bash
# Summary counts
jq -s '
  map(select(.kind=="event").payload) as $e
  | ($e | map(select(.kind=="issueRecorded" and .issue.isFailure != false).testID) | unique) as $failed
  | { total:   ($e | map(select(.kind=="testStarted")) | length),
      failed:  ($failed | length),
      passed:  (($e | map(select(.kind=="testEnded")) | length) - ($failed | length)) }
' .build/events.jsonl

# Failing tests with locations
jq -r 'select(.kind=="event").payload
       | select(.kind=="issueRecorded" and .issue.isFailure != false)
       | "\(.issue.sourceLocation.filePath):\(.issue.sourceLocation.line): \(.testID)\n    \(.messages[0].text)"' \
  .build/events.jsonl

# Did the run actually complete? (absence of runEnded means the process died)
jq -s -e 'any(.[]; .kind=="event" and .payload.kind=="runEnded")' .build/events.jsonl >/dev/null \
  || echo "run did not complete"
```

A typo'd `--filter` yields a valid, empty run that looks like success. Always confirm `total` is non-zero and matches expectation.

---

## File Structure

**Create:**
- `app/Modules/GameModels/Sources/SchemaMigration.swift` — the `SchemaMigration` value type and its `register(in:)` helper. Lives in `GameModels` because `UniverseModels` already depends on it, so both models modules can use it.
- `app/Modules/GameDatabase/Sources/DatabaseReset.swift` — reads and clears the reset triggers. Pure and injectable, so it is unit-testable without touching real `UserDefaults` or the process environment.
- `app/Modules/GameDatabase/Tests/SchemaManifestTests.swift` — frozen manifest test.
- `app/Modules/GameDatabase/Tests/GoldenSchemaTests.swift` — golden schema snapshot test.
- `app/Modules/GameDatabase/Tests/MigrationSafetyTests.swift` — the wipe bug, encoded as a regression test.
- `app/Modules/GameDatabase/Tests/DatabaseResetTests.swift` — reset trigger tests.
- `app/Modules/GameDatabase/Tests/Fixtures/schema.sql` — the golden schema fixture (generated in Task 6).
- `app/.claude/memory/erase-on-schema-change.md` — memory note on the root cause.

**Modify:**
- 14 files in `app/Modules/GameModels/Sources/` — convert `registerMigrations` to `SchemaMigration` values.
- 2 files in `app/Modules/UniverseModels/Sources/` — same.
- `app/Modules/GameDatabase/Sources/GameDatabase.swift` — the manifest, the `migrator(_:)` seam, the reset hook, deletion of the erase flag.
- `app/macOS/ReplicantApp.swift` — the Tools menu item. **No new file is added to the app target**, deliberately: the `.xcodeproj` cannot be edited from here (`pbxproj-link-is-manual` memory note), so the menu button and its AppKit confirm/relaunch go inline into a file the target already owns.
- `app/CLAUDE.md` — the append-only rule.
- `app/.claude/memory/MEMORY.md` — index line for the new note.

---

## Task 1: The `SchemaMigration` value type

**Files:**
- Create: `app/Modules/GameModels/Sources/SchemaMigration.swift`
- Test: `app/Modules/GameModels/Tests/SchemaMigrationTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `public struct SchemaMigration: Sendable`
  - `public init(_ identifier: String, migrate: @escaping @Sendable (Database) throws -> Void)`
  - `public init(_ identifier: String, merging: Set<String>, migrate: @escaping @Sendable (Database, Set<String>) throws -> Void)`
  - `public var identifier: String`
  - `public var mergedIdentifiers: Set<String>`
  - `public func register(in migrator: inout DatabaseMigrator)`

- [ ] **Step 1: Write the failing test**

Create `app/Modules/GameModels/Tests/SchemaMigrationTests.swift`:

```swift
//
//  SchemaMigrationTests.swift
//  GameModelsTests
//

import Foundation
import SQLiteData
import Testing

@testable import GameModels

@Suite struct SchemaMigrationTests {
    /// A registered migration runs, and GRDB records it under the exact
    /// identifier string it was given — the string existing databases key on.
    @Test func registersUnderItsIdentifier() throws {
        let migration = SchemaMigration("Create 'widgets' table") { db in
            try #sql(#"CREATE TABLE "widgets" ("id" TEXT PRIMARY KEY NOT NULL) STRICT"#)
                .execute(db)
        }

        var migrator = DatabaseMigrator()
        migration.register(in: &migrator)

        let database = try DatabaseQueue()
        try migrator.migrate(database)

        let applied = try database.read { try migrator.appliedIdentifiers($0) }
        #expect(applied == ["Create 'widgets' table"])
    }

    /// The merging initialiser hands the migration body the set of previously
    /// applied identifiers it supersedes, and drops their rows. This is the
    /// mechanism the future baseline squash relies on.
    @Test func mergingMigrationSupersedesOldIdentifiers() throws {
        let database = try DatabaseQueue()

        var old = DatabaseMigrator()
        SchemaMigration("v1") { db in
            try #sql(#"CREATE TABLE "widgets" ("id" TEXT PRIMARY KEY NOT NULL) STRICT"#)
                .execute(db)
        }
        .register(in: &old)
        try old.migrate(database)

        var seenApplied: Set<String>?
        var merged = DatabaseMigrator()
        SchemaMigration("Baseline", merging: ["v1"]) { _, appliedIDs in
            seenApplied = appliedIDs
        }
        .register(in: &merged)
        try merged.migrate(database)

        #expect(seenApplied == ["v1"])
        let applied = try database.read { try merged.appliedIdentifiers($0) }
        #expect(applied == ["Baseline"])
    }
}
```

- [ ] **Step 2: Run it to make sure it fails**

```bash
cd app/Modules
swift test --test-product GameModelsTests --disable-xctest \
  --event-stream-version "6.3" --event-stream-output-path .build/events.jsonl \
  --filter 'SchemaMigrationTests'
```

Expected: build failure — `cannot find 'SchemaMigration' in scope`.

- [ ] **Step 3: Write the implementation**

Create `app/Modules/GameModels/Sources/SchemaMigration.swift`:

```swift
//
//  SchemaMigration.swift
//  GameModels
//
//  One schema change, as a value. Ordering lives in `GameDatabase.manifest`
//  (an array whose index IS the order), deliberately NOT in `identifier` —
//  GRDB persists the identifier, so renaming one would make an existing
//  database treat the migration as unapplied and re-run its CREATE TABLE
//  against a table that already exists. Keeping order and identity separate
//  is what lets migrations be reordered on paper without touching real data.
//

import Foundation
import SQLiteData

public struct SchemaMigration: Sendable {
    /// The string GRDB writes to `grdb_migrations`. Immutable once shipped.
    public let identifier: String

    /// Identifiers this migration supersedes. Empty for every ordinary
    /// migration; populated only by a baseline squash.
    public let mergedIdentifiers: Set<String>

    private let body: @Sendable (Database, Set<String>) throws -> Void

    /// The ordinary case: a migration that runs the same way every time.
    public init(
        _ identifier: String,
        migrate: @escaping @Sendable (Database) throws -> Void
    ) {
        self.identifier = identifier
        self.mergedIdentifiers = []
        self.body = { db, _ in try migrate(db) }
    }

    /// The squash case. The body receives the subset of `merging` that was
    /// already applied, so it can skip work an older migration chain did.
    public init(
        _ identifier: String,
        merging mergedIdentifiers: Set<String>,
        migrate: @escaping @Sendable (Database, Set<String>) throws -> Void
    ) {
        self.identifier = identifier
        self.mergedIdentifiers = mergedIdentifiers
        self.body = migrate
    }

    /// Registers this migration with GRDB. Registration order is the caller's
    /// responsibility — see `GameDatabase.manifest`.
    public func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration(
            identifier,
            merging: mergedIdentifiers,
            migrate: body
        )
    }
}
```

- [ ] **Step 4: Run the tests and make sure they pass**

```bash
cd app/Modules
swift test --test-product GameModelsTests --disable-xctest \
  --event-stream-version "6.3" --event-stream-output-path .build/events.jsonl \
  --filter 'SchemaMigrationTests'
```

Expected: `{"total": 2, "failed": 0, "passed": 2}` from the summary query.

- [ ] **Step 5: Commit**

```bash
git add app/Modules/GameModels/Sources/SchemaMigration.swift \
        app/Modules/GameModels/Tests/SchemaMigrationTests.swift
git commit -m "Add SchemaMigration, separating migration order from identity"
```

---

## Task 2: Convert GameModels' migrations to `SchemaMigration`

Each model gains named static `SchemaMigration` properties and keeps `registerMigrations` as a thin shim, so the package compiles and every existing test passes at each point. Task 4 deletes the shims.

**Files (all Modify):**
- `app/Modules/GameModels/Sources/Message.swift:61`
- `app/Modules/GameModels/Sources/Blueprint.swift:203`
- `app/Modules/GameModels/Sources/Civilisation.swift:121`
- `app/Modules/GameModels/Sources/Replicant.swift:100`
- `app/Modules/GameModels/Sources/KnownReplicant.swift:355`
- `app/Modules/GameModels/Sources/Device.swift:639`
- `app/Modules/GameModels/Sources/Directive.swift:256` and `:294`
- `app/Modules/GameModels/Sources/FTLLink.swift:97`
- `app/Modules/GameModels/Sources/BobnetMessage.swift:96`
- `app/Modules/GameModels/Sources/BobnetChannel.swift:38`
- `app/Modules/GameModels/Sources/Operation.swift:250`
- `app/Modules/GameModels/Sources/EventLog.swift:151`
- `app/Modules/GameModels/Sources/LocationEvent.swift:171`

**Interfaces:**
- Consumes: `SchemaMigration` from Task 1.
- Produces, for use by Task 4's manifest — exact names and their **unchanged** identifier strings:

| Static property | Identifier string (verbatim, do not alter) |
|---|---|
| `Message.createMessages` | `Create 'messages' table` |
| `Message.addMessageCategories` | `Add category/subcategory to 'messages'` |
| `Blueprint.createBlueprints` | `Create 'blueprints' table` |
| `Civilisation.createCivilisations` | `Create 'civilisations' table` |
| `Replicant.createReplicants` | `Create 'replicants' table` |
| `KnownReplicant.createKnownReplicants` | `Create 'knownReplicants' table` |
| `Device.createDevices` | `Create 'devices' table` |
| `Directive.createDirectives` | `Create 'directives' table` |
| `Directive.addControllerCode` | `Add 'controllerCode' to 'directives'` |
| `DirectiveLogEntry.createDirectiveLogEntries` | `Create 'directiveLogEntries' table` |
| `FTLLinkRecord.createFTLLinks` | `Create 'ftlLinks' table` |
| `BobnetMessage.createBobnetMessages` | `Create 'bobnetMessages' table` |
| `BobnetChannel.createBobnetChannels` | `Create 'bobnetChannels' table` |
| `Operation.createOperations` | `Create 'operations' table` |
| `EventLog.createEventLogs` | `Create 'eventLogs' table` |
| `LocationEvent.createLocationEvents` | `Create 'locationEvents' table` |
| `LocationEvent.addObjectivesMet` | `Add 'objectivesMet' to locationEvents` |

- [ ] **Step 1: Convert one model and confirm the shape compiles**

Start with `Message.swift`. Replace the whole `registerMigrations` function (currently lines 61–82) with:

```swift
    /// The `messages` table, created 2026-07. Identifier is load-bearing —
    /// see `SchemaMigration`.
    public static let createMessages = SchemaMigration("Create 'messages' table") { db in
        try #sql(
            """
            CREATE TABLE "messages" (
              "id" INTEGER PRIMARY KEY NOT NULL,
              "messageType" TEXT NOT NULL DEFAULT '',
              "title" TEXT NOT NULL DEFAULT '',
              "body" TEXT NOT NULL DEFAULT '',
              "isRead" INTEGER NOT NULL DEFAULT 0,
              "createdAt" TEXT NOT NULL
            ) STRICT
            """
        )
        .execute(db)
    }

    /// v2.3.0 added optional category/subcategory groupings to messages.
    public static let addMessageCategories = SchemaMigration(
        "Add category/subcategory to 'messages'"
    ) { db in
        try #sql(#"ALTER TABLE "messages" ADD COLUMN "category" TEXT"#).execute(db)
        try #sql(#"ALTER TABLE "messages" ADD COLUMN "subcategory" TEXT"#).execute(db)
    }

    /// Temporary shim so `GameDatabase` keeps compiling mid-conversion.
    /// Deleted in the manifest task.
    public static func registerMigrations(_ migrator: inout DatabaseMigrator) {
        createMessages.register(in: &migrator)
        addMessageCategories.register(in: &migrator)
    }
```

Build to confirm the shape:

```bash
cd app/Modules && swift build --build-tests 2>&1 | tail -20
```

Expected: builds clean.

- [ ] **Step 2: Convert the remaining twelve files the same way**

For each file in the Files list, apply the identical transformation:

1. Move each `migrator.registerMigration("<id>") { db in … }` body into a `public static let <name> = SchemaMigration("<id>") { db in … }`, copying the SQL **character for character** — including multi-statement bodies like `Operation.createOperations` (table + `CREATE UNIQUE INDEX "operation_one_open_per_device"`) and `DirectiveLogEntry.createDirectiveLogEntries` (table + its three indexes).
2. Leave `registerMigrations` in place as a shim that calls `.register(in:)` on each, **in the same order the original registered them**.
3. Preserve every existing doc comment on the migrations.

Note `Directive.swift` holds two types: `Directive` (two migrations) and `DirectiveLogEntry` (one). Each keeps its own extension and its own shim.

A multi-statement body keeps every statement inside the one `SchemaMigration` — do **not** split a table and its indexes into separate migrations, because that would change the identifier set. `Operation.swift:250` becomes:

```swift
    public static let createOperations = SchemaMigration("Create 'operations' table") { db in
        try #sql(
            """
            CREATE TABLE "operations" (
              "id" TEXT PRIMARY KEY NOT NULL,
              "entityCode" TEXT NOT NULL,
              "kind" TEXT NOT NULL,
              "status" TEXT NOT NULL,
              "source" TEXT NOT NULL,
              "startedAt" TEXT NOT NULL,
              "completesAt" TEXT,
              "lastConfirmedAt" TEXT NOT NULL,
              "detail" TEXT NOT NULL DEFAULT '{}'
            ) STRICT
            """
        )
        .execute(db)
        // One open operation per device. `optimistic` is intentionally not in
        // this set, so dispatch can stage a row without conflicting with the
        // op it may replace.
        try #sql(
            """
            CREATE UNIQUE INDEX "operation_one_open_per_device"
              ON "operations" ("entityCode")
              WHERE "status" IN ('enqueued', 'active')
            """
        )
        .execute(db)
    }
```

- [ ] **Step 3: Build and run the full package tests**

```bash
cd app/Modules && swift build --build-tests 2>&1 | tail -20
swift test --test-product GameDatabaseTests --disable-xctest \
  --event-stream-version "6.3" --event-stream-output-path .build/events.jsonl
```

Expected: builds clean; `bootstrapComposesEverySchema` passes. Behaviour is unchanged at this point — the same identifiers register in the same order.

- [ ] **Step 4: Commit**

```bash
git add app/Modules/GameModels/Sources
git commit -m "Express GameModels migrations as SchemaMigration values"
```

---

## Task 3: Convert UniverseModels' migrations

**Files:**
- Modify: `app/Modules/UniverseModels/Sources/Star.swift:108`
- Modify: `app/Modules/UniverseModels/Sources/LocationRecords.swift:206`, `:227`, `:250`

**Interfaces:**
- Consumes: `SchemaMigration` from Task 1.
- Produces:

| Static property | Identifier string (verbatim) |
|---|---|
| `Star.createStars` | `Create 'stars' table` |
| `SystemDetail.createSystemDetails` | `Create 'systemDetails' table` |
| `LocationFootprint.createLocationFootprints` | `Create 'locationFootprints' table` |
| `SiteAssay.createSiteAssays` | `Create 'siteAssays' table` |

- [ ] **Step 1: Apply the same transformation as Task 2**

`Star.swift` becomes:

```swift
extension Star {
    /// The `stars` table — the census/galaxy terrain root. Kept beside the
    /// model so schema and type never drift.
    public static let createStars = SchemaMigration("Create 'stars' table") { db in
        try #sql(
            """
            CREATE TABLE "stars" (
              "designation" TEXT PRIMARY KEY NOT NULL,
              "spectralType" TEXT NOT NULL DEFAULT '',
              "color" TEXT NOT NULL DEFAULT '',
              "positionX" REAL NOT NULL DEFAULT 0,
              "positionY" REAL NOT NULL DEFAULT 0,
              "positionZ" REAL NOT NULL DEFAULT 0,
              "estimatedPlanets" INTEGER NOT NULL DEFAULT 0,
              "explored" INTEGER NOT NULL DEFAULT 0,
              "hasLife" INTEGER,
              "entryPoint" TEXT,
              "createdAt" TEXT NOT NULL,
              "firstVisitedAt" TEXT,
              "fullyScannedAt" TEXT
            ) STRICT
            """
        )
        .execute(db)
    }

    /// Temporary shim; deleted in the manifest task.
    public static func registerMigrations(_ migrator: inout DatabaseMigrator) {
        createStars.register(in: &migrator)
    }
}
```

`LocationRecords.swift` gets the same treatment for its three extensions (`SystemDetail`, `LocationFootprint`, `SiteAssay`), copying each `CREATE TABLE` verbatim.

`UniverseModels` already depends on `GameModels`, so `SchemaMigration` needs no new import beyond the existing `import SQLiteData` plus `import GameModels`. Add `import GameModels` to either file if it is not already present.

- [ ] **Step 2: Build and test**

```bash
cd app/Modules && swift build --build-tests 2>&1 | tail -20
swift test --test-product GameDatabaseTests --disable-xctest \
  --event-stream-version "6.3" --event-stream-output-path .build/events.jsonl
```

Expected: builds clean, existing test passes.

- [ ] **Step 3: Commit**

```bash
git add app/Modules/UniverseModels/Sources
git commit -m "Express UniverseModels migrations as SchemaMigration values"
```

---

## Task 4: The manifest

**Files:**
- Modify: `app/Modules/GameDatabase/Sources/GameDatabase.swift:28-53`
- Modify: all files touched in Tasks 2 and 3 (delete the shims)

**Interfaces:**
- Consumes: every static from Tasks 2 and 3.
- Produces:
  - `public static let manifest: [SchemaMigration]`
  - `public static func migrator(_ entries: [SchemaMigration] = manifest) -> DatabaseMigrator`

The `entries` parameter is the seam Task 7's regression test needs: it lets a test build a migrator from a *modified* manifest while still going through `GameDatabase`'s own configuration.

- [ ] **Step 1: Replace `migrator()` with the manifest**

In `GameDatabase.swift`, replace the entire `migrator()` function with:

```swift
    /// Every migration, in order. **The array index is the order** — there is
    /// deliberately no sequence number, so there is no ordering key that can
    /// collide and no reliance on a sort (Swift's is not stable, and a tie
    /// would order non-deterministically between runs).
    ///
    /// Append new migrations to the END. Never edit an entry that has shipped:
    /// its identifier is already recorded in real databases, so an edit simply
    /// never runs and leaves the schema silently stale. The golden schema test
    /// exists to catch exactly that.
    ///
    /// This order reproduces the original per-table registration order, so the
    /// identifiers written to `grdb_migrations` are unchanged.
    ///
    /// Adding a table? Decide its logout fate at the same time: account-scoped
    /// tables need a clear registered in `ReplicantApp.registerSessionCleanup()`
    /// (or `AccountManager`'s own teardown), or a second account on this
    /// machine inherits the first's rows — and "table is empty" cold-load
    /// gates then skip the fetch. `EventLog` is the one deliberate exemption
    /// (user-managed diagnostic ledger).
    public static let manifest: [SchemaMigration] = [
        Message.createMessages,
        Message.addMessageCategories,
        Blueprint.createBlueprints,
        Civilisation.createCivilisations,
        Star.createStars,
        SystemDetail.createSystemDetails,
        LocationFootprint.createLocationFootprints,
        SiteAssay.createSiteAssays,
        LocationEvent.createLocationEvents,
        LocationEvent.addObjectivesMet,
        Replicant.createReplicants,
        KnownReplicant.createKnownReplicants,
        Device.createDevices,
        Directive.createDirectives,
        Directive.addControllerCode,
        DirectiveLogEntry.createDirectiveLogEntries,
        FTLLinkRecord.createFTLLinks,
        BobnetMessage.createBobnetMessages,
        BobnetChannel.createBobnetChannels,
        // Qualified: `Operation` would otherwise be ambiguous with Foundation's.
        GameModels.Operation.createOperations,
        EventLog.createEventLogs,
    ]

    /// Builds a migrator from `entries`. The parameter exists so tests can
    /// migrate a deliberately-modified manifest through the real code path.
    public static func migrator(_ entries: [SchemaMigration] = manifest) -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        #if DEBUG
        migrator.eraseDatabaseOnSchemaChange = true
        #endif
        for entry in entries {
            entry.register(in: &migrator)
        }
        return migrator
    }
```

The erase flag stays for now — Task 7 removes it, with a test that proves the removal works.

- [ ] **Step 2: Delete every `registerMigrations` shim**

Remove the shim from all 17 extensions touched in Tasks 2 and 3. Confirm none remain:

```bash
cd app/Modules
grep -rn "registerMigrations" GameModels/Sources UniverseModels/Sources GameDatabase/Sources
```

Expected: no output.

There is one other call site — `EventLogFeature/Sources/EventLogView+Previews.swift:19` calls `EventLog.registerMigrations(&migrator)`. Replace that line with:

```swift
    EventLog.createEventLogs.register(in: &migrator)
```

- [ ] **Step 3: Build and test**

```bash
cd app/Modules && swift build --build-tests 2>&1 | tail -20
swift test --test-product GameDatabaseTests --disable-xctest \
  --event-stream-version "6.3" --event-stream-output-path .build/events.jsonl
```

Expected: builds clean, `bootstrapComposesEverySchema` passes.

- [ ] **Step 4: Commit**

```bash
git add app/Modules
git commit -m "Order migrations by one manifest array instead of per-table grouping"
```

---

## Task 5: Frozen manifest test

**Files:**
- Create: `app/Modules/GameDatabase/Tests/SchemaManifestTests.swift`

**Interfaces:**
- Consumes: `GameDatabase.manifest`.
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Write the test**

```swift
//
//  SchemaManifestTests.swift
//  GameDatabaseTests
//
//  Freezes the migration manifest. Migrations are append-only: an identifier
//  that has shipped is recorded in real databases, so renaming or reordering
//  one silently changes what those databases will do. This test makes either
//  mistake a build failure rather than a data-loss report.
//

import Foundation
import Testing

@testable import GameDatabase

@Suite struct SchemaManifestTests {
    /// Every shipped migration identifier, in order. ONLY ever append to this
    /// list — never reorder, rename, or delete an entry.
    static let frozenIdentifiers = [
        "Create 'messages' table",
        "Add category/subcategory to 'messages'",
        "Create 'blueprints' table",
        "Create 'civilisations' table",
        "Create 'stars' table",
        "Create 'systemDetails' table",
        "Create 'locationFootprints' table",
        "Create 'siteAssays' table",
        "Create 'locationEvents' table",
        "Add 'objectivesMet' to locationEvents",
        "Create 'replicants' table",
        "Create 'knownReplicants' table",
        "Create 'devices' table",
        "Create 'directives' table",
        "Add 'controllerCode' to 'directives'",
        "Create 'directiveLogEntries' table",
        "Create 'ftlLinks' table",
        "Create 'bobnetMessages' table",
        "Create 'bobnetChannels' table",
        "Create 'operations' table",
        "Create 'eventLogs' table",
    ]

    @Test func manifestMatchesTheFrozenList() {
        #expect(GameDatabase.manifest.map(\.identifier) == Self.frozenIdentifiers)
    }

    /// GRDB itself `precondition`-fails on a duplicate identifier at
    /// registration, which would crash the app at launch rather than fail a
    /// test. Catch it here first.
    @Test func identifiersAreUnique() {
        let identifiers = GameDatabase.manifest.map(\.identifier)
        #expect(Set(identifiers).count == identifiers.count)
    }
}
```

- [ ] **Step 2: Run it and confirm it passes**

```bash
cd app/Modules
swift test --test-product GameDatabaseTests --disable-xctest \
  --event-stream-version "6.3" --event-stream-output-path .build/events.jsonl \
  --filter 'SchemaManifestTests'
```

Expected: `{"total": 2, "failed": 0, "passed": 2}`.

- [ ] **Step 3: Prove the test actually bites**

Temporarily swap two adjacent entries in `GameDatabase.manifest` (e.g. `Blueprint.createBlueprints` and `Civilisation.createCivilisations`), re-run the command from Step 2, and confirm `manifestMatchesTheFrozenList` FAILS. Then revert the swap and confirm it passes again.

A frozen-list test that cannot fail is worse than no test, so this step is not optional.

- [ ] **Step 4: Commit**

```bash
git add app/Modules/GameDatabase/Tests/SchemaManifestTests.swift
git commit -m "Freeze the migration manifest against reordering and renaming"
```

---

## Task 6: Golden schema snapshot test

This is the test that catches an edit to an already-shipped `CREATE TABLE` — the one failure the frozen manifest cannot see, and the one that becomes silent once the erase flag is gone in Task 7.

**Files:**
- Create: `app/Modules/GameDatabase/Tests/GoldenSchemaTests.swift`
- Create: `app/Modules/GameDatabase/Tests/Fixtures/schema.sql` (generated in Step 2)

**Interfaces:**
- Consumes: `GameDatabase.bootstrap()`.
- Produces: `Fixtures/schema.sql`, which the future baseline squash uses verbatim as its migration body.

The fixture is located via `#filePath`, not `Bundle.module`. Bundle resources are read-only copies in the build directory, so regeneration would write to the wrong place; `#filePath` resolves to the real source file.

- [ ] **Step 1: Write the test**

```swift
//
//  GoldenSchemaTests.swift
//  GameDatabaseTests
//
//  Snapshots the schema a fresh database ends up with. Migrations are
//  append-only, so editing a shipped CREATE TABLE no longer wipes and
//  rebuilds — the edit simply never runs on an existing database and the
//  schema goes quietly stale. This test is what makes that loud.
//
//  Regenerate deliberately:
//    RC_REGENERATE_SCHEMA_FIXTURE=1 swift test --test-product GameDatabaseTests …
//  It rewrites the fixture AND still fails, so the change lands in a diff.
//

import Foundation
import SQLiteData
import Testing

@testable import GameDatabase

@Suite struct GoldenSchemaTests {
    static var fixtureURL: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "Fixtures/schema.sql")
    }

    /// `grdb_migrations` is excluded — it is GRDB-owned, and including it
    /// would couple this fixture to a library upgrade.
    static func dumpSchema(_ database: any DatabaseWriter) throws -> String {
        try database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT sql FROM sqlite_master
                WHERE sql IS NOT NULL
                  AND name NOT LIKE 'sqlite_%'
                  AND name <> 'grdb_migrations'
                ORDER BY type, name
                """
            )
            return rows.map { ($0["sql"] as String) + ";" }.joined(separator: "\n\n") + "\n"
        }
    }

    @Test func freshSchemaMatchesTheGoldenFixture() throws {
        let actual = try Self.dumpSchema(try GameDatabase.bootstrap())

        if ProcessInfo.processInfo.environment["RC_REGENERATE_SCHEMA_FIXTURE"] == "1" {
            try FileManager.default.createDirectory(
                at: Self.fixtureURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try actual.write(to: Self.fixtureURL, atomically: true, encoding: .utf8)
            Issue.record("Regenerated \(Self.fixtureURL.lastPathComponent) — review the diff and re-run without the flag.")
            return
        }

        let expected = try String(contentsOf: Self.fixtureURL, encoding: .utf8)
        #expect(actual == expected)
    }
}
```

- [ ] **Step 2: Generate the fixture**

```bash
cd app/Modules
RC_REGENERATE_SCHEMA_FIXTURE=1 swift test --test-product GameDatabaseTests \
  --disable-xctest --event-stream-version "6.3" \
  --event-stream-output-path .build/events.jsonl \
  --filter 'GoldenSchemaTests'
```

Expected: the test FAILS with the "Regenerated" message (by design), and `GameDatabase/Tests/Fixtures/schema.sql` now exists.

- [ ] **Step 3: Review the generated fixture**

```bash
cat app/Modules/GameDatabase/Tests/Fixtures/schema.sql
```

Confirm it contains 18 `CREATE TABLE` statements and 4 `CREATE INDEX`/`CREATE UNIQUE INDEX` statements:

```bash
grep -c "^CREATE TABLE" app/Modules/GameDatabase/Tests/Fixtures/schema.sql   # expect 18
grep -c "^CREATE .*INDEX" app/Modules/GameDatabase/Tests/Fixtures/schema.sql # expect 4
```

- [ ] **Step 4: Run without the flag and confirm it passes**

```bash
cd app/Modules
swift test --test-product GameDatabaseTests --disable-xctest \
  --event-stream-version "6.3" --event-stream-output-path .build/events.jsonl \
  --filter 'GoldenSchemaTests'
```

Expected: `{"total": 1, "failed": 0, "passed": 1}`.

- [ ] **Step 5: Prove the test bites**

Temporarily add a column to `Star.createStars`'s `CREATE TABLE` (e.g. `"scratch" TEXT`), re-run Step 4, and confirm the test FAILS with a schema diff. Revert and confirm it passes.

- [ ] **Step 6: Commit**

```bash
git add app/Modules/GameDatabase/Tests/GoldenSchemaTests.swift \
        app/Modules/GameDatabase/Tests/Fixtures/schema.sql
git commit -m "Snapshot the schema so edits to shipped migrations fail loudly"
```

---

## Task 7: Remove `eraseDatabaseOnSchemaChange`

TDD applies directly here: the test reproduces the wipe, fails while the flag is set, and passes once it is gone.

**Files:**
- Create: `app/Modules/GameDatabase/Tests/MigrationSafetyTests.swift`
- Modify: `app/Modules/GameDatabase/Sources/GameDatabase.swift` (the `migrator(_:)` body from Task 4)

**Interfaces:**
- Consumes: `GameDatabase.manifest`, `GameDatabase.migrator(_:)`.

- [ ] **Step 1: Write the failing test**

The inserted migration must go **mid-list**, not at the end. Appending at the end does not trigger the erase — which is exactly why the wipes felt arbitrary.

```swift
//
//  MigrationSafetyTests.swift
//  GameDatabaseTests
//
//  The regression that motivated append-only migrations: adding a table used
//  to erase the whole database, taking the rate-limited stars catalogue and
//  the click-to-rehydrate location tables with it.
//

import Foundation
import SQLiteData
import Testing
import UniverseModels

@testable import GameDatabase

@Suite struct MigrationSafetyTests {
    /// Adding a migration in the MIDDLE of the manifest must not cost existing
    /// rows. Mid-list is the case that matters: GRDB's erase check compares
    /// against a throwaway database migrated to the last APPLIED identifier,
    /// so a migration appended at the end always survived and only a
    /// mid-list one wiped.
    @Test func addingAMigrationPreservesExistingRows() throws {
        let database = try GameDatabase.bootstrap()

        try database.write { db in
            try Star.insert {
                Star(
                    designation: "SOL", spectralType: "G2", color: "yellow-white",
                    positionX: 0, positionY: 0, positionZ: 0, estimatedPlanets: 8,
                    explored: true, hasLife: true, entryPoint: nil,
                    createdAt: .distantPast
                )
            }
            .execute(db)
        }

        var extended = GameDatabase.manifest
        extended.insert(
            SchemaMigration("test-only mid-list table") { db in
                try #sql(#"CREATE TABLE "midListProbe" ("x" TEXT) STRICT"#).execute(db)
            },
            at: 1
        )
        try GameDatabase.migrator(extended).migrate(database)

        let survivingStars = try database.read { try Star.fetchCount($0) }
        #expect(survivingStars == 1, "a new mid-list migration erased the catalogue")
    }
}
```

`Star` has no `Draft` type (its primary key is the natural `designation`, not generated), so the memberwise initialiser is used directly — `firstVisitedAt` and `fullyScannedAt` are defaulted. This matches the existing pattern in `DirectivesFeature/Tests/NewDirectiveFeatureTests.swift:125`.

- [ ] **Step 2: Add `UniverseModels` to the test target**

The test imports `UniverseModels`, which `GameDatabaseTests` does not yet depend on. In `app/Modules/Package.swift`, in the `GameDatabaseTests` test target (around line 339), add `"UniverseModels"` to `dependencies`, keeping alphabetical order:

```swift
        .testTarget(
            name: "GameDatabaseTests",
            dependencies: [
                "GameDatabase",
                "GameModels",
                "UniverseModels",
                .product(name: "SQLiteData", package: "sqlite-data"),
            ],
            path: "GameDatabase/Tests"
        ),
```

- [ ] **Step 3: Run it and watch it fail**

```bash
cd app/Modules
swift test --test-product GameDatabaseTests --disable-xctest \
  --event-stream-version "6.3" --event-stream-output-path .build/events.jsonl \
  --filter 'MigrationSafetyTests'
```

Expected: FAIL — `a new mid-list migration erased the catalogue`, because `eraseDatabaseOnSchemaChange` is still set. **This failure is the whole point; do not proceed until you have seen it.**

- [ ] **Step 4: Remove the flag**

In `GameDatabase.swift`, delete these three lines from `migrator(_:)`:

```swift
        #if DEBUG
        migrator.eraseDatabaseOnSchemaChange = true
        #endif
```

so the function reads:

```swift
    /// Builds a migrator from `entries`. The parameter exists so tests can
    /// migrate a deliberately-modified manifest through the real code path.
    ///
    /// `eraseDatabaseOnSchemaChange` is deliberately NOT set. It wiped the
    /// database whenever a migration landed anywhere but the end of the list,
    /// which cost the stars catalogue repeatedly. A migration that throws now
    /// surfaces through `bootstrapDatabase`'s `withErrorReporting` instead.
    public static func migrator(_ entries: [SchemaMigration] = manifest) -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        for entry in entries {
            entry.register(in: &migrator)
        }
        return migrator
    }
```

- [ ] **Step 5: Run the tests and make sure they pass**

```bash
cd app/Modules
swift test --test-product GameDatabaseTests --disable-xctest \
  --event-stream-version "6.3" --event-stream-output-path .build/events.jsonl
```

Expected: every `GameDatabaseTests` test passes, including the golden schema and frozen manifest tests.

- [ ] **Step 6: Commit**

```bash
git add app/Modules/GameDatabase app/Modules/Package.swift
git commit -m "Stop erasing the database on schema change"
```

---

## Task 8: The deliberate reset

**Files:**
- Create: `app/Modules/GameDatabase/Sources/DatabaseReset.swift`
- Create: `app/Modules/GameDatabase/Tests/DatabaseResetTests.swift`
- Modify: `app/Modules/GameDatabase/Sources/GameDatabase.swift` (the `bootstrap()` body)

**Interfaces:**
- Produces:
  - `public enum DatabaseReset`
  - `public static let userDefaultsKey = "RCResetDatabaseOnNextLaunch"`
  - `public static let environmentKey = "RC_RESET_DATABASE"`
  - `public static func consumeRequest(defaults: UserDefaults, environment: [String: String]) -> Bool`
  - `public static func requestOnNextLaunch(defaults: UserDefaults = .standard)`

`consumeRequest` takes its inputs so tests never touch real `UserDefaults` or the process environment.

- [ ] **Step 1: Write the failing tests**

```swift
//
//  DatabaseResetTests.swift
//  GameDatabaseTests
//

import Foundation
import Testing

@testable import GameDatabase

@Suite struct DatabaseResetTests {
    /// A fresh suite of defaults per test, so nothing leaks between them.
    private func makeDefaults(_ name: String) -> UserDefaults {
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func noTriggersMeansNoReset() {
        let defaults = makeDefaults("rc.reset.none")
        #expect(DatabaseReset.consumeRequest(defaults: defaults, environment: [:]) == false)
    }

    @Test func environmentVariableRequestsReset() {
        let defaults = makeDefaults("rc.reset.env")
        let environment = [DatabaseReset.environmentKey: "1"]
        #expect(DatabaseReset.consumeRequest(defaults: defaults, environment: environment))
    }

    @Test func flagRequestsResetAndIsClearedImmediately() {
        let defaults = makeDefaults("rc.reset.flag")
        DatabaseReset.requestOnNextLaunch(defaults: defaults)

        #expect(DatabaseReset.consumeRequest(defaults: defaults, environment: [:]))
        // Cleared BEFORE the erase runs, so a crash mid-erase cannot produce a
        // reset loop that wipes the database on every launch.
        #expect(DatabaseReset.consumeRequest(defaults: defaults, environment: [:]) == false)
    }
}
```

- [ ] **Step 2: Run and watch them fail**

```bash
cd app/Modules
swift test --test-product GameDatabaseTests --disable-xctest \
  --event-stream-version "6.3" --event-stream-output-path .build/events.jsonl \
  --filter 'DatabaseResetTests'
```

Expected: build failure — `cannot find 'DatabaseReset' in scope`.

- [ ] **Step 3: Write the implementation**

Create `app/Modules/GameDatabase/Sources/DatabaseReset.swift`:

```swift
//
//  DatabaseReset.swift
//  GameDatabase
//
//  The one deliberate way to wipe the local database. Reset happens ONLY at
//  bootstrap, before the SSE ingestion pipeline, the directive engine, and any
//  @FetchAll observer are running — an in-place erase would drop tables out
//  from under all three. Both triggers feed this single path.
//

import Foundation
import os

public enum DatabaseReset {
    /// Set by the Tools ▸ Reset Local Database… menu item, consumed at the
    /// next launch.
    public static let userDefaultsKey = "RCResetDatabaseOnNextLaunch"

    /// The rescue path: available in every configuration, because a bad schema
    /// can stop the app launching at all, which is exactly when a menu item is
    /// unreachable.
    public static let environmentKey = "RC_RESET_DATABASE"

    /// Whether a reset was requested, clearing the persistent flag as a side
    /// effect. Cleared BEFORE the caller erases, so a crash mid-erase cannot
    /// leave the flag set and wipe the database on every subsequent launch.
    public static func consumeRequest(
        defaults: UserDefaults,
        environment: [String: String]
    ) -> Bool {
        let flagged = defaults.bool(forKey: userDefaultsKey)
        if flagged {
            defaults.removeObject(forKey: userDefaultsKey)
        }
        return flagged || environment[environmentKey] == "1"
    }

    /// Arms a reset for the next launch. The caller relaunches.
    public static func requestOnNextLaunch(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: userDefaultsKey)
    }
}
```

This file needs only `import Foundation` — the warning in `bootstrap()` uses the `logger` already declared at the bottom of `GameDatabase.swift`, so do not declare a second one here.

- [ ] **Step 4: Run the tests and make sure they pass**

```bash
cd app/Modules
swift test --test-product GameDatabaseTests --disable-xctest \
  --event-stream-version "6.3" --event-stream-output-path .build/events.jsonl \
  --filter 'DatabaseResetTests'
```

Expected: `{"total": 3, "failed": 0, "passed": 3}`.

- [ ] **Step 5: Hook it into `bootstrap()`**

Replace `GameDatabase.bootstrap()` with:

```swift
    /// Opens the default database and runs every migration, returning the writer.
    ///
    /// SQLiteData vends an in-memory store automatically in test and preview
    /// contexts, so the same call bootstraps production, previews, and tests.
    /// The writer is returned so tests can read and write it directly.
    ///
    /// Honours a requested reset (see `DatabaseReset`) before migrating. The
    /// check is skipped outside `.live`: tests and previews already get a
    /// fresh in-memory store, where erasing would be meaningless.
    public static func bootstrap() throws -> any DatabaseWriter {
        let database = try SQLiteData.defaultDatabase(configuration: configuration)
        @Dependency(\.context) var context
        if context == .live,
           DatabaseReset.consumeRequest(
               defaults: .standard,
               environment: ProcessInfo.processInfo.environment
           )
        {
            logger.warning("Reset requested — erasing the local database before migrating.")
            try database.erase()
        }
        try migrator().migrate(database)
        return database
    }
```

- [ ] **Step 6: Build and run the whole GameDatabase suite**

```bash
cd app/Modules && swift build --build-tests 2>&1 | tail -20
swift test --test-product GameDatabaseTests --disable-xctest \
  --event-stream-version "6.3" --event-stream-output-path .build/events.jsonl
```

Expected: builds clean, all tests pass. The reset branch is inert here because tests do not run in `.live`.

- [ ] **Step 7: Commit**

```bash
git add app/Modules/GameDatabase
git commit -m "Add a deliberate, bootstrap-only database reset"
```

---

## Task 9: The Tools menu item

This task touches the app target, which cannot be built or exercised from an automated session (it hits the Keychain login wall, and screenshots/AppleScript are TCC-blocked). **Its verification is manual, by the user.** Everything it depends on is already covered by tests from Task 8.

**Files:**
- Modify: `app/macOS/ReplicantApp.swift:266-281` (the `.commands` block)

**Interfaces:**
- Consumes: `DatabaseReset.requestOnNextLaunch(defaults:)` from Task 8.

No new file is added to the app target — the `.xcodeproj` cannot be edited from here, so the button and its AppKit confirm/relaunch go inline into `ReplicantApp.swift`, which the target already owns.

- [ ] **Step 1: Add the menu item**

Inside the existing `CommandMenu("Tools")`, after the Event Log button, add:

```swift
                #if DEBUG
                Divider()

                Button("Reset Local Database…") {
                    confirmDatabaseReset()
                }
                #endif
```

- [ ] **Step 2: Add the confirm-and-relaunch helper**

Add this method to the same type, beside `registerSessionCleanup()`. `NSAlert` is used rather than a SwiftUI dialog because a `CommandMenu` button has no view hierarchy to present one from.

```swift
    #if DEBUG
    /// Arms a database reset and relaunches. The wipe itself happens at the
    /// next bootstrap, before ingestion or any observer is running — see
    /// `DatabaseReset`. The Keychain session is untouched, so the app comes
    /// back signed in and the catalogue can be reloaded straight away.
    private func confirmDatabaseReset() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Reset the local database?"
        alert.informativeText = """
            Every locally cached table is erased and rebuilt on relaunch, \
            including the stars catalogue and surveyed locations. The stars \
            catalogue endpoint is rate limited to roughly one call a minute, \
            and locations rehydrate only when selected.

            You stay signed in.
            """
        alert.addButton(withTitle: "Reset and Relaunch")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        DatabaseReset.requestOnNextLaunch()
        UserDefaults.standard.synchronize()

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(
            at: Bundle.main.bundleURL,
            configuration: configuration
        ) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
    #endif
```

Confirm `ReplicantApp.swift` imports both `AppKit` (or `SwiftUI`, which re-exports `NSApp` usage already present at line 140) and `GameDatabase`. Add `import GameDatabase` if absent.

- [ ] **Step 3: Hand to the user for manual verification**

The user should confirm, in a debug build from Xcode:

1. Tools ▸ "Reset Local Database…" appears with a divider above it.
2. Cancel leaves the database untouched (star count unchanged).
3. "Reset and Relaunch" quits, reopens, and comes back **signed in** with empty tables.
4. Relaunching again after that does **not** wipe a second time (the flag was consumed).
5. `RC_RESET_DATABASE=1` set in the Xcode scheme's environment also wipes on launch.

Star count, for steps 2–4:

```bash
sqlite3 ~/Library/Containers/name.pennig.replicould/Data/Library/Application\ Support/SQLiteData.db \
  "SELECT count(*) FROM stars;"
```

- [ ] **Step 4: Commit**

```bash
git add app/macOS/ReplicantApp.swift
git commit -m "Add Tools ▸ Reset Local Database…"
```

---

## Task 10: Documentation

**Files:**
- Modify: `app/Modules/GameDatabase/Sources/GameDatabase.swift` (the type's doc comment)
- Modify: `app/CLAUDE.md`
- Create: `app/.claude/memory/erase-on-schema-change.md`
- Modify: `app/.claude/memory/MEMORY.md`

- [ ] **Step 1: Fix the `GameDatabase` doc comment**

Its current claim that migrations are "Ordered so that tables referenced by others are created first" is vacuous — there are no foreign keys anywhere in the schema (`grep -rn "REFERENCES" GameModels/Sources UniverseModels/Sources` returns nothing). Replace the enum's doc comment with:

```swift
/// The single composition point for the app's database schema.
///
/// Migrations are **append-only**. `manifest` is the ordered list; its index is
/// the order. A shipped migration's identifier is already recorded in real
/// databases, so editing or reordering one changes what those databases do —
/// `SchemaManifestTests` and `GoldenSchemaTests` enforce this.
///
/// There are no foreign keys in this schema, so manifest order carries no
/// referential constraint; it exists so that new migrations are always an
/// append, which is what stops a schema change from wiping the database.
```

- [ ] **Step 2: Add the CLAUDE.md rule**

In `app/CLAUDE.md`, under `## Rules`, add:

```markdown
- **Database migrations are append-only.** A new schema change appends a `SchemaMigration` to `GameDatabase.manifest`; never edit, rename, or reorder one that has shipped — GRDB keys applied migrations by identifier, so an edit silently never runs and leaves the local schema stale. Adding a column to an existing table means a new `ALTER TABLE` migration, not a change to its `CREATE TABLE`. `SchemaManifestTests` freezes the identifier list and `GoldenSchemaTests` snapshots the resulting schema; regenerate the latter with `RC_REGENERATE_SCHEMA_FIXTURE=1` only when the change is intended. Wipe the local database deliberately via Tools ▸ "Reset Local Database…" or `RC_RESET_DATABASE=1`.
```

- [ ] **Step 3: Write the memory note**

Create `app/.claude/memory/erase-on-schema-change.md`:

```markdown
---
name: erase-on-schema-change
description: "Why adding a table used to wipe the local DB, and the append-only manifest that replaced it"
metadata:
  node_type: memory
  type: project
---

`GameDatabase.migrator()` used to set `eraseDatabaseOnSchemaChange = true` in
DEBUG. GRDB's `hasSchemaChanges` finds the **last registered** migration that is
already applied, migrates a throwaway database up to that same identifier, and
compares schemas — so a new migration registered anywhere but the END of the
global order made the two diverge and triggered `db.erase()`.

Migrations were registered grouped by table, so a new table landed mid-list and
wiped everything: the `stars` catalogue (rate-limited to ~1 call/minute) and the
`systemDetails` / `locationFootprints` / `siteAssays` tables that only rehydrate
when a location is clicked. Editing an already-applied `CREATE TABLE` did the
same. Appending at the very end happened to survive, which is why it felt
arbitrary.

**Fixed 2026-07-26.** Order now lives in `GameDatabase.manifest`, an array whose
index IS the order — no sequence numbers, so no ordering key can collide.
Identifiers were left byte-for-byte unchanged, so no existing database re-ran
anything and no reload was needed.

**How to apply:** append new migrations to the end of `manifest`; never edit a
shipped one. The replacement for the erase flag is `DatabaseReset` — Tools ▸
"Reset Local Database…" or `RC_RESET_DATABASE=1`, both of which only ever act at
bootstrap, before ingestion and observers are running.

Guardrails: `SchemaManifestTests` (frozen identifier list), `GoldenSchemaTests`
(schema snapshot, regenerate with `RC_REGENERATE_SCHEMA_FIXTURE=1`),
`MigrationSafetyTests` (the wipe itself, as a regression test).

A future baseline squash is supported natively via `SchemaMigration`'s `merging:`
initialiser; the golden fixture is the source text for its body. See
[[gamedatabase-module]].
```

- [ ] **Step 4: Add the index line**

In `app/.claude/memory/MEMORY.md`, beside the existing `gamedatabase-module` line, add:

```markdown
- [Erase-on-schema-change](erase-on-schema-change.md) — why adding a table used to wipe the DB (GRDB compares against the last APPLIED identifier, so mid-list migrations erased); replaced 2026-07-26 by the append-only `GameDatabase.manifest` + `DatabaseReset`.
```

- [ ] **Step 5: Full verification**

```bash
cd app/Modules && swift build --build-tests 2>&1 | tail -20
swift test --test-product GameDatabaseTests --disable-xctest \
  --event-stream-version "6.3" --event-stream-output-path .build/events.jsonl
swift test --test-product GameModelsTests --disable-xctest \
  --event-stream-version "6.3" --event-stream-output-path .build/events-gm.jsonl
```

Expected: clean build; zero failures in both, and a `runEnded` present in each stream.

- [ ] **Step 6: Commit**

```bash
git add app/CLAUDE.md app/.claude/memory app/Modules/GameDatabase
git commit -m "Document the append-only migration rule"
```

---

## Post-implementation check

Before declaring this done, confirm the user's real database was not disturbed. Identifiers were unchanged, so it should read exactly as it did before — 21 applied migrations, catalogue intact:

```bash
DB=~/Library/Containers/name.pennig.replicould/Data/Library/Application\ Support/SQLiteData.db
sqlite3 "$DB" "SELECT count(*) FROM grdb_migrations;"   # expect 21
sqlite3 "$DB" "SELECT count(*) FROM stars;"             # expect unchanged
```

This must be run by the user — an automated session is TCC-blocked from the app container.
