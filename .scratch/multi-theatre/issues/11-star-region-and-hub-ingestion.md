# 11 — Star region and hub ingestion

Type: task
Status: open
Blocked by: —
Labels: multi-theatre

The stars payload carries `region` and `has_hub`; the local `stars` table has a column for neither, so the app cannot see a System Hub or a region even once one exists. Travel carries `hub_bonus` and the preview never shows it. Independent of every other ticket — it can run first or last.

**Files:**
- Modify: `app/Modules/GameModels/Sources/Star.swift`
- Modify: `app/Modules/GameDatabase/Sources/GameDatabase.swift` (append two migrations)
- Modify: `app/Modules/GameServices/Sources/StarsClient.swift` and the stars ingestion path
- Modify: the travel preview sheet in `TravelUI`
- Test: `app/Modules/GameServices/Tests/StarIngestionTests.swift` (extend, or create if absent)

**Interfaces:**
- Produces: `Star.region: String?`, `Star.hasHub: Bool`.

**Payload facts, confirmed against `app/Modules/API/Sources/openapi.json`:** both `app_schemas_stars_StarListResponseSchema`'s star and the catalogue star carry `has_hub: boolean` and `region: string?`. Travel carries `hub_bonus: boolean?` on its response alongside `route` and `total_time_seconds`. `has_hub` is non-nullable in the list schema and `region` is nullable — mirror that exactly (`hasHub` non-optional with a `DEFAULT 0`, `region` optional).

---

- [ ] **Step 1: Write the failing test**

Extend the stars ingestion tests with a case that decodes a payload carrying `region: "Perseus"` and `has_hub: true` and asserts both reach the row:

```swift
@Test("Region and hub flag survive ingestion")
func regionAndHubIngested() async throws {
    let database = try starsDatabase()
    try await ingest(starsFixture(designation: "DENEBED", region: "Perseus", hasHub: true),
                     into: database)

    let star = try await database.read {
        try Star.where { $0.designation.eq("DENEBED") }.fetchOne($0)
    }
    #expect(star?.region == "Perseus")
    #expect(star?.hasHub == true)
}

@Test("A star with no region ingests as nil rather than empty")
func absentRegionIsNil() async throws {
    let database = try starsDatabase()
    try await ingest(starsFixture(designation: "SOL", region: nil, hasHub: false), into: database)

    let star = try await database.read {
        try Star.where { $0.designation.eq("SOL") }.fetchOne($0)
    }
    #expect(star?.region == nil)
    #expect(star?.hasHub == false)
}
```

Follow the existing ingestion-test idiom in `GameServices/Tests` rather than inventing fixture helpers.

- [ ] **Step 2: Run and confirm it fails**

```bash
cd app/Modules && swift test --filter StarIngestionTests --event-stream-output-path /tmp/t11.json
```

- [ ] **Step 3: Add the columns and two separate migrations**

Two migrations, not one — each `ALTER TABLE` is its own `SchemaMigration`, appended to the END of `manifest`:

```swift
    public static let addStarRegion = SchemaMigration("Add 'region' to 'stars'") { db in
        try #sql(
            """
            ALTER TABLE "stars" ADD COLUMN "region" TEXT
            """
        )
        .execute(db)
    }

    public static let addStarHasHub = SchemaMigration("Add 'hasHub' to 'stars'") { db in
        try #sql(
            """
            ALTER TABLE "stars" ADD COLUMN "hasHub" INTEGER NOT NULL DEFAULT 0
            """
        )
        .execute(db)
    }
```

- [ ] **Step 4: Carry the fields through ingestion**

Map `region` and `has_hub` from the generated `Components.Schemas.*` star types onto the row in `StarsClient` and wherever the catalogue ingests. Both list and catalogue responses carry them; miss one and a star's flag flips depending on which endpoint last wrote it.

- [ ] **Step 5: Show `hub_bonus` on the travel preview**

`hub_bonus` is a response field, not a persisted row, so this is display only. Surface it on the travel preview sheet in `TravelUI` beside the existing route and duration — a hub-assisted leg is up to 25% faster and the operator currently has no way to see that it applied.

- [ ] **Step 6: Regenerate fixtures, run the suite, commit**

```bash
cd app/Modules && RC_REGENERATE_SCHEMA_FIXTURE=1 swift test --filter GoldenSchemaTests --event-stream-output-path /tmp/t11-schema.json
cd app/Modules && swift test --event-stream-output-path /tmp/t11-all.json
cd /Users/matt/Developer/replicant-macos && ./app/scripts/check-comments.sh app/Modules/GameModels/Sources/Star.swift
git add -A
git commit -m "feat(theatre): ingest star region and hub flag; show travel hub bonus"
```

Add both new identifiers to `SchemaManifestTests`' frozen list.
