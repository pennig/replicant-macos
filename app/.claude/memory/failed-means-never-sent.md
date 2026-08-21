---
name: failed-means-never-sent
description: "`OperationStatus.failed` is a claim that the request never reached the server, and the governor's dedup relies on it — so a response-DECODE failure must record `.unknown`, because the command already took effect"
metadata:
  node_type: memory
  type: reference
---

`CommandGovernor`'s dedup predicate excludes exactly one status:

```swift
&& $0.status.neq(OperationStatus.failed)
```

Every other status blocks a repeat inside the step entry. So `.failed` is not a
generic "it went wrong" — it is a **licence to re-POST**, and anything recorded
under it must genuinely never have left.

`CommandClient.dispatchOwned`'s catch block used to record every thrown dispatch
as `.failed`, its comment reading "Network / encoding error — not a server
rejection. No retry." The governor read the same row and concluded the opposite.
Both could not be right, and the one that acted won.

## What a decode failure actually is

A body the generated client cannot decode throws AFTER the round trip. The
request was sent, the server acted, and only the reply was unreadable. Re-POSTing
walks into a world that has already moved.

`CommandClient.throwStatus` splits them on `ClientError.response`, which the
runtime documents as nil "if the error resulted before the response was
received":

```swift
(error as? ClientError)?.response == nil ? .failed : .unknown
```

`.unknown` is terminal (not in `OperationStatus.openCases`), so it does not wedge
the `operation_one_active_per_device` index, and being non-`.failed` it blocks
the duplicate for free. The CALLER still hears `.failed(reason)` — the dispatch
did not succeed — so only the durable row carries the distinction.

## The live failure this came from (2026-08-21)

Survey run `0DB23EC5`, two travel ops six seconds apart:

- `409736A6` **failed** — `DecodingError.dataCorrupted: Path: hub_bonus.
  Additional properties are disabled, but found 1 unknown keys`
- `643AB4B1` **rejected** — `Device is not in a star system`, because the first
  travel HAD departed

The run stalled `commandRejected` and sat 3 hours. `hub_bonus` was real drift:
declared on `app_schemas_travel_TravelResponseSchema` but not on
`app_schemas_devices_DeviceCommandResponseSchema`, which is what
`POST /v1/devices/{device_code}` returns. Patched per
[[openapi-spec-drift-leniency]] — a typed key added, `additionalProperties`
left `false`.

**Fixing the spec is not the fix.** It retires one key; the next undeclared field
does the same thing. `throwStatus` is what makes the class survivable, which is
why the regression test uses a key the server will never send — declaring the
real one would silently retire the test.

Same family as the double-dispatch in
[[transport-events-carry-the-hold]] and the retry gating in
[[same-step-dispatch-needs-tracked-op]]. `Path:` naming the rejected key is
recorded in [[survey-run-owns-the-system-scan]].
