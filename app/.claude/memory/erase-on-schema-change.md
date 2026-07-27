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
