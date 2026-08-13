---
name: rate-limit-bucket-hygiene
description: "The two ways RateLimitGovernor mis-tracked a bucket — a foreign limiter's headers overwriting a shared bucket's limit, and min() being blind to the server's window refill — plus why the brain must report reads beside commands"
metadata:
  node_type: memory
  type: reference
---

`RateLimitGovernor` holds three buckets against the documented limits (docs/rate-limits/): **reads 120/min, actions 60/min, star catalogue 1/min**, plus four per-endpoint HOURLY limits that are all non-GET and therefore all land in `actions` — account registration 10/h, verification 30/h, webhook change 12/h, feedback 10/h. Every one of them is reported on the same `X-RateLimit-*` headers.

Two defects followed from that, both fixed 2026-08-13.

**1. A shared bucket's denominator was unpinned.** `record` assigned `state.limit` from the header unconditionally, so the brain's why-view flipped between "58 of 60" and "116 of 120" for one bucket — some non-GET response was reporting the reads limiter's numbers. The reading's `remaining` is equally foreign, so the fix REJECTS THE WHOLE READING (limit, remaining and reset together) when the header disagrees with the bucket's configured limit, and logs it. `State.pinnedLimit` carries that expectation and is **nil for `stars`**, deliberately: `stars` is one endpoint's private budget, nothing else can pollute it, and validating it would silently break the survey button's cooldown if the server ever retuned. Pin a bucket only when many endpoints share it.

**2. `min()` cannot see a refill.** `record` did `min(state.remaining, remaining)` and then overwrote `resetAt` — with no window-change detection. A bucket drained late in one window kept that drained count through the WHOLE of the next one, because the local refill in `acquire` fires only when the LOCALLY STORED `resetAt` passes, and each response kept pushing that stamp forward. The server had already handed the budget back and the app throttled itself against it anyway. Fix: a reset epoch strictly later than the stored one means the window rolled, and the server's `remaining` is taken at face value; inside one window `min` still holds, which is the out-of-order-response guard it exists for. The regression test for the second half (`withinOneWindowTheServerCanOnlyLowerTheCount`) matters as much as the fix.

The tell that this was real: with the fix stashed, `aRolledWindowUnblocksAcquireWithoutWaiting` made the API suite take **96 seconds instead of 1.2** — `acquire` blocking for a full window is the bug reproducing inside the suite.

**Why it surfaced as "the Devices refresh is slow".** A manual refresh is `DevicesClient.walk`, serial pages at `pageSize = 50`; at 445 devices that is 9 sequential GETs, each taking its own `acquire(.reads)`. A drained reads bucket parks the whole walk at the governor's `reserve` of 3. Meanwhile the brain's why-view read **`budget(.actions)` and nothing else**, so the surface showed command headroom while reads were the thing stalling. `BrainLimits` now carries `readsRemaining`/`readsLimit`/`readsFloor` and the why-view renders a second `.readGovernor` line beside `.commandGovernor` (the old `.governor` case, renamed — `kind` is the `Identifiable` id, so two lines cannot share one). `DeviceRefreshClient.readFloor` vends `PollCoordinator.defaultBudgetFloor` (12) the same way `CommandGovernorClient.actionFloor` vends the command one, so the surface states the number the coordinator enforces rather than a literal that could drift.

Not measured and still open: **which** non-GET endpoint reports `limit: 120`. Confirming it needs one POST captured with `curl -D-`, which was not run. The `.notice` log the mismatch now emits names the offending limit when it next happens.

See [[openapi-operation-id-format]] for the earlier instance of the same family — the `getV1Stars` operationID mismatch clamping the shared reads budget — and [[paged-endpoint-maxima]] for why the devices walk is 50 per page.
