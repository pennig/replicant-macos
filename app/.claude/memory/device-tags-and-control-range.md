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

`tags` is **already decoded and persisted** on `Device` (JSON column). Five surge plates are already
tagged `taxi` in production, so the mechanism is in live use — just never for automation.

Follow-up worth taking: Survey Run's `recovering` step waits out a blind 5-minute `recallGrace`
*because* adopted drones are event-silent and a location read cannot see a stowed one. The tag
endpoint removes both halves, so that step can become a single confirming read. (v2.3.3 also now holds
`directive.completed` until a recall-configured directive's drones finish travelling, which removes
the other reason for the wait.)

## `in_control_range`

A `Bool` on every device in both `DeviceListItemSchema` and `DeviceStatusSchema`. **Already in
`openapi.json`, already decoded by the generated client, and read by nothing in the app's own `Device`
model.** It is the server's own answer to whether a device is commandable right now — see
[[ftl-authority-rule]] for the rule it encodes.

Surfacing it is one append-only `ALTER TABLE` migration, and it turns the directives spec's
"reachability is a precondition on every dispatch" from geometry the app infers into a fact it reads.
Treat `nil` as **not yet read**, never as unreachable.
