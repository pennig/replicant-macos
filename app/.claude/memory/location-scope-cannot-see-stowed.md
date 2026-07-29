---
name: location-scope-cannot-see-stowed
description: "A location-scoped device query cannot see a STOWED device (stowing clears location), so a gate whose success condition is 'stowed' has its evidence erased by the very thing it waits for"
metadata:
  node_type: memory
  type: reference
---

**The rule.** `GET devices?location=<designation>` answers **presence**, and
stowing a device **clears its location**. So a stowed device is absent from that
response entirely — it is not stale data, it is out of scope. Containment
questions must name the device (`GET devices/{code}`) or use the unfiltered fleet
list; both report `stowed_in_device_code` wherever the device is.

Note the asymmetry that makes this easy to get wrong: an **in-transit** device
also reports `location: null` yet the server still matches it to the system
(probed 2026-07-27). So the filter *does* return devices with no location — just
not stowed ones. "It returns in-transit devices" is not evidence that it returns
everything.

**The failure it caused (live, 2026-07-29 21:44 → 22:05, ESELLUSAU).** A Survey
Run sat in `recovering` forever with every drone already safely home.
`SurveyRun.recover` gated on each drone's own `stowedInDeviceCode` column but
probed with `.refreshDevicesInSystem` — so:

1. The recall completed; all six drones stowed aboard vessel `F2908E6E`,
   `location` → null.
2. `GET devices?location=ESELLUSAU` returned **exactly one row**, the vessel.
   The unfiltered fleet list returned all six with correct stow columns — proof
   that scope, not staleness, was the problem.
3. `resolveSystemRefresh` deliberately prunes nothing, so the six absent rows
   kept their pre-recall values (`location: ESELLUSAU-2-2`, `stowedIn: NULL`).
4. `stranded` was therefore never empty → never `.advanceTarget`.
5. Worse, the probe throttle keys on `stranded.map(\.updatedAt).min()` — the
   rows the probe never writes — so `lastLook` never advanced and the probe
   re-fired **every tick** (the user's symptom: repeated device requests at
   ESELLUSAU) until `recallDeadline` surfaced `dronesNotRecovered` over a fully
   recovered fleet.

**The fix.** `recover` now returns
`.refreshDevices(deviceCodes: stranded.map(\.deviceCode), thenStall: nil)`.
`resolveRefresh` reads each named code directly, which is what repairs the rows
the gate reads — and incidentally makes the throttle work, since those rows now
get written.

The reasoning the old code was built on ("a system scope names nothing, so it
can miss nothing") conflated *naming a carrier and relying on its
`stowed_devices` expansion to reach the children* with *naming the children
themselves*. Only the former is unreliable — the expansion is an addition to the
per-code reads, not the mechanism. `MissionAction.refreshDevices`' own docs
already said **"name every device the answer depends on"**, and preflight's
staging check already did exactly that (see
[[staging-freshness-vs-read-budget]]).

**Why nothing self-heals here.** Adopted drones emit no per-device events at
all, so their columns move only when something explicitly reads them — see
[[ami-drones-are-event-silent]]. That is what makes "which read do I spend"
load-bearing rather than a mere optimisation.

**Manual unblock for a run already stuck in this state:** Devices screen ▸
Refresh (`devicesClient.fetchAll()`, a full fleet walk that bypasses the read
budget and *does* include stowed rows), then Retry if it has already stalled.

`.refreshDevicesInSystem` remains in `MissionAction` as a tested presence-query
capability with no production caller; its docs now carry the stowed blind spot.
See [[directives-feature]] and [[controlled-devices-detail-only]].
