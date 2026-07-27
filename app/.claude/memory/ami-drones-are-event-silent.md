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

- **Never wait on a drone row to change by itself.** `SurveyRun.recover` waits
  out `recallGrace` doing nothing and *then* pays for one `.high` read round.
  Polling on the engine's 5s tick would be a read storm for a fact that cannot
  change without a read anyway.
- **Never trust a positive containment claim from an unread row.** `preflight`'s
  `stagingFreshness` check exists for exactly this.

The one free signal about a launch is **`ami.launched`**, which carries
`devices_deployed` — the server saying plainly whether the launch did anything.
`DirectiveIngestion.amiLaunchRoute` consumes it (matched by exact event name, not
by the `ami` category, which is otherwise hundreds of digests an hour: 781
`ami.transport.digest` in that same window).

See [[directives-feature]] and [[controlled-devices-detail-only]] (the other half
of why adoption is hard to observe).
