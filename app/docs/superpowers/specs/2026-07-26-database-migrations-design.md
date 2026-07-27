# Solidify the database schema: append-only migrations

**Date:** 2026-07-26
**Status:** Approved design, pending implementation plan

## Problem

Adding a table — or editing an existing one — wipes the entire local database.
The expensive-to-rebuild data goes with it: the `stars` catalogue (a rate-limited
~1-call-per-minute endpoint), and `systemDetails` / `locationFootprints` /
`siteAssays`, which are only rehydrated by clicking individual locations. The
wipe has felt arbitrary, striking on some schema changes and not others.

## Root cause

`GameDatabase.migrator()` sets, in DEBUG only:

```swift
migrator.eraseDatabaseOnSchemaChange = true
```

GRDB's `hasSchemaChanges` (`DatabaseMigrator.swift:427`) finds the **last
registered** migration that is already applied, migrates a throwaway database up
to that same identifier, and compares the two schemas. If they differ it calls
`db.erase()`.

Migrations are registered *grouped by table*, so a new table lands in the middle
of the global list — `SiteAssay` sits between `LocationFootprint` and
`LocationEvent`. The throwaway database therefore picks up the new table while
the real one has not run it yet, the schemas differ, and everything is erased.

This explains the apparent arbitrariness:

| Change | Outcome |
|---|---|
| New migration registered **last** in the global order | Survives |
| New migration registered **anywhere else** | Full wipe |
| Edit to an already-applied `CREATE TABLE` body | Full wipe |

The most recent instance is commit `0b95996` (2026-07-25), which appended
`"Add 'controllerCode' to 'directives'"` inside `Directive.registerMigrations` —
mid-list globally, hence a wipe on the next launch.

## Goals

- A schema change never destroys local data.
- Accidental edits to shipped migrations fail loudly, in tests, not silently at runtime.
- Resetting the database remains possible, but only ever on purpose.
- Preserve the existing convention that schema SQL lives beside its `@Table` type.
- Leave a clean path to periodically collapse the migration list into a fresh baseline.

## Non-goals

- Separating the catalogue into its own SQLite file. Once nothing erases
  automatically, the catalogue is safe in the main database, and SQLiteData's
  `defaultDatabase` is a single global that would have to be threaded through
  every `@FetchAll`, preview, and test.
- Squashing the current 21 migrations. The machinery lands now; the squash is a
  later, separately reviewable commit (see "Future: baseline squash").
- Any data migration or catalogue reload. None is required — see "Rollout".

## Design

### 1. `SchemaMigration`, and a manifest that *is* the order

A small value type in `GameModels` (which `UniverseModels` already sits atop):

```swift
public struct SchemaMigration: Sendable {
    public let identifier: String
    public let mergedIdentifiers: Set<String>
    public let migrate: @Sendable (Database, Set<String>) throws -> Void

    /// The ordinary case.
    public init(_ identifier: String, migrate: @escaping @Sendable (Database) throws -> Void)

    /// The squash case; see "Future: baseline squash".
    public init(
        _ identifier: String,
        merging: Set<String>,
        migrate: @escaping @Sendable (Database, Set<String>) throws -> Void
    )
}
```

`mergedIdentifiers` is present from the start (empty by default) so the eventual
squash needs no change to the type.

Each model replaces `static func registerMigrations(_:)` with named static
properties — `Star.createStars`, `Message.addCategories`,
`Directive.addControllerCode` — keeping the SQL beside the type. `GameDatabase`
then holds one ordered array:

```swift
static let manifest: [SchemaMigration] = [
    Message.createMessages,
    Message.addCategories,
    Blueprint.createBlueprints,
    // …
    Directive.addControllerCode,   // new migrations append here, forever
]
```

**The array index is the order.** There is no separate sequence number, so there
is no ordering key that can collide, and no reliance on `sort` (which is not
stable in Swift and would order ties non-deterministically between runs).

`GameDatabase.migrator()` becomes a loop over `manifest`, registering each entry
by identifier.

The initial manifest reproduces today's registration order exactly, so the set of
identifiers written to `grdb_migrations` is unchanged and nothing re-runs.

#### Why identifiers must not change

GRDB persists only the identifier string. Renaming identifiers would make an
existing database look like it has 21 unapplied migrations, whose `CREATE TABLE`
statements would then fail against tables that already exist. Decoupling *order*
(array position) from *identity* (the unchanged string) avoids this entirely —
no reconciliation pass, no wipe.

#### Guarantees against ordering mistakes

| Failure | Caught by |
|---|---|
| Duplicate ordering key | Impossible — there are no ordering keys |
| Duplicate identifier | GRDB `precondition` at bootstrap (`DatabaseMigrator.swift:575`) |
| Reordering or renaming a shipped migration | Frozen-manifest test (§4) |
| Editing a shipped `CREATE TABLE` body | Golden schema snapshot (§4) |

### 2. Remove `eraseDatabaseOnSchemaChange`

The flag goes, and with it the `#if DEBUG` asymmetry in *erase behaviour* —
debug and release now migrate identically. (The reset hatch in §3 is a separate
concern and remains partly DEBUG-gated.)

The trade is deliberate. A migration that throws used to wipe and silently
rebuild; it now fails loudly through the existing `withErrorReporting` in
`ReplicantApp.init`, naming the migration that threw and pointing at the reset
hatch.

There is one new sharp edge, called out here because it is the cost of this
change: editing an already-applied `CREATE TABLE` body no longer wipes, so the
edit simply never runs and the local schema is silently out of date. The golden
schema test (§4) exists specifically to catch this, and must run in the normal
suite.

### 3. Reset: one code path, two triggers

