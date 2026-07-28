---
name: survey-digest-scans
description: "ami.survey.digest report.scans[] (API v2.3.3) is the only channel carrying a Survey Run's per-body scan intel; the moons roster is a SIBLING of planet, and folding it in needs BodyObservation, not BodyDetail"
metadata:
  node_type: memory
  type: project
---

Shipped 2026-07-27. API v2.3.3 added `report.scans[]` to `ami.survey.digest`,
and `LocationsClient.ingestSurveyScans` folds it into `SystemDetail` +
`SiteAssay` off the existing `LocationsIngestion.catalogRoute()` dispatch table.

**Why it matters more than it looks.** An AMI-adopted survey drone emits zero
per-device events ([[ami-drones-are-event-silent]]), so before this block
existed a survey that scanned nine bodies produced *nothing but counts*. This is
the only channel the intel travels on. The orrery renders off a `@Fetch` over
`SystemDetail`, so writing there makes it re-render live mid-survey with **no
star-map changes at all**.

## The payload

Measured on the live event log 2026-07-27: 493 `ami.survey.digest` rows, 32 with
the `scans` key, 11 non-empty. It is the only event anywhere carrying `scans`.
`belt_search` digests carry the key but it has been empty in every sample.

Entries are `{device_code, scan_target, scan_type, report}`, two shapes:

- `scan_type: "planet"` → `report = { planet: {…20 fields…}, moons: [stubs] }`
- `scan_type: "moon"` → `report = { moon: {…18 fields…, salvage: [...] } }`

The moon block is exactly what the orrery's physical fidelity work consumes
(`has_atmosphere`, `has_subsurface_ocean`, `orbital_distance_km`,
`orbital_period_hours`, `tidally_locked`) — see [[orrery-physical-fidelity]].
Salvage entries carry absolute `resources_remaining`, the only source of a
site's unit totals ([[salvage-resource-amounts]]).

## Three traps

**1. `moons` is a SIBLING of `planet`, not nested inside it.** A
`scan.completed` result nests the roster *inside* the planet object, which is
why `RawScanEventResult` cannot be reused — it decodes `moons` off
`RawScannedBody`. Reusing it loses every moon silently. `RawSurveyScanReport`
exists for exactly this one-field difference.

**2. A scan is a PARTIAL observation — never model it as `BodyDetail`.**
`StarSystem.applying(_:)` preserves only salvage, lagrange, and moons, taking
`sites`/`devices`/`inventory` from the incoming value. A digest scan carries
none of those three, so routing it through `applying` would erase them on every
scan. Hence `BodyObservation` + `StarSystem.observing(_:)`, which writes only
the fields the payload actually carried. **The type exists to make that
asymmetry unrepresentable**; if you ever find yourself converting a
`BodyObservation` to a `BodyDetail`, that is the bug.

**3. Percentages vs. depletion pull opposite ways.** `observing` preserves an
existing site's `remainingPct` (a scan carries none, and it is the only live
figure we hold) but takes `depleted` **from** the scan — a scan is a fresh
observation, so it is the one path that can *clear* a stale local flag as well
as set one. This deliberately differs from `insertingSalvage`, which preserves
`depleted`, because a `salvage.discovered` notification is not an observation of
depletion state.

## Two fields that had no home

`species_name` (planet + moon) was absent from the codebase entirely, and
`Moon` had no `lifeStage` at all — so a moon's life stage was being dropped even
on the pre-existing `GET locations/{moon}` path, and `OrreryMapping` hardcoded
`lifeStage: nil` for every moon. Both now exist (`BodyPhysical.speciesName`,
`Moon.lifeStage`), both wired through the older paths too, and moons now get the
`.life` indicator planets already had. Both are Optional, so synthesized
`Decodable` uses `decodeIfPresent` and pre-existing `StarSystem` blobs still
decode — no hand-written decoder, unlike `Belt`/`SalvageSite` which added
non-optional collections.

## Deliberately not done

- **Drill-in still fetches.** `hydrateBody` keeps firing on body select. The
  digest carries no `devices`/`sites`/`inventory`, so skipping the fetch would
  hide another player's ship parked at the body. The win is that the orrery
  renders correct physics *immediately* and the fetch tops up live occupancy.
- `report.progress`/`busy`/`idle`/`assigned_this_tick` — survey-queue telemetry,
  not location data. Scan counts stay owned by `hydrateSystem`.
- An unknown `scan_type` is **counted** (`SurveyScans.unreadable`) and logged at
  `.notice`, not silently dropped, so a belt or star scan surfaces if the
  backend starts sending one.

Spec: `docs/superpowers/specs/2026-07-27-survey-digest-scan-hydration-design.md`.
Tests: `UniverseModelsTests/SurveyScanTests` (fixtures captured verbatim from the
live DB) and `GameServicesTests/SurveyScanIngestionTests`.
See [[locations-catalog-feature]] for the blob-per-system model this writes into.
