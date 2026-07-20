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
- `GameDatabase.migrator()` — registers all 11 tables' migrations.
- `GameDatabase.bootstrap() throws -> any DatabaseWriter` — opens the default DB (in-memory in test/preview contexts), migrates, returns the writer.
- `GameDatabase.configuration` — DEBUG SQL tracing (logger when live, console in preview, silent in test).
- `DependencyValues.bootstrapDatabase()` and `bootstrapDatabase(seed:)` — the latter for previews: `try $0.bootstrapDatabase { db in try db.seed { Model.previewFixture } }`.

**Why:** before this, `bootstrapDatabase` lived in the app target (unreachable from modules), so every feature preview/test hand-rolled `SQLiteData.defaultDatabase()` + migrator + `$0.defaultDatabase = database`. Now all ~13 test files call `GameDatabase.bootstrap()` and the two DB previews (MessagesView, BlueprintDetailView) use `bootstrapDatabase(seed:)`.

**How to apply:** new feature modules with DB previews/tests should add `GameDatabase` as a dep (source target for previews, test target for tests) and call it — never re-register migrations locally. A new `@Table` registers its migration in `GameDatabase.migrator()`.

**Manual step:** the app target imports GameDatabase; per [[pbxproj-link-is-manual]] the user must link the GameDatabase library product to the app target in Xcode.
