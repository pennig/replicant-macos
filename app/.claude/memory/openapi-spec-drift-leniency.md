---
name: openapi-spec-drift-leniency
description: "POLICY (2026-07-09): keep the OpenAPI spec STRICT — do NOT relax additionalProperties:false→true. Patch drift with targeted typed keys instead."
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 8ae05013-2f31-4ecd-8d38-f371eae04243
---

The user has resolved to **keep the `replicant.space` spec strict** and edit it with narrow, typed patches as drift is discovered, reporting issues upstream as they find them. Do **NOT** apply the old blanket `additionalProperties:false→true` relaxation — that approach is now explicitly rejected.

**Why:** strict decoders surface server/spec drift loudly (a decode throw, logged with its coding path via [[decode-diagnostics-decorator]]) instead of silently swallowing unknown keys. Each drift then gets a precise, documented fix in the spec. (Background: ~140 schemas use `"additionalProperties": false`, so swift-openapi-generator emits strict decoders that throw `DecodingError.dataCorrupted … Additional properties are disabled, but found N unknown keys` when the server sends undeclared keys.)

**How to apply when a drift throws:** add the specific missing key(s) with their real type to the offending schema in the `-edits` file — do not touch `additionalProperties`. See the carried-over patches on `openapi-2.1.1-edits.json`: `origin_name`/`travel_type` on the travel block, `new_resource` on device commands, `activated`/`deactivated`/`relay_active` on relay, and `asteroid_belt` re-pointed to a proper `$ref`. Same pattern as [[location-response-schema-drift]] / [[api-drift-backlog]].

Spec file layout (pristine + `-edits` + `openapi.json` symlink): see [[openapi-spec-layout]].

Related: the generator config (`openapi-generator-config.yaml`) must contain ONLY generator keys (`generate`, `accessModifier`, `namingStrategy`) — never OpenAPI-document keys, or the build fails with "Unknown configuration key found in config file". See [[api-module-name]].
