# 11 — Pinned Haul Run row: false "Nothing reachable", no destination, ferry not locked

Type: task
Status: resolved

## Symptom (observed live 2026-08-10)

The mine's pinned Haul Run (row `C4A542AE…`, `fleetTag auto:mine:ACHERNUR-BELT-1`,
pinned target `ACHERNUR-BELT-1`) renders in the Directives list with **no
destination** and subtitle **"Nothing reachable"**, while its ferry
(`8D53C9B1`, `ami_transport_controller` at `AINALRAM-BELT-1`) is actively
hauling `collect: ACHERNUR-BELT-1 → deliver: AINALRAM-BELT-1`. The run is
healthy; the row is wrong. The row also gives no hint it belongs to the mine.

Separately, the ferry's built-in Ferry row is **not locked** ("driven by …"
badge absent, Reconfigure/Clear not refused), unlike the three built-ins owned
by the Salvage/Survey/general-Haul runs.

## Root cause

Two holes, one shared origin: the row model predates `HaulRun`'s pinned-source
mode (shipped with the mine build, 2026-08-09) and only understands the
tag-driven general drainer.

1. **Display** — `DirectiveRow.merge`
   (`app/Modules/DirectivesFeature/Sources/DirectiveRow.swift:220`) resolves a
   haul run's target via `HaulRun.currentHaulTarget(devices:tag:delivery:)`,
   filtering devices by the row's `fleetTag`. A pinned row's tag
   (`auto:mine:<belt>`, from `Brain.mineFerryTag`) is worn by **no device** —
   mine devices wear bare `auto:mine`, and the engine drives a pinned row by
   `deviceCode`, not tag (`HaulRun.pinnedAssignment`,
   `app/Modules/DirectiveEngine/Sources/HaulRun.swift:156`). So the lookup
   structurally returns nil → "Nothing reachable", no `headlineDesignation`.

2. **Lock** — the `drivenBy` owners map keys on `directive.controllerCode`
   (`DirectiveRow.swift:204`). The brain launches the pinned row with
   `controllerCode: nil` (`Brain.swift:420` in `ensureMineFerries`), and the
   only stamp path — `.assignController` out of `HaulRun.assign` — is skipped
   forever on this row: the `mineRun` install had already armed the ferry, so
   `assign`'s `isInForce` short-circuit (`HaulRun.swift:263`) advances straight
   to `hauling` every cycle. `controllerCode` stays nil → the ferry's built-in
   row never gets `drivenBy` → the Reconfigure/Clear refusals in
   `DirectivesFeature.swift:204`/`215` don't fire. The operator can clear the
   ferry config out from under the run (it would self-heal by re-dispatching,
   but the guard the sibling rows have is absent).

## Fix direction

- `merge`: branch on `HaulRun.pinnedSource(of:)` — a pinned row's designation
  is `targets.first` (optionally confirmed via
  `HaulRun.drainedPile(of:delivery:)` on the row's own `deviceCode`).
- `ensureMineFerries`: stamp `controllerCode` at launch — it is the same device
  the closure already resolved as `deviceCode`. (Check `reservedDevices` still
  behaves; it already inserts `controllerCode` when present.)
- Optional, operator-facing: the belt designation in the headline conveys the
  mine association implicitly; decide whether the row should say "mine" out
  loud (e.g. subtitle "Hauling for mine at <belt>").

## Acceptance

- Pinned row renders `Haul Run → ACHERNUR-BELT-1` (mono designation) with a
  truthful subtitle while the ferry is in force.
- Ferry built-in row shows "driven by Haul Run" and refuses Reconfigure/Clear
  while the pinned row is live.
- General drainer row behaviour unchanged (tag path still serves it).
- `DirectiveRowTests` cover both pinned-row cases; existing tests green.

## Answer (2026-08-10)

Both holes closed, plus two adjacent ones the fix exposed.

**Display.** `DirectiveRow.merge` branches on `HaulRun.pinnedSource(of:)` and
resolves a pinned row's target from its **own `deviceCode`** via
`HaulRun.drainedPile(of:delivery:)` rather than the tag lookup;
`headlineDesignation` returns `HaulRun.pinnedSource(of:) ?? haulTarget`, so the
belt renders whether or not the ferry has taken the config. The subtitle is
`"Hauling belt inventory"` in force and `"Pointing the ferry"` before —
`"Nothing reachable"` is now unreachable for a pinned row. The tag-driven
general drainer path is untouched.

**Lock.** `Brain.ensureMineFerries` stamps `controllerCode: controller` at
launch. `reservedDevices` is provably unchanged (the stamped controller *is* the
row's `deviceCode`, which it already inserted) and that equality is asserted by
a test.

**Wording (the optional third item).** Operator's call: the belt must be
discoverable per-row, treated like the general drainer — `Haul Run →
ACHERNUR-BELT-1` in the headline plus subtitle `Hauling belt inventory`. Goal
vocabulary ("mine") stays out of the Directives list.

**Two adjacent holes found and closed.** `DirectiveTargetsSection` had the
identical tag-blindness — a pinned row drew no Assignments section at all,
falsifying its own doc's promise to mirror `DirectiveRow.subtitle`. And
`DirectiveDetailView` rendered `directive.kind.title`, plain "Haul Run" for
every haul run, so two mines were indistinguishable one click deeper than the
list; it now takes the row's `headlineDesignation` and renders it in
`.rcTitleMono` beside the title, with `navigationTitle` composed from
`DirectiveRow.title` (which its own doc already said existed for that).

### Correction to the analysis above

"The only stamp path is skipped **forever**" is overstated, and the truth is
worse: `HaulRun.assign`'s pinned branch emits `.assignController` whenever
`isInForce` is false, so the stamp is unreachable *exactly while the ferry is
healthy*. The lock would have appeared only once the run started misbehaving.
Stamping at launch is still the right fix.

**Known limit, pre-existing and shared with the general path:** `merge` has no
`WorldSnapshot`, so it confirms against the hard-coded `HaulRun.deliveryLocation`
rather than the live hub. Correct today; if the hub moves, a working pinned
ferry reads "Pointing the ferry" forever.
