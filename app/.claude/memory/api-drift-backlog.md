---
name: api-drift-backlog
description: Known open OpenAPI spec-drift issues to patch in openapi.json (with the failing tests that prove them)
metadata: 
  node_type: memory
  type: project
  originSessionId: acf63055-6a9a-4ae6-b6f4-c4d5ed6f2b46
---

Running backlog of confirmed OpenAPI spec/server drift. The [[decode-diagnostics-decorator]] now logs each decode failure (subsystem `name.pennig.replicould.api`, category `decoding`) with its exact coding path, so new drifts surface precisely. Fix pattern = add the missing typed key to `Modules/API/Sources/openapi.json` (prefer a typed `$ref`/property over `additionalProperties:true`), same as [[location-response-schema-drift]]. Re-apply after any spec re-fetch — see [[openapi-spec-drift-leniency]], [[openapi-spec-layout]].

**Open:** none known. As of 2026-07-20 `swift test` is fully green (GameServices bundle = 121 tests, all suites pass).

**Latent (watch, not a current drift):** generated `Date` fields (e.g. `DeviceStatusSchema.created_at`) decode via OpenAPIRuntime's default ISO8601 transcoder — **no fractional seconds**. If the server ever emits fractional-second timestamps in a `date-time` field, the whole payload fails to decode (unlike `Replicant.created_at`, a string field with `parseTimestamp` tolerance). DiagnosticAPIClient would log it loudly; the fix would be a custom `DateTranscoder` on the generated client. Noted 2026-07-21 while adding GameModelsTests. Both formerly-listed failures now pass:

1. ~~`post/v1/devices/{device_code}` rejects `new_resource`~~ — RESOLVED. `retargetIsImmediateWithResource` passes (the device-command response schema now decodes `new_resource`).
2. ~~`CommandClientTests.terminatingCommandClosesOpenOp`~~ — RESOLVED. Passes; the terminating command now closes the open op as expected.

**Fixed this session:** `CommandClientTests.adoptSendsDevicesAndIsImmediate` was failing (`readCount == 1` but got 2). This was a **stale test, not a code bug** — `CommandClient.dispatch` (the immediate path) was enhanced so topology commands (attach/detach/adopt/release) also refresh each device named in the response's `affectedDeviceCodes` block, not just the primary device. `adopt` therefore reads the controller *plus* the adopted device. Test updated to assert the exact read order (`["18CA7C99", "32658E70"]`) instead of a bare count.

**Applied patches to re-apply after a spec re-fetch:**

- **`post/v1/devices/{device_code}` needs a `201` response.** The `replicate` command returns **201 Created** (per docs), but the spec only declared `200` + `default`, so the generated client routed success to `.default` (a decode-as-error path). Added a `"201"` response mirroring the `200` `DeviceCommandResponseSchema` in the active `-edits` spec (`openapi.json` currently symlinks `openapi-2.3.3-edits.json`) so the client gets a `.created` case. `CommandClient` handles `.created` defensively (unreachable there); `ReplicantsClient.replicate` reads the new-replicant identity from `.created`/`.ok`. See [[replicants-feature]]. Never live-probe `replicate` (POST) — it permanently creates a replicant on the one live account.
