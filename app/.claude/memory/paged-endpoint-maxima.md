---
name: paged-endpoint-maxima
description: "Paged endpoints cap at 100 (devices at 50); over-asking is silently clamped and openapi.json documents no maxima — always request the max"
metadata:
  node_type: memory
  type: reference
---

**Rule: every paged request sends the endpoint's maximum `limit`.** Fewer
round-trips against the reads budget, and the constant at the call site then
matches what actually arrives.

Measured against the live API 2026-07-26 by requesting 50 / 100 / 200 / 1000 and
counting what came back:

| Endpoint | Max | Notes |
|---|---|---|
| `GET devices` | **50** | Lower than everything else. Per operator. |
| `GET events` | 100 | 200 and 1000 both return exactly 100 |
| `GET replicants` | 100 | same |
| `GET messages` | 100 | same |
| `GET devices/{code}/messages` | 100 | the one maximum the spec documents |
| `GET accounts/events` | assumed 100 | account has too few rows to measure |

Two traps:

1. **Over-asking is silently clamped, never rejected.** `?limit=1000` returns
   100 with no error and no warning, so an oversized constant looks like it
   works. `LocationEventsClient.pageSize` was 200 with a comment claiming the
   endpoint capped there; it had never fetched more than 100.
2. **`openapi.json` documents almost no maxima** — only
   `devices/{device_code}/messages` carries `maximum: 100`. Every other paged
   parameter has a `default` and no `maximum`, so the spec cannot be used to
   pick a page size. Measure, or ask. See [[openapi-spec-drift-leniency]].

Also note the **default is 20**, which is what you get from a bare
`replicant raw GET devices` — easy to mistake for the whole collection when
probing. Always pass an explicit `limit` and follow `next_cursor` when probing a
fleet-sized endpoint; a truncated probe once led to a wrong conclusion about the
state of the fleet.
