---
name: gamedatabase-module
description: "GameDatabase is the single schema-composition module; previews/tests bootstrap through it, not by hand."
metadata: 
  node_type: memory
  type: project
  originSessionId: a0cb260e-e0c3-4a83-871b-1fe43e911d26
---

`GameDatabase` (Modules/GameDatabase) is the one place the app's SQLite schema is composed. It depends on [[locations-catalog-feature]]'s UniverseModels + GameModels (UniverseModels already sits atop GameModels), so it can see every `@Table`.

It vends:
- `GameDatabase.migrator()` — builds a `DatabaseMigrator` from `GameDatabase.manifest`, the append-only ordered list of all 18 tables' migrations (see [[erase-on-schema-change]]).
- `GameDatabase.bootstrap() throws -> any DatabaseWriter` — opens the default DB (a temp-file-backed `DatabasePool` in test/preview contexts, per `SQLiteData.defaultDatabase()`), migrates, returns the writer.
- `GameDatabase.configuration` — DEBUG SQL tracing (logger when live, console in preview, silent in test).
- `DependencyValues.bootstrapDatabase()` and `bootstrapDatabase(seed:)` — the latter for previews: `try $0.bootstrapDatabase { db in try db.seed { Model.previewFixture } }`.

**Why:** before this, `bootstrapDatabase` lived in the app target (unreachable from modules), so every feature preview/test hand-rolled `SQLiteData.defaultDatabase()` + migrator + `$0.defaultDatabase = database`. Now all ~13 test files call `GameDatabase.bootstrap()` and the two DB previews (MessagesView, BlueprintDetailView) use `bootstrapDatabase(seed:)`.

**How to apply:** new feature modules with DB previews/tests should add `GameDatabase` as a dep (source target for previews, test target for tests) and call it — never re-register migrations locally. A new `@Table` **appends** its migration to `GameDatabase.manifest` — never registers it ad hoc and never edits or reorders a shipped entry (that's what silently stops it from running on an existing database; see [[erase-on-schema-change]]).

**Manual step:** the app target imports GameDatabase; per [[pbxproj-link-is-manual]] the user must link the GameDatabase library product to the app target in Xcode.
