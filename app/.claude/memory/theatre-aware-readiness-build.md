---
name: theatre-aware-readiness-build
description: "The build that made the brain's four readiness functions per-theatre. Records why readiness scoping ALONE could never work (reservedDevices sweeps by fleetTag account-wide), the per-theatre tag scheme that fixed it, and the wire-read gap that scheme opened — the server's GET devices/tags/{tag} knows only bare tags."
metadata:
  type: project
---

Closes the readiness follow-up in [[theatre-recognition-model]]'s residuals. `surveyReadiness`,
`salvageReadiness`, `haulReadiness` and `mineReadiness` each took `theatres.first(where:
\.isOperational)` **before** their caller's `for theatre in ...` loop, so a sibling theatre got a
directive carrying the FIRST theatre's carrier, saved only by `ensureOne`'s reservation guard.
All four now take a `Theatre`; carrier pools are scoped by `Brain.owningTheatre(of:view:)` (a
partition: servicing → nearest → nil).

## The two facts that cost the most to learn

**Readiness scoping alone can never let a second theatre launch.** `Brain.reservedDevices`
reserves every device carrying a live directive's `fleetTag`, and the brain stamped shared
constants (`auto:survey`/`auto:salvage`/`auto:haul`). One live run therefore reserved every
identically-tagged device account-wide. Fixed with per-theatre tags (`auto:survey:<depot>`),
generalising the `auto:mine:<belt>` precedent in [[brain-mine-build]]; `reservedDevices` is
untouched. Operator decision, 2026-08-12.

**A per-theatre tag must never reach the server.** `GET /v1/devices/tags/{tag}` knows only the
bare tags — probed live: `auto:haul` returns 8 devices, `auto:haul:AINALRAM-BELT-1` returns
`{"devices": []}` (the endpoint is case-insensitive but not theatre-aware). `HaulRun.preflight`,
`SalvageRun.preflight`/`awaitCompletion`/`verify` all issue `.refreshFleet(tag:)`, so the first
cut stalled every relaunched salvage and haul run within minutes, unclearably — the stall
guidance names a tag the operator already has. Two `thenStall: nil` sites were worse: they
collapse to `.wait` and loop forever with no escalation, the quiet-degradation shape of
[[survey-repair-fleet-tag]]. **Rule: the stamped tag and the `reservedDevices` sweep are
per-theatre; every wire-bound tag is rooted through `RepairFleet.root(of:)`.** `SurveyRun` is
immune — it uses `.refreshDevices(deviceCodes:)` and issues no tag read. `MineRun` never reads
`directive.fleetTag`.

## Two proofs worth not re-deriving

- **A literal cross-theatre tag collision cannot be constructed.** `reservedDevices` sweeps on
  `device.hasTag(directive.fleetTag)`, so a literal match IS the reservation criterion — match
  implies reserved implies excluded from every candidate list. What is pinnable, and pinned, is
  that a legacy bare-tagged live run permanently sweeps another theatre's still-bare device.
- **In `plan()`'s grow pass, "first candidate resolves no theatre, later one is carrier-blocked"
  is unreachable.** `theatre(nearest:)` passes `admits = { _ in true }`, so the minimised set is
  candidate-invariant; and every `GrowRanking` candidate's `firstHop` is backtracked through
  `MeshGraph.search`'s `best` map, whose entries are gated on `positions[...] != nil` — the same
  dictionary that becomes `view.starPositions`. REVISIT if `theatre(nearest:)` ever gains a
  distance cutoff or a per-candidate admission rule.

## Shape differences that are correct, not drift

Haul's carrier pool is single-tier (`hasTag` + `availableDirectives.contains("ferry")`), not the
two-tier `isCarrierHull` + tag split survey and salvage use, so haul has no mistagged-non-hull
pool and correctly no `mistaggedClause` call. Mine scopes by depot parameter rather than
`owningTheatre`, because `MineRecipe.shortfall`/`idleCarrier` are co-location tests.

**Scope the carrier pool AND the untagged-hull blocker pool; keep the mistagged clause
FLEET-WIDE.** A mistagged device is often stowed, a stowed device has `location: nil`, and
`owningTheatre` returns nil for it. Scoping only the pool makes the idle reason call another
theatre's tagged vessel untagged; scoping the mistagged clause hides the device the clause
exists to name. See [[carrier-hull-capability-gate]].

## Operator migration, not yet done

Devices wearing bare tags still launch (selection accepts either form), but a live bare-tagged
row keeps sweeping account-wide **permanently** — a general run has no natural completion. Per
fleet: cancel the run, re-tag every member to `auto:<goal>:<depot>`, let the brain relaunch, in
that order. Re-tagging service bots while a bare-tagged row is live would otherwise disable
repair silently.

Also fixed here: `MineRun.armTargets` and `HaulRun.pinnedAssignment` hard-coded `ferry` for
same-system pairs, which `HaulTargetPlanner` calls malformed — live once an entry-point depot
frees its own system's belt at distance 0.0. Both now pick `shuttle` the way the general drainer
does.