`GameDatabase.bootstrap()` keeps its current signature — the ~13 test files and
the two preview call sites are untouched — and consults the reset triggers
internally before migrating. The check is skipped outside the `.live` context,
since SQLiteData already vends a fresh in-memory store to tests and previews,
where erasing would be meaningless. Reset is requested by either:

- **`RC_RESET_DATABASE=1`** in the environment — available in all
  configurations. This is the rescue path when a bad schema stops the app
  launching at all, which is exactly when a menu item is unreachable.
- **A `UserDefaults` flag** (`RCResetDatabaseOnNextLaunch`), set by the menu item
  below. Bootstrap reads **and clears it before erasing**, so a crash mid-erase
  cannot produce a reset loop.

**Tools ▸ "Reset Local Database…"** (DEBUG-only, behind a confirmation) sets the
flag and relaunches via `NSWorkspace.openApplication` with
`createsNewApplicationInstance`, then terminates.

Reset therefore only ever happens at bootstrap, before the SSE ingestion
pipeline, the directive engine, and any `@FetchAll` observer are running. An
in-place live erase would drop tables out from under all three and would require
replaying the whole logout teardown ordering to be safe; this design avoids that
class of problem rather than managing it.

The Keychain session is untouched, so the app relaunches signed in and the
catalogue can be reloaded immediately.

Per-table reset is deliberately omitted: with the catalogue no longer at risk,
clearing a single table while iterating is better served by `sqlite3` than by
permanent UI.

### 4. Guardrails

Three tests in `GameDatabase/Tests`:

**Frozen manifest.** Compares `GameDatabase.manifest.map(\.identifier)` against a
checked-in array literal. Reordering or renaming a shipped migration fails, and
the diff names exactly what moved.

**Golden schema snapshot.** Bootstraps a fresh in-memory database, dumps

```sql
SELECT type, name, sql FROM sqlite_master
WHERE sql IS NOT NULL AND name NOT LIKE 'sqlite_%'
ORDER BY type, name;
```

and compares against `GameDatabase/Tests/Fixtures/schema.sql`. This is the test
that catches an edit to a shipped `CREATE TABLE` body. `grdb_migrations` is
excluded from the dump — it is GRDB-owned and would couple the fixture to a
library upgrade. Running the suite with `RC_REGENERATE_SCHEMA_FIXTURE=1` rewrites
the fixture and fails the test with a note saying it did, so regenerating is
always deliberate and always shows up in a diff.

**The bug, as a test.** Seed the catalogue tables, register an extra migration on
top of `GameDatabase.migrator()`, re-migrate, and assert the seeded rows survive.
This encodes "adding a table must not cost me the stars" directly, so the
regression cannot return silently.

### 5. Documentation

- Rewrite the `GameDatabase` doc comment. Its current claim that migrations are
  "ordered so that tables referenced by others are created first" is vacuous —
  there are no foreign keys anywhere in the schema.
- Add a CLAUDE.md rule: migrations are append-only; shipped migrations are
  immutable; new ones append to `GameDatabase.manifest`.
- Add a `.claude/memory/` note recording the erase mechanism, so the root cause
  is not rediscovered from scratch.

## Future: baseline squash

GRDB supports this natively via `registerMigration(_:merging:)`
(`DatabaseMigrator.swift:313`), which is why `SchemaMigration` carries
`mergedIdentifiers` from day one.

```swift
SchemaMigration("Baseline YYYY-MM-DD", merging: legacyIdentifiers) { db, appliedIDs in
    guard appliedIDs.isEmpty else { return }   // old chain already built this schema
    try #sql(goldenSchemaDDL).execute(db)
}
```

An existing database has the merged identifiers applied, so GRDB skips the body
and swaps those rows for the single baseline row — no data touched, no reload. A
fresh database runs the baseline DDL. The golden schema fixture is the source
text for that body, which is the real payoff of §4.

Two details for whoever executes it:

- The `guard` above silently no-ops on a *partially* applied chain, leaving a
  half-built schema. The real implementation must assert all-or-nothing and throw
  loudly on anything in between.
- GRDB's documentation warns against naming a merged migration after the *first*
  elements of the merged set; a dated name avoids this.

## Rollout

No data migration and no catalogue reload are required.

Identifiers are unchanged, so an existing database sees all its migrations still
applied and runs nothing. This was verified before the change: the last migration
edit was `0b95996` (2026-07-25 23:44), the app has run since, and
`SELECT count(*) FROM grdb_migrations` returns **21** — matching the 21
migrations registered in source (18 `CREATE TABLE` plus 3 `ALTER TABLE`). The
live database is in sync with the source definitions.

## Risks

| Risk | Mitigation |
|---|---|
| An edit to a shipped migration now silently no-ops instead of wiping | Golden schema test, run in the normal suite |
| A failed migration leaves a partially-migrated database | Loud `withErrorReporting` failure naming the migration; `RC_RESET_DATABASE=1` as the escape |
| A new migration is added to a model but forgotten in the manifest | Not caught by the golden schema test — an unregistered migration never runs, so the fresh-bootstrap schema is unchanged and the fixture still matches. `bootstrapComposesEverySchema`'s full-column `.all.fetchAll` per table is what catches this in practice: a model gains a property with no matching `ALTER TABLE`/manifest entry, and the generated `SELECT` fails to prepare against the real (unchanged) schema |
| The reset menu item is triggered by accident | DEBUG-only, behind a confirmation, and requires a relaunch |

## Scope

- ~21 call-site conversions across `GameModels` and `UniverseModels`
- One rewrite of `GameDatabase.migrator()` plus the new `SchemaMigration` type
- One DEBUG menu item and the bootstrap reset path
- Three tests and one golden fixture
- Doc comment, CLAUDE.md rule, memory note
