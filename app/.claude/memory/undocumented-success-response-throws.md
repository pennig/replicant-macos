---
name: undocumented-success-response-throws
description: "An operation documenting only `default` decodes its 200 against the STRICT error schema, so every success throws — found on POST locations/{code}/events/{designation} (2026-07-30)."
metadata:
  node_type: memory
  type: project
---

Under this repo's strict-spec policy ([[openapi-spec-drift-leniency]]), an operation whose
`responses` block declares **only** `default: DEFAULT_ERROR` is not merely under-documented — it is
**broken on the success path**.

swift-openapi-generator's deserializer decodes the body **eagerly**, before returning the `Output`
case. With only a `default` response there is no 200 branch, so a successful reply is decoded as
`flask_smorest_error_handler_ErrorSchema` — which is `additionalProperties: false` and knows only
`code` / `status` / `message` / `errors`. Any real success payload therefore throws
`DecodingError.dataCorrupted … Additional properties are disabled, but found N unknown keys`.

Nothing in the Swift call site can rescue this. The old `LocationEventsClient.complete` looked safe
because it only read the body in its failure branch — but the decode has already happened by then.

**Found on** `POST /v1/locations/{location_code}/events/{designation}` (2026-07-30). Resolving a
location event really returns
`{designation, event_status, rewards, status, title}` — four keys unknown to the error schema — so
**every successful quest completion surfaced to the player as a failure**. Fixed by declaring
`app_schemas_location_events_LocationEventResolutionResponseSchema` and a `200` on the operation in
`openapi-2.3.3-edits.json`, then handling `.ok` in the client.

**How to spot the rest:** a `switch output` with a single `case .default(statusCode, …)` that
range-checks for 2xx is the tell — it means the spec documents no success response for an operation
that plainly has one. Or scan the `-edits` file for operations whose `responses` object has
`default` as its only key.

That scan on 2.3.3 (2026-07-30) finds **nine** besides the fixed one — `GET /v1/health`, the three
`devices/{code}/permissions` verbs, the three `devices/{code}/trades*` verbs,
`GET /v1/replicants/{code}/traders`. **None is called from app code today** (only the generated
decorator names them), so they are latent rather than live. Anyone wiring one of these up must
declare its 200 first, or the very first successful call will throw.

**2.5.0 (2026-08-10) added two more, and they were caught by reading the upgrade diff rather than by a
throw:** `GET /v1/tutorials` and `GET /v1/tutorials/{slug}` both shipped `default`-only. Live probes
confirm real 200 bodies (a `tutorials` array of seven; a detail with `steps[]`), so both were patched
with a declared 200 in `openapi-2.5.0-edits.json` — see [[openapi-spec-layout]]. Re-running the scan
on `openapi-2.5.0-edits.json` still finds exactly the same **nine** latent operations listed below,
none of them called from app code. **Make the scan a standing step of every spec upgrade**: a
`default`-only block on a NEW path is free to fix at upgrade time and expensive to find later, since
the endpoint fails only for whoever first wires it up.

**How to test it** without POSTing to the live account (which mutates real game state — see the
`probe-api` skill): drive the generated client with a canned `ClientTransport` returning the real
200 body, as `GameServices/Tests/LocationEventsClientTests.swift` does. That test also guards the
declared schema: drop a key from it and the strict decoder fails the test.

Related: [[openapi-spec-layout]] for where the `-edits` files live, [[decode-diagnostics-decorator]]
for how such a throw gets logged with its coding path.
