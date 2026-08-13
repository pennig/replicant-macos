# Theatre-aware readiness

Closes the follow-up ticket in `.scratch/multi-theatre/residuals.md` ("Follow-up ticket,
gating — theatre-aware readiness"), plus the same-system `ferry` defect on the two mine
paths that the ticket does not cover but that arms the moment a second theatre exists.

## Context

`Brain.surveyReadiness`, `salvageReadiness` and `mineReadiness` each resolve
`view.theatres.first(where: \.isOperational)` once, and `haulReadiness` only asks whether
any operational theatre exists. All four are resolved **before** their caller's
`for theatre in snapshot.view.theatres.filter(\.isOperational)` loop. So every sibling
theatre builds a directive carrying the FIRST theatre's carrier and roam centre while
stamped with the sibling's `theatreDepot`. Only `ensureOne`'s account-wide device
reservation check stops those rows committing.

`theatres` is sorted by depot designation (`TheatreRegistry.recognise` ends
`result.sorted { $0.depot < $1.depot }`), so the lowest depot designation wins every
verdict.

At two operational theatres the second gets no survey run, no salvage run, no mine
install and no general haul drainer, and the log takes four
`"… declined: X is already committed"` notices every 5-second tick indefinitely.

## The carrier-scoping decision

The ticket says "scope carrier selection to that theatre's depot" but does not say how.
Requiring a carrier to stand AT the depot is wrong for survey and salvage: those carriers
roam, and the existing single-theatre behaviour would regress to never relaunching once
the carrier is in the field.

**Decision: an owning-theatre partition.** Each carrier belongs to exactly one operational
theatre — the one servicing its current system, falling back to the nearest theatre, and
to nil when the device has no location the census can place. A partition is the property
that matters: two theatres can never select the same device, which is the defect.

`mineReadiness` is exempt from the partition. `MineRecipe.shortfall(at:)` and
`MineRecipe.idleCarrier(at:)` already take the depot as a parameter, so passing the
theatre's own depot is the whole fix there.

## Global Constraints

- **Comment budget is hard**: file header ≤ 6 lines, `///` ≤ 3 lines, inline `//` ≤ 2
  lines. Blank `///` lines count. History goes to `.claude/memory/`, never into source.
  See `app/CLAUDE.md` § Comments.
- **TDD**: write the failing test first, watch it fail, then implement. Every task's
  tests live in `app/Modules/DirectiveEngine/Tests/`.
- **Read test results from the Swift Testing JSON event stream**, never by scraping
  console text. Use the `swift-test-event-stream` skill. For scoped runs use
  `--test-product`; for whole-package runs use `--build-system native` (the default
  swiftbuild backend truncates the event stream file — one process per target, each
  truncating the same path).
- **`theSupervisorAdoptsTheRowTheBrainLaunched` is intermittent** under
  `--build-system native` and pre-existing. Do not attribute a failure of it to your
  change without re-running. See
  `app/.claude/memory/supervisor-adopts-row-whole-package-failure.md`.
- **Verify with the Swift LSP**, not grep, and build before querying — the index is
  exactly as fresh as the last `swift build`. An empty `findReferences` is not evidence a
  symbol is unused. LSP root is `app/Modules/`.
- **`TheatreLivenessTests` must keep passing unchanged.** It pins the device-reservation
  guard, which stays correct; this work makes it stop being load-bearing for this case.
- Do not open a PR and do not push. Commit to the current worktree branch.
- `Device.location` is a SITE, not a system. Use `SiteAssay.system(of:)` to get the
  system, never a prefix match.

## Task 1 — The owning-theatre partition

Add to `Brain` (in `app/Modules/DirectiveEngine/Sources/Brain.swift`):

```swift
static func owningTheatre(of device: Device, view: WorldView) -> Theatre?
```

Rules, in order:

1. `device.location` is nil → return nil (a stowed or cruising device belongs to no
   theatre).
2. `view.theatre(servicing: SiteAssay.system(of: location))` if non-nil.
3. Otherwise `view.theatre(nearest: SiteAssay.system(of: location))`.
4. Otherwise nil (the system is not in the census).

This must be a **partition**: for a given `view`, each device maps to at most one
theatre, and the mapping is deterministic across ticks. Both `WorldView` resolvers
already order by `(distance, depot)`, so determinism comes for free — assert it anyway.

Tests to write:

- A device in a theatre's own system is owned by that theatre.
- With two operational theatres, a device is owned by exactly one — assert the other
  theatre does NOT own it.
- A device with `location == nil` is owned by no theatre.
- A device in a system absent from `starPositions` is owned by no theatre.
- Determinism: the same device and view return the same theatre across repeated calls.

## Task 2 — `surveyReadiness` takes a theatre

Change the signature to `surveyReadiness(view: WorldView, theatre: Theatre)`.

- Delete the internal `guard let theatre = view.theatres.first(where: \.isOperational)`
  (Brain.swift ~1205) and its `.idle(reason: "no operational theatre")`; the caller now
  supplies the theatre.
- Take `centre = theatre.system` from the parameter.
- Scope carrier selection: after the existing tag and `isCarrierHull` filters, keep only
  devices whose `Brain.owningTheatre(of:view:)` equals the passed theatre.
- Move `ensureSurvey`'s `guard case let .launch(...)` INSIDE the
  `for theatre in ...` loop, calling `surveyReadiness(view:theatre:)` per theatre and
  `continue`-ing on `.idle`.

Keep the two-case verdict (no stall case) — `surveyReadiness` must remain unable to
escalate by construction. Keep the mistagged-device clause.

Tests: two operational theatres, each with its own tagged, staged carrier → each theatre
gets a launch naming its OWN carrier and its OWN system as roam centre. And: a theatre
with no carrier of its own returns `.idle` without consuming the other theatre's carrier.

## Task 3 — `salvageReadiness` takes a theatre

Same shape as Task 2: `salvageReadiness(view: WorldView, directives: [Directive],
theatre: Theatre)`. Delete the internal theatre resolution (Brain.swift ~1261), take
`centre` from the parameter, apply the same owning-theatre filter to carrier selection,
and move the guard inside `ensureSalvage`'s loop.

Keep the meshed-salvage-units gate and the reserved-device filter as they are.

Tests: mirror Task 2's, plus one asserting the meshed-salvage gate still declines when no
meshed system has units left.

## Task 4 — `haulReadiness` takes a theatre

`haulReadiness(view: WorldView, directives: [Directive], theatre: Theatre)`.

- Replace `guard view.theatres.contains(where: \.isOperational)` with nothing — the
  caller passing a theatre already establishes it.
- Apply the owning-theatre filter to `HaulRun.controllers(...)` selection.
- Move the guard inside `ensureHaul`'s loop.

Tests: two theatres each with their own `auto:haul` controller → two general drainers,
each naming its own controller. One theatre with no controller of its own → `.idle` for
that theatre only.

## Task 5 — `mineReadiness` takes a theatre

`mineReadiness(view: WorldView, directives: [Directive], theatre: Theatre)`.

- Replace `guard let hub = view.theatres.first(where: \.isOperational)?.depot` with
  `let hub = theatre.depot`.
- The `depots` exclusion set stays **account-wide** (`Set(view.theatres.filter(\.isOperational).map(\.depot))`)
  — a mine must not be sited on ANY theatre's depot, not merely this one's.
- Move the guard inside `ensureMine`'s loop.
- Update the stale comment above `depots` (Brain.swift ~1340): it says a depot is
  "belt-shaped", which is not true of an entry-point depot. State what the code does —
  every operational depot is excluded from siting — within the 2-line inline budget.

Tests: two theatres, each with its own printed mine fleet and idle carrier → each gets a
launch naming its own carrier and a belt near its own depot. And: a belt at theatre B's
depot is not sited for theatre A.

## Task 6 — `plan()`'s grow pass falls through

`Brain.plan` (Brain.swift ~703) takes the single best candidate and idles the whole pass
when that candidate's nearest theatre has no free carrier. Change it to walk `ranked` in
order and take the first candidate that is both not in flight AND whose nearest theatre
has a free carrier.

Preserve the existing idle reasons: if no candidate is out of flight, keep "every grow
candidate is already in flight"; if candidates remain but none has a reachable theatre
with a free carrier, keep the `carrierBlocker(...)` reason computed for the FIRST such
candidate's theatre, so the why-view still names a concrete blocker.

Tests: two candidates, the nearer one's theatre carrier-less and the further one's free →
the pass grows toward the further candidate rather than idling. And: all candidates
carrier-less → idle with the `carrierBlocker` reason, not a generic one.

## Task 7 — Per-theatre stock reporting

`Snapshot.hubFootprint` (Brain.swift ~86) reads only
`view.theatres.first(where: \.isOperational)`'s footprint, so `BrainLimits.hubStock` and
the why-view show theatre A's stock under theatre B's heading.

Make the reported stock per-theatre. `BrainLimits` is documented "Reports, never gates",
so this is display-only — do not let it change any gate. Surface each operational
theatre's own footprint and render it against that theatre in the why-view
(`app/Modules/DirectivesFeature/Sources/BrainWhyView.swift`).

Follow the card-phrasing rule recorded in
`app/.claude/memory/brain-survey-goal-build.md`: state a status and a static fact, never a
status and an active verb.

Tests: two theatres with different footprint resources → each reports its own number.

## Task 8 — Same-system `ferry` is a `shuttle`

`HaulTargetPlanner.ferry` is the interstellar supply line and requires both ends on the
FTL mesh; `HaulTargetPlanner.shuttle` is the in-system one. `HaulTargetPlanner`'s own doc
(HaulTargetPlanner.swift ~41-45) says a `ferry` whose two ends share a system is
malformed. The general drainer picks correctly
(`directive: system == deliverySystem ? shuttle : ferry`, ~100-104). Two mine-side paths
bypass that choice and hard-code `ferry`:

- `MineRun.armTargets` (MineRun.swift ~250-256) — the `ferry` config armed onto the
  transport controller.
- `HaulRun.pinnedAssignment` (HaulRun.swift ~157-161) — the per-mine pinned haul row.

Both must choose the verb the same way the general drainer does: compare
`SiteAssay.system(of: collectLocation)` against `SiteAssay.system(of: deliverySink)` and
pick `shuttle` when they match, `ferry` otherwise.

This is not hypothetical after Tasks 1–7: `Brain.mineReadiness` excludes operational
depots from siting, so an entry-point depot frees that system's own belt as a candidate
at distance 0.0, which `MineSitePlanner` then ranks first.

Check whether the loose confirm checks that accept an in-force config
(HaulRun.swift ~174-176 and ~186-189, MineRun.swift ~266-269) need to accept the new verb
too — a row armed `shuttle` must read as in-force, not as needing a re-arm.

Tests: a pile in the depot's own system arms `shuttle`; a pile in another system arms
`ferry`; a `shuttle`-armed row reads as in-force rather than re-arming every tick.

## Task 9 — Per-theatre fleet tags

Discovered during Task 4, and it is why Tasks 2–4 alone do not achieve the goal.

`Brain.reservedDevices` (`Brain.swift:1011-1015`) reserves, for every live directive,
**every device in the fleet carrying that directive's `fleetTag`**. The brain stamps shared
constants — `SurveyRun.defaultFleetTag` = `auto:survey` (`SurveyRun.swift:70`),
`SalvageRun.defaultFleetTag` = `auto:salvage` (`SalvageRun.swift:65`),
`HaulRun.defaultFleetTag` = `auto:haul` (`HaulRun.swift:47`). So one live run reserves every
identically-tagged device account-wide, and the second theatre's carrier is filtered out as
reserved no matter how well its readiness function is scoped.

The codebase already answered this once: mine ferries are tagged `auto:mine:<belt>` and
never the bare fleet tag, recorded in `app/.claude/memory/brain-mine-build.md` — "a shared
tag would cap the whole system at one working ferry". That is why mine ferries are the one
thing `residuals.md` lists as already per-theatre.

**Decision (operator's, taken 2026-08-12): per-theatre tags**, matching the mine precedent.
`reservedDevices` is not touched.

- Add a per-theatre tag derivation to each of the three runs, shaped like the mine one:
  `auto:survey:<depot>`, `auto:salvage:<depot>`, `auto:haul:<depot>`. `SurveyRun` already has
  a `fleetTag(_:)` seam (`SurveyRun.swift:573-575`) — extend rather than duplicate.
- `Brain.ensureSurvey` / `ensureSalvage` / `ensureHaul` stamp the per-theatre tag on the
  directive they build.
- **Migration must not break the working single-theatre fleet.** Today's devices wear the
  bare tag. Carrier SELECTION accepts either the theatre's own tag or the bare tag, so an
  un-migrated fleet keeps launching. The directive still stamps the per-theatre tag, so a
  migrated device is reserved only by its own theatre.
- **Surface the migration**: a bare-tagged device selected for a theatre loses the tag-based
  reservation that protects its fleet members from another run. Name that in the readiness
  blocker or idle reason so the operator knows which devices to re-tag, rather than leaving
  it to be discovered when a fleet member is stolen.

Tests: two theatres, each with its own per-theatre-tagged carrier, both launch on the same
tick — this is the test that fails today and is the whole point of the effort. A bare-tagged
carrier still launches for a single theatre. A device tagged for theatre A is not selected
for theatre B. A live theatre-A run does not reserve theatre B's tagged carrier.

## Out of scope

- Calibrating `HaulTargetPlanner.secondsPerLy` (uncalibrated, tracked separately).
- The retry-amplification residual (`brain-salvage-build`), which this work multiplies by
  theatre count but does not cause.
- Any change to `TheatreRegistry`, `TheatreSiteRanking`, or the establish flow.
