---
name: location-response-schema-drift
description: "openapi.json patch so GET locations/{designation} decodes (asteroid_belt drift) — re-apply after re-fetch"
metadata: 
  node_type: memory
  type: project
  originSessionId: acf63055-6a9a-4ae6-b6f4-c4d5ed6f2b46
---

`GET /v1/locations/{designation}` (the shared `LocationsClient.system()`/`body()` path) was silently failing for star-locations: the spec schema `app_schemas_locations_LocationResponseSchema` is `additionalProperties: false` and declares `belt` but NOT `asteroid_belt`, while the server sends `asteroid_belt` at the star level. So the generated strict decode (`try ok.body.json`) threw BEFORE `LocationDecoding.reinterpret` (which tolerates unknowns) ever ran → `system()` threw → nothing persisted. Symptom: systems only reachable via GET (e.g. SOL — remote, never scanned in place) never hydrated (no `systemDetails` row, orrery shows zero planets), while systems scanned in place (POST scan path) worked.

**Why:** unit tests decode `RawLocation` directly (bypassing the generated `ok.body.json`), so they passed while the real app path failed — a blind spot.

**Fix (typed, not a catch-all):** added the missing property to `app_schemas_locations_LocationResponseSchema.properties` — `"asteroid_belt": {"$ref": "#/components/schemas/app_schemas_scanning_AsteroidBeltSchema"}` (that schema `{present, belts}` already exists and the SCAN response uses the same ref). Kept `additionalProperties: false`, so genuinely-unexpected drift still fails loudly. It's optional (the schema has no `required`), so planet/moon locations (no asteroid_belt) still decode. Net spec diff = 3 added lines. Preferred over `additionalProperties:true` (user's call: honest schema > silent bag). Same class as [[openapi-spec-drift-leniency]] — **RE-APPLY after any openapi.json re-fetch**.

Regression guard added: `UniverseModelsTests.generatedLocationDecodeToleratesStarAsteroidBelt` decodes a star payload through the GENERATED `Components.Schemas.AppSchemasLocationsLocationResponseSchema` + `reinterpret` + `starSystem()` — the real production path (other tests decode `RawLocation` directly and missed this). If the spec re-strictens, this test fails loudly.

To diagnose future recurrences: validate a live payload against the spec schema (walk `additionalProperties:false` + required — a Python walk found `asteroid_belt` in seconds), or check the [[sqlite-db-location]] `systemDetails` table for missing rows.

Decode-drift logging: `API/Sources/Middleware/DecodingDiagnostics.swift` — `DecodingDiagnostics.capture("opID") { … }` wraps a client call and, on a response-body decode failure, logs the exact codingPath + reason (unwrapping `ClientError.underlyingError` → `DecodingError`). Wired into `LocationsClient` system/body/scan; adopt at other client boundaries as needed. NOTE a `ClientMiddleware` CANNOT do this — decode happens after middleware returns; `LoggingMiddleware` only logs the raw body. Read it: Console.app / `log stream` subsystem `name.pennig.replicould.api`, category `decoding` (the field) + `http` (the raw body) — that pair is what to send the backend dev.
