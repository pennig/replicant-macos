---
name: openapi-operation-id-format
description: "Runtime operationIDs are synthesized method/path strings (get/v1/stars), NOT Swift method names — match middleware against Operations.X.id"
metadata:
  type: project
---

The spec has no `operationId`s, so swift-openapi-generator synthesizes each
operation's `id` as a `method/path` string: `Operations.GetV1Stars.id ==
"get/v1/stars"`. That string — not the Swift method name `getV1Stars` — is what
the runtime passes to `ClientMiddleware.intercept(..., operationID:)` and embeds
in `ClientError` descriptions.

**Why:** `RateLimitMiddleware`'s stars special-case originally tested
`operationID == "getV1Stars"`, which never matched — so `GET /v1/stars`'s
dedicated `limit: 1 / remaining: 0` headers were recorded into the shared
`reads` bucket, zeroing the app's read budget for ~60s (and clamping its refill
limit to 1, which can wedge `acquire` behind `reserve`). Symptom: first-run star
catalogue loads left the map stuck "waiting on the rate limit" during the
follow-up per-replicant overlay walk.

**How to apply:** in middleware (same module as the generated code), compare
against the generated constant (`operationID == Operations.GetV1Stars.id`),
never a hand-typed name. `RateLimitMiddlewareTests` pins both the routing and
the literal `"get/v1/stars"` format. See [[api-module-name]].
