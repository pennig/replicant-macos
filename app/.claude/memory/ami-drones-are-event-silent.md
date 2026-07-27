---
name: ami-drones-are-event-silent
description: "AMI-managed survey drones emit ZERO per-device SSE events — every movement is rolled up into the controller's ami.*.digest — so their stow/location columns only change when something explicitly reads them"
metadata:
  node_type: memory
  type: reference
---

**A device adopted by an AMI controller emits no per-device events of its own.**
Verified over the full 11.5-hour `eventLogs` window on 2026-07-27: the six survey
drones controlled by `B2CBDEC6` (`416059AA`, `71AF5FE8`, `7487448E`, `89C1A6EF`,
`A1D08194`, `A697D0E8`) account for **zero** rows — not one `device.deployed`,
`device.stowed`, `travel.departed` or `travel.arrived` — across two full surveys
in which they were deployed and recalled six at a time. Every one of those
movements appears only as a *count* inside the controller's `ami.survey.digest`
(`{"counts": {"scan.started": 3, "travel.arrived": 3}}`). The controller itself
does emit its own `device.stowed`/`device.deployed`.

**Consequence, and it is the load-bearing one:** the `StalenessTracker.markStale`
→ `.low` drain path is event-driven, so an adopted drone is *never marked stale*
and its row only changes when something explicitly reads it. A drone left in
another system keeps claiming `stowedInDeviceCode = <vessel>` indefinitely. This
is worse than the budget-deferral problem in
[[staging-freshness-vs-read-budget]] — that one was a delayed read, this is no
read at all.

Two things follow, both now built:

- **Never wait on a drone row to change by itself.** `SurveyRun.recover` probes
  after `recallProbeDelay`, then waits out the farthest traveller's OWN
  `arrives_at` (`recallArrival`), re-probing only once that passes and never more
  often than `recallProbeInterval`. Polling on the engine's 5s tick would be a
  read storm for a fact that cannot change without a read anyway.
- **Never trust a positive containment claim from an unread row.** `preflight`'s
  `stagingFreshness` check exists for exactly this.

**A drone's ETA is readable from the LIST payload** (probed 2026-07-27), and the
engine now uses exactly this via `MissionAction.refreshDevicesInSystem` →
`DevicesClient.fetchAtLocation`:

- `GET devices?location=<STAR>` scopes to a whole system, and the filter matches
  **sub-locations** (`location=ASTELLIO` returns devices at `ASTELLIO-1-L4`), so
  one request returns a vessel, its controller and its drones together.
- **In-transit devices are included.** A travelling device reports
  `location: null` yet is still matched to the system — verified with `1A403F86`
  (cruising, `location: null`) appearing under `location=ATIANFU`. This is the
  fact the whole approach rests on: the drones worth waiting for are the ones in
  flight.
- Unlike `controlled_devices`, the **`travel` block IS present in list entries** —
  full `arrives_at` / `final_arrives_at` / `route`.
- `limit` caps at 50 ([[paged-endpoint-maxima]]), so a system read is one request
  until a system holds 50+ devices.

Cost: one request per probe instead of one per device (8 → 1 for a six-drone
recall), and it does not scale with fleet size. A whole-fleet walk would too,
but only until ~350 devices; a scoped one never degrades.

**Never follow `fetchAtLocation` with `Reconciler.pruneDevices`.** A scoped walk
is not the authoritative full fleet — every device outside the scope is absent by
construction, so pruning on it would delete the fleet. `fetchAll` is a pure read
and callers prune explicitly, which is what keeps this safe.

**The trap that cost 5.5 hours of stall (2026-07-27):** `MissionAction.refreshDevices`
expands each named device into *that carrier's* `stowed_devices` blob — and that
blob is **not** a reliable inverse of the children's `stowedInDeviceCode`
columns. Live vessel `F2908E6E` reported `stowed_devices:
[{"device_code":"60160672","device_type":"replicant_matrix"}], stow_used: 1`
while six drones and a controller all claimed to be stowed aboard it. A check
that judges rows the request does not NAME can therefore never be satisfied.
**Always name every device a freshness check covers.**

The one free signal about a launch is **`ami.launched`**, which carries
`devices_deployed` — the server saying plainly whether the launch did anything.
`DirectiveIngestion.amiLaunchRoute` consumes it (matched by exact event name, not
by the `ami` category, which is otherwise hundreds of digests an hour: 781
`ami.transport.digest` in that same window).

See [[directives-feature]] and [[controlled-devices-detail-only]] (the other half
of why adoption is hard to observe).
