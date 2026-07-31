---
name: device-tags-and-control-range
description: "GET devices/tags/{tag} is the missing primitive: a fleet-wide list filtered by tag, so it sees STOWED and TRAVELLING devices that ?location= structurally cannot. Carries in_control_range, already in openapi.json + generated client but read by nothing. Fixes the two incidents that cost Survey Run a fleet and ten hours."
metadata:
  type: reference
---

Probed live 2026-07-30. Two facts that were sitting in plain sight.

## `GET /v1/devices/tags/{tag}`

"List all owned devices matching a tag, with full device status." Returns the **fleet-wide** list
filtered by tag, carrying `stowed_in_device_code`, `controller_device_code`, `attached_devices`,
`available_commands`, `features`, `status`, `location` and `in_control_range`. Confirmed to return
`travelling` devices (with a null `location`). `GET /v1/devices` also accepts `?tag=` and
`?untagged=`.

**Why this matters more than it looks.** Because it filters on *tag* rather than *location*, it is
structurally immune to the trap documented in [[location-scope-cannot-see-stowed]]: stowing **clears**
a device's location, so `GET devices?location=X` answers presence and can never see a device aboard a
vessel. That single gap is behind both of the directive engine's expensive incidents — a Survey Run
frozen in `recovering` for 20 minutes re-probing drones that were already aboard, and a run that lost
its whole drone complement because a stale row read as "still aboard" ([[staging-freshness-vs-read-budget]],
[[ami-drones-are-event-silent]]).

A tag query gives a mission a **reliable roster of its own devices regardless of idle / travelling /
stowed**. Any automation that needs to answer "where is my fleet" should resolve by tag, not by
location probe.

**Proved on live data 2026-07-30**, against the continuous survey run's fleet tagged `auto:survey`,
caught mid-flight with the drones stowed aboard a travelling vessel:

```
code       type                   status       location  stowed_in  in_control_range
F2908E6E   heaven_vessel          travelling   null      null       false
B2CBDEC6   ami_survey_controller  stowed       null      F2908E6E   true
A697D0E8   survey_drone           stowed       null      F2908E6E   true      (x6 drones)
```

All eight came back in ONE request. **Every one has a null location** — the vessel because it is in
transit, the rest because stowing clears it — so a location-scoped query has nothing to query by and
returns an empty set for this fleet. Containment (`stowed_in_device_code`) survives intact. A tag
containing a colon needs no encoding.

**`in_control_range` is per-device and reflects transit, not just mesh membership**: `false` on the
travelling vessel, `true` on the cargo stowed inside it. So a device in flight reports out-of-range as
a matter of course. Never gate a mission on the *mover's* range flag — a freighter merely en route
would read as unreachable. Gate on the destination, or on the fleet's settled members.

`tags` is **already decoded and persisted** on `Device` (JSON column). Five surge plates are already
tagged `taxi` in production, so the mechanism is in live use — just never for automation.

Follow-up worth taking: Survey Run's `recovering` step waits out a blind 5-minute `recallGrace`
*because* adopted drones are event-silent and a location read cannot see a stowed one. The tag
endpoint removes both halves, so that step can become a single confirming read. (v2.3.3 also now holds
`directive.completed` until a recall-configured directive's drones finish travelling, which removes
the other reason for the wait.)

## `in_control_range`

A `Bool` on every device in both `DeviceListItemSchema` and `DeviceStatusSchema`. It is the server's
own answer to whether a device is commandable right now — see [[ftl-authority-rule]] for the rule it
encodes.

**It is already wired up, and no migration is needed.** `Device.inControlRange` is a computed property
over the `detail` blob (`detail["in_control_range"]?.boolValue`), with `isOutOfControlRange` beside it;
`SchemaMappingTests` and `DeviceActivityTests` cover both, and `DevicesFeature/CommandGrid` already
disables commands on an out-of-range device. A mission can read it today.

Two things worth knowing anyway:

- It **survives a list sync**, unlike `controlled_devices` ([[controlled-devices-detail-only]]),
  because `in_control_range` is on the *list* schema too — so the `detail` rewrite that erases the
  one leaves the other intact.
- Treat `nil` as **not yet read**, never as unreachable. `isOutOfControlRange` already encodes that
  asymmetry (a missing field is not "out of range"), so prefer it to `inControlRange == false`
  spelled out by hand.

Recorded because the 2026-07-30 salvage design initially specced an `ALTER TABLE` for this off a
`grep` truncated by `head` — the field looked generated-but-unused when it was neither.
