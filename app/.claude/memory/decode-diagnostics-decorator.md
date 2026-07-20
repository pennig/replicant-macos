---
name: decode-diagnostics-decorator
description: "OpenAPI response-body decode errors are logged centrally via an APIProtocol decorator, not per call site"
metadata: 
  node_type: memory
  type: project
  originSessionId: acf63055-6a9a-4ae6-b6f4-c4d5ed6f2b46
---

Decode-error (spec/server-drift) logging for the generated OpenAPI client is centralized in **one** place: `DiagnosticAPIClient` (API/Sources/Middleware/), a transparent `APIProtocol` decorator whose ~74 methods (grows as the spec adds operations) each forward to a wrapped client through `DecodingDiagnostics.capture(operationID:)`, which logs the exact `DecodingError` coding path and rethrows unchanged.

**Why not middleware:** a `ClientMiddleware` wraps the byte transport and runs BEFORE the typed-body decode, so it can't see `DecodingError`. The decorator sits above the generated `Client` where the decode actually throws.

**How to apply:**
- `GameClient.make()` / `ReplicantSpace.client(...)` return `any APIProtocol` (a `DiagnosticAPIClient` wrapping `Client`), so call sites are unchanged — never add per-call `DecodingDiagnostics.capture` wrappers.
- Logs go to subsystem `name.pennig.replicould.api`, category `decoding`.
- If the API surface changes, regenerate the decorator: `swift build --target API` then `python3 scripts/gen-diagnostic-client.py` (run from `Modules/`). It parses the generated `APIProtocol` from Types.swift and rewrites the file 1:1; a stale copy just fails to compile.
- **GOTCHA (hit on the 2.1.1 upgrade):** the script reads `Types.swift` under `Modules/.build`, but an Xcode/`BuildProject` build generates into DerivedData and does NOT refresh `Modules/.build`. So after a spec change you MUST run `swift build --target API` first — otherwise the script regenerates against a stale protocol (e.g. missing the new `getV1Achievements` ops) and the decorator still won't conform. Sequence that works: `swift build --target API` (refreshes .build, may itself fail on the stale decorator — that's fine) → `python3 scripts/gen-diagnostic-client.py` → BuildProject.
- When a drift is logged, the real fix is patching `openapi.json` (add the missing typed key), same pattern as [[location-response-schema-drift]] / [[openapi-spec-drift-leniency]].
