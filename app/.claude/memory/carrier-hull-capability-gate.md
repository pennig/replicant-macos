---
name: carrier-hull-capability-gate
description: "The 2026-08-07 racing-vessel incident: brain carrier selection is now capability-based (Device.isCarrierHull = cradle+surge), never a deviceType match"
metadata:
  type: project
---

The 2026-08-07 live incident: the operator moved `auto:tendmesh` from the HEAVEN
Vessel to a `racing_vessel` (new replicant aboard, relay already stowed) and the
brain reported "no vessel at AINALRAM-BELT-1 is tagged auto:tendmesh". Root cause:
`Brain.carrierDeviceType = "heaven_vessel"` gated every carrier site on device
TYPE before the tag check, so the tagged vessel never entered the candidate list
and the blocker misattributed a type exclusion to tagging.

Fix: `Device.isCarrierHull` (`cradle` + `surge` features), the same
capability-not-type convention as `isPrintHub`. Calibration against the
2026-08-07 fleet: the pair picks exactly {heaven_vessel, racing_vessel} —
`matrix_container` has cradle but no surge (would strand on an interstellar
leg), `surge_plate` has surge but no cradle, freighters/haulers have neither.
The two hulls' feature sets are byte-identical, so nothing about the job needed
the HEAVEN type. All six Brain gate sites swapped, including `restockHost`'s
EXCLUSION (a racing vessel was eligible to become the restock host, which would
have reserved it out of the fleet permanently) and the survey/salvage carrier
gates, which had the identical latent wall.

Review round added the diagnostics half: every blocker now names a MISTAGGED
device (tag on a non-carrier hull) fleet-wide — not hub-scoped, because a stowed
device has `location: nil` (see [[location-scope-cannot-see-stowed]]) and the
remedy (move the tag) is location-independent. Fixture consequence: test
carriers must carry real feature sets; `deviceFixture` resolves features by
type via `fixtureFeatures(for:)` (explicit `[]` stays featureless) and its
default-tag rule keys on carrier-shaped features, not the type string.
