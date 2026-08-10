---
name: brain-mine-build
description: SHIPPED 2026-08-09 — the brain's fifth acting capability, a permanent mine, the build record.
metadata:
  type: project
---

# The brain's mine goal — the build record (2026-08-09)

Plan: `docs/superpowers/plans/2026-08-09-brain-mine-goal.md`.
The brain's fifth acting capability, after
[brain-tendmesh-build](brain-tendmesh-build.md),
[brain-survey-goal-build](brain-survey-goal-build.md), and
[brain-salvage-build](brain-salvage-build.md) (salvage + haul). Two new mission
kinds, one new SPM-level enum, no schema change.

## What shipped

- **Two directives.** `mineFleetPrint` — an operator-invoked serial printer:
  one job per tick against the `MineRecipe` shortfall at the hub, gated on the
  shared reserve rail so it cannot disagree with `RelayRun`/`RestockRun` about
  "too poor to print". `mineRun` — installs a printed fleet at a belt through
  `attach → confirmingAttach → travel → confirmingArrival → detach →
  confirmingDetach → adopt → confirmingAdopt → arm → confirmingArm`: attach the
  nine carried members one at a time, fly the loaded carrier out, detach the
  whole fleet in one command, hand drones to their controllers, then arm every
  target (mining, survey, two service bots, the transport pair's `ferry`).
- **`MineRecipe`** — the eleven-device fleet as data (nine carried: one mining
  controller, three mining drones, one survey controller, two survey drones,
  two service bots; two self-moving: one transport controller, one cargo
  freighter), plus the membership queries (`shortfall`, `unassignedFleet`,
  `installedBelts`, `idleCarrier`) the print run, the mine run, and the
  brain's readiness verdicts all share.
- **`MineSitePlanner`** — ranks candidate belts for a new permanent mine:
  belt class first, then a rares/conductive scarcity bonus (rares ≥ moderate
  scores 2, conductive ≥ moderate scores 1), then distance from the hub, then
  designation as the stable tie-break. Hard filters: meshed system, not
  already occupied, classifiable, placeable.
- **`HaulRun` pinned-source mode** — a row carrying `targets` drains exactly
  that one location through exactly its own `deviceCode` controller (`targets.first`
  is the whole mode switch), beside the existing general drainer.
- **Brain wiring** — `mineReadiness` (fleet shortfall → idle carrier → site
  planner, in that order), `ensureMine` (one install at a time — a second
  would contend for the same free fleet members at the hub), and
  `ensureMineFerries`, which keeps one PINNED haul row per INSTALLED belt
  alive, tagged `auto:mine:<belt>` (per-belt, never the bare fleet tag — see
  below) and skipped for any belt a live `mineRun` still targets, since that
  run arms the same transport controller from the other side.
- **Why-view rows + per-mine health** — `mineStatus` reads a live `mineRun`
  row FIRST (mid-install the fleet is attached/stowed, so re-deriving
  readiness would misreport its own blocker), else the readiness verdict.
  `mineHealth` returns one `BrainMineHealth` per installed belt (mining
  active, survey active, ferry in force), excluding any belt a live install
  still targets.
- **The Print Mine Fleet launcher** — a confirm dialog in `DirectivesFeature`
  rather than its own screen, adopting an already-running print row.
- **The seam test** — `BrainMineSeamTests`: one real tick through the real
  `report()` over a real database, plus the two twins that each withdraw
  exactly one seeded fact (no printed fleet; belt system unmeshed) and prove
  the report names the right idle reason.

## Where the plan was wrong

**The `confirmingAttach` fresh-evidence ladder the plan called for was
unimplementable.** The standard "prove `updatedAt >= stepStartedAt`" pattern
(see [confirm-steps-need-fresh-evidence](confirm-steps-need-fresh-evidence.md))
needs the confirm-read to land AFTER the step stamp. But `attach`'s own
dispatch performs a confirm-read of the moved row, and that read lands BEFORE
`confirmingAttach`'s `stepStartedAt` is written — so the freshness check and
the success predicate were mutually exclusive: a row proven fresh could never
also read as landed. Fixed by `MissionLogBudget.dispatchRounds`, which counts
the CURRENT unbroken run of `dispatch`/`confirm` re-entries straight off the
directive's own log — a loop-scoped attempt budget the mission's
re-stamping clock cannot erase — and the same shape closes `confirmAdopt`.

**The arm loop needed per-verb dispatch evidence, not a landing score.** A
first cut scored all five arm targets by `armState` (0/1/2) and credited
whichever one changed; review found this banks a 0-to-2 landing (a
`set_directive` that happened to land already-active) as two rounds' worth of
progress, over-crediting the budget. The real fix needed to know which VERB
the loop just sent (`set_directive` only proves `armState >= 1`; `activate`
alone proves `armState == 2`). A first attempt at fixing this dead-ended: once
a paused `set_directive` proved unconfirmable, the retry path had nothing to
re-dispatch against and stalled without making progress. The shipped fix is
`MissionLogBudget.LastDispatch`, a three-way enum (`.dispatched(kind:device:)`
/ `.nothingSent` / `.unreadable`) that parses `DirectiveExecutor`'s own
`dispatchSummary` log line and **fails closed** on anything that doesn't
parse as `"Dispatched <verb> to <code>"`.

**Transport-pair identification had to prefer the installed pair over the
free pool.** `MineRun.transport(of:in:)` first tries to match a controller
already `collect`-configured for the belt; only when none exists does it fall
back to the lowest-coded free pair. Matching free-first would let a SECOND
mine's install steal the first mine's already-working ferry pair out from
under it (the spare-pair hijack) the moment both are printed and idle at the
hub simultaneously.

**Per-belt ferry `fleetTag` was a deliberate deviation from a fleet-wide
tag.** `reservedDevices` closes over a row's `fleetTag`, so a single
`auto:mine` ferry row (matching the print/install tag) would reserve every OTHER
mine's transport controller too, capping the whole system at one working ferry
regardless of how many mines are installed. `mineFerryTag(for:)` mints
`auto:mine:<belt>` instead.

**`mineHealth` needed directives threaded through, not just device rows.** A
first cut read health off device state alone and false-halted a belt still
mid-install (attached/stowed members read as an unhealthy mine, not an
installing one). Fixed by excluding any belt `liveMineBelts(directives)`
still targets — the same exclusion `mineStatus` and `ensureMineFerries` use.

**The seam test's two twins shared a mutation-coupling trap**, the same one
[brain-salvage-build](brain-salvage-build.md) and
[brain-tendmesh-build](brain-tendmesh-build.md) both hit: a twin asserting the
EXACT reason string a mutated function produces can pass against a mutant that
breaks the function in a different way but happens to route through the same
string. Resolved with a second, launch-isolating mutation per twin rather than
relaxing the assertion.

## Carried forward, not fixed

- **Retry re-arms the attach counter.** `MissionLogBudget.dispatchRounds`
  stops its backward walk on a `.resolved` log entry and counts it as the loop
  boundary — the same retry-amplification shape recorded in
  [brain-salvage-build](brain-salvage-build.md): a brain auto-retry writes
  exactly that `.resolved` entry, so each retry re-arms the round budget.
  Bounded (blind re-sends, not unbounded), operator-resolvable.
- **Pinned ferry mode hardcodes `ferry`.** A pinned source standing in the
  hub's own system would need `shuttle` instead — today that's a bounded
  `commandRejected` stall, not a crash or silent misroute.
- **Pinned mode skips the mesh filter** the general planner applies — bounded
  the same way.
- **Live `mineRun` reserves ALL transport controllers** while it installs (the
  whole recipe's device-reservation scope, not a belt-scoped one), so a NEW
  ferry for a different belt waits until the install finishes. Self-clearing.
- **Ferry rows never retire.** A belt that stops producing keeps its pinned
  `auto:mine:<belt>` haul row alive forever. Additive-policy, no owner.
- **The pinned ferry row renders as "Nothing reachable" in the Directives
  list.** Pre-existing fallback gap (see [brain-salvage-build](brain-salvage-build.md)'s
  parked note) that the first pinned-mode row in production made visible; the
  correct display is `targets.first`, and no task in this effort owns fixing
  the list view.
- **Post-install directive lapses surface in the why-view but are never
  auto-re-armed.** Deliberate: a lapse (an operator pausing a controller,
  say) implies deliberate teardown, and the brain does not second-guess it.
- **`lastDispatch` parses a human-readable log summary line.** A structured
  field on the dispatch-log entry (verb + device code, typed) would retire
  this string-parsing coupling; not built this round.
- **Hand-pass comment audit turned up header-length overages beyond the
  ledger's own tracked minors** (Task 5 flagged `MineSitePlanner.swift`/
  `MineSitePlannerTests.swift` at 7/8 lines against the 6-line budget):
  `MineRecipe.swift` (7), `MineRun.swift` (8), `BrainMineSeamTests.swift` (7),
  `BrainMineTests.swift` (8), `MineRecipeTests.swift` (7), `MineRunTests.swift`
  (7) all carry the same one-or-two-line overage, consistent with `Brain.swift`'s
  own long-standing 9-line header. `check-comments.sh` does not check line
  counts, only history-pattern regexes — see [comment-policy](comment-policy.md).
- **`installedBelts` reads true at DETACH, not at arm.** The predicate is
  "a tagged `ami_mining_controller` standing away from the hub", which is
  satisfied the instant `MineRun`'s detach lands — several ticks before
  `adopting`/`arming` have made the fleet do anything. Nothing exploits this
  today because no path re-enters `preflight` once a run is past it, and
  `preflight`'s `installedBelts` check is the only reader that retires a row
  `.done`. But any future skip verb, remap verb, or preflight re-entry would
  read a landed-but-unarmed fleet as an installed mine and retire the run,
  leaving eleven devices parked at a belt mining nothing. A real check would
  ask whether the mining controller is running `MineRun.miningDirective`,
  which is what `Brain.mineHealth` already asks.
- **`MineFleetPrint` pays the full 30-minute `printDeadline` at EVERY job
  transition, not just on a dead queue.** The final-review fix that removed the
  over-print cascade (`printing` advances only on an empty `remaining`) has no
  "my dispatched type is satisfied, hand back promptly" path — the dispatched
  type is not statelessly recoverable (a `.print` dispatch logs verb + device,
  not the `device_type` param). An 8-job fleet build therefore waits ~7 × 30 min
  of pure deadline on top of print time (~6h total vs ~2.8h). Deliberate trade:
  wall-clock on an unattended print bought the end of a guaranteed ~28%
  over-spend. A structured params field on the dispatch log entry would allow
  the prompt hand-back and retire this.
- **`installedBelts != hub` makes the hub's own belt structurally invisible**
  to the mine estate: a mine installed there answers no installed query, so
  the goal would re-site it forever. Now guarded at BOTH ends by the final-review
  fix wave — `Brain.mineReadiness` unions the hub location into the occupied
  set, and `MineRun.preflight` stalls `.unreachableDevice` on a target belt
  equal to the derived hub. The guard is the fix, not the filter: relaxing
  `installedBelts` to include the hub would break `MineRecipe.unassignedFleet`,
  which needs the hub's own standing fleet to read as free.

## Sign-off (2026-08-09)

`swift build --build-tests` clean from a fresh worktree build.
Per-product event-stream runs, one output path each, gated on zero
`issueRecorded` failures, exactly one `runEnded`, and `testStarted` ==
`testEnded`:

| Product | Tests | Failed | runEnded | started == ended |
| --- | --- | --- | --- | --- |
| DirectiveEngineTests | 1,110 | 0 | 1 | yes |
| DirectivesFeatureTests | 202 | 0 | 1 | yes |
| GameServicesTests | 250 | 0 | 1 | yes |
| GameModelsTests | 117 | 0 | 1 | yes |
| BobnetFeatureTests | 78 | 0 | 1 | yes |

**1,757 tests, zero failures, zero crashed targets.** The DirectiveEngine and
DirectivesFeature rows are the post-fix-wave re-runs; the other three products
were untouched by the wave and carry their pre-wave numbers.

`check-comments.sh` over every file this effort touched found only
pre-existing history-pattern hits, all dated/worded before this effort's
first commit (0d0d12b) — none were introduced by this build. The one new
doc comment the mechanical checker flagged (`mineFleetIncomplete`'s "is no
longer complete") is a false positive: it states a current invariant, not
history.

LSP `findReferences` on the three anchor symbols, from a build freshly
populated and re-linked (`./scripts/link-index-store.sh`): `HaulRun.pinnedSource`
resolved cleanly (8 references across `HaulRun.swift`'s own three call sites
and `HaulRunTests.swift`). `MineRecipe.shortfall` and `MineSitePlanner.site`
returned empty from `findReferences` despite `hover` fully resolving both
declarations in place — the documented cold-per-symbol-index gap, not
evidence of dead code. Grep fallback confirmed both: `shortfall` is called
from `MineFleetPrint.swift:56` and `Brain.swift:1203` (inside `mineReadiness`);
`site` is called from `Brain.swift:1217`, also inside `mineReadiness` — both
match the plan's expected call graph.

**First live install (ACHERNUR-BELT-1, 2026-08-09/10) surfaced three defects**,
filed as `.scratch/automation-brain/issues/11–13` and **all three FIXED
2026-08-10**.

**11 — pinned haul row.** `DirectiveRow.merge` knew only the tag-resolution
path, and a pinned row's belt-scoped tag is worn by no device, so it rendered
"Nothing reachable" with no designation; `controllerCode` stayed nil so the
ferry's built-in row was never locked. Fixed by branching on
`HaulRun.pinnedSource(of:)` (resolve off the row's OWN `deviceCode` via
`drainedPile`) and stamping `controllerCode` at launch in `ensureMineFerries`.
The ticket's "the only stamp path is skipped forever" was backwards in a way
worth knowing: `assign`'s pinned branch emits `.assignController` whenever
`isInForce` is false, so the lock would have appeared only once the ferry
started MISBEHAVING. Two adjacent tag-blind surfaces fell out —
`DirectiveTargetsSection` drew no Assignments section for a pinned row, and
`DirectiveDetailView` titled every haul run "Haul Run", making two mines
indistinguishable one click below the list.

**12 — unowned belt controllers.** The lock model assumed every engine-owned
built-in is held by a live mission's `controllerCode`; the permanent mine has no
such row by design. Resolved with a **derived predicate**: an in-force directive
on a device wearing an `auto:` tag and owned by no mission is engine-owned, the
lowest-sorting tag is the owner, and a belt is claimed only for `auto:mine` at a
location in `installedBelts` computed over devices with a directive IN FORCE (an
idle mine fleet at the hub is inventory, not a mine). **The gap was 8 rows, not
the 2 the ticket named** — six service bots were also editable, and
`RepairFleet.isArmed` needs `currentDirective == "service"`, so a Clear silently
disarmed repair on the survey, salvage and mine fleets. The bare tag is now
load-bearing for a guard; un-tagging is the take-back gesture, documented in
`app/CONTEXT.md` and in the detail pane's lock note.

**13 — `MineFleetPrint` over-print.** The ticket's arithmetic was wrong and the
DB verification rewrote the cause. A transport job is **exactly 30m00s**, so
`printDeadline` does not undercut it — it EQUALS it, buying zero holdback, and
all 14 dispatches of the install exited on the deadline rather than by finding
their clones. The real enabling condition was an **SSE delivery backlog of 0 →
2h08m**: ops closed on the POLL path (which never carries the clone's device
code) while device rows lagged 28–117 min. Dispatches 1–4 at ~0 lag produced
exact counts; over-printing began at the first clone landing inside the lag
window and stopped when the backlog drained. The multi-quantity "settles on the
first clone" theory is **contradicted** — the qty-2 bot op stayed open across
both clones. Fixed by porting `RelayRun`'s pattern: `fleetEvidenceIsStale`
compares the newest `updatedAt` among hub-located rows against
`stepStartedAt` and buys `.refreshDevicesInSystem` before dispatch.
**The witness must be `stepStartedAt`, never the op close** — the op closed
BECAUSE the hub was polled, so `hub.updatedAt ≈ close + 10s` and any
close-derived watermark is self-satisfying. `RestockRun` shares the race and is
LESS guarded (its deadline check only logs, then falls through unconditionally);
scoped out and filed as ticket 14.

Related: [brain-tendmesh-build](brain-tendmesh-build.md),
[brain-survey-goal-build](brain-survey-goal-build.md),
[brain-salvage-build](brain-salvage-build.md),
[brain-goal-decision-policy](brain-goal-decision-policy.md),
[brain-robustness-bar](brain-robustness-bar.md),
[confirm-steps-need-fresh-evidence](confirm-steps-need-fresh-evidence.md).
