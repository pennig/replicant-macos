# Continuous Survey Roam

**Date:** 2026-07-29
**Status:** Approved

## Problem

Survey Run is stable, but it is a *manual* automation: the player picks every
target by hand and the run ends when the queue empties. The decision of what to
scan is still theirs, so the automation saves keystrokes rather than attention.

What is wanted instead: pick one starting star, launch, and have the run survey
outward indefinitely on its own, minimising inter-system travel.

The obvious implementation — greedy nearest-neighbour from wherever the vessel
is — is wrong, and measurably so. It is the cheapest possible visit order, and
it produces a scanned region full of permanent holes.

## What the measurements said

Simulated over the real census (14,122 stars) against the 400 systems nearest a
centre, visiting 120 of them:

| visit order | travel | filled radius | worst hole |
|---|---|---|---|
| **ATIANFU** | | | |
| greedy nearest-neighbour | 483 ly | **3.9 ly** | 22.6 ly |
| sliding shells, 5 ly | 650 ly | **16.4 ly** | 4.9 ly |
| strict radial (no holes possible) | 1940 ly | 17.4 ly | 0 |
| **SOL** | | | |
| greedy nearest-neighbour | 482 ly | **4.7 ly** | 22.8 ly |
| sliding shells, 5 ly | 702 ly | **17.9 ly** | 5.0 ly |

"Filled radius" is the radius inside which *every* system is surveyed — the
thing a player actually looks at on the map. "Worst hole" is the deepest gap
that ever opens behind the frontier.

Greedy nearest-neighbour never recovers from its first skip. It passed a system
3.9 ly from the centre, found a cheaper hop, and in 120 systems and 483 ly of
travel never came back; gaps 22 ly deep open behind it. It does not meander
outward so much as fill dense pockets and leave holes scattered behind. Shells
reach ~94% of strict radial's completeness for ~34% of its travel, and hold the
worst hole to one shell width.

**Travel is not the bottleneck, which is what makes this affordable.** Across
826 real travel operations the server's own ETAs are 1–3 minutes for the bulk
and top out at 467 s (~8 min). A single `survey_scan` averages 160 s per body,
and a full system means every planet and moon plus the recall wait — so a
survey cycle runs to tens of minutes against a few minutes of flight.

Shells cost +35% travel at ATIANFU and +46% at SOL, which sounds worse than it
is in wall-clock terms. Per system surveyed that is 5.4 ly against greedy's
4.0 at ATIANFU — about 1.4 extra light-years, or roughly one extra minute at the
~32 s/ly the observed ETAs imply. Against a survey cycle of tens of minutes it
is a low-single-digit throughput cost.

Caveat on that figure: every hop with evidence behind it is inside the ~20 ly
region the fleet has actually been working, so it is not established that a
40 ly hop stays that cheap. If long hops turn out to be superlinear in distance,
the shell width is the dial to revisit — nothing else in this design depends on
the assumption.

## Decisions

Four decisions were settled before design.

1. **Expanding shells, 5 ly wide, greedy inside each.** Finish every unsurveyed
   system within 5 ly of the innermost unsurveyed one before reaching further;
   inside that band, take the hop nearest the vessel. The guarantee is that no
   hole deeper than one shell width ever persists and the filled sphere grows
   monotonically. 5 ly is a baked constant, not a control.

   The band **slides** — it is anchored on the innermost remaining candidate
   rather than on a fixed grid of annuli around the centre. Both were measured
   and they are within ~8% of each other on travel while holding the same hole
   bound, so the tie is broken on specification: a fixed grid has a boundary
   case (a candidate landing exactly on a grid line opens a double-width band),
   and a sliding band has none. The guarantee becomes exactly true rather than
   true-with-an-asterisk.
2. **No outer radius leash.** With shells growing outward, a radius adds no
   density guarantee that the shells do not already provide, and "survey
   forever" has no finish line to draw. The run ends when the player cancels it.
3. **The stall matrix is unchanged — every reason still halts the run.** An
   auto-skip policy was considered and rejected: it buys unattended uptime at
   the cost of an unstaged vessel touring dozens of systems scanning nothing
   while the run still reads as healthy. A bad system costs a night; a silently
   useless run costs trust in the whole feature.
4. **A mode toggle in the existing launcher**, not a second `DirectiveKind`. The
   behaviour change is one step's worth; a separate kind would duplicate the
   vessel-eligibility rules, the step machine, and the launcher for it.

## Part A — The planner

### A1. `SurveyRoamPlanner`

A new pure namespace in DirectiveEngine beside `SurveyTargetSuggestions` — no
I/O, no clock, no randomness, so it tests as plain function calls over fixtures
the way `SurveyRun`'s stall matrix does:

```swift
public enum SurveyRoamPlanner {
    /// The band thickness — the one dial between travel and density. Wider
    /// approaches greedy nearest-neighbour (cheapest, leaves permanent holes
    /// 22 ly deep); narrower approaches strict radial order (no holes, 3x the
    /// travel). Measured at 5 ly: +35% travel over greedy, buying a filled
    /// radius of 16.4 ly against greedy's 3.9.
    public static let shellWidthLY: Double = 5

    public static func nextTarget(
        centre: Position,
        from vessel: Position,
        stars: [Star],
        attempted: Set<String>,
        shellWidth: Double = shellWidthLY
    ) -> String?
}
```

It must NOT be a static on a SwiftUI `View`: pure logic in that position traps
with signal 5 under `swift test` (see the `swiftui-view-statics-trap-in-tests`
note).

### A2. The shell is derived, never stored

```
candidates = stars where fullyScannedAt == nil, designation ∉ attempted
inner      = min distance(centre, c) over candidates
shellTop   = inner + shellWidth                  // slides; no grid, no boundary case
shell      = candidates within shellTop of the centre
next       = shell member nearest THE VESSEL, ties broken on designation
```

`shellTop` is anchored on `inner`, so the band is always exactly `shellWidth`
thick measured from the nearest thing still to do. That is what makes the hole
bound exact: nothing can be left behind that is more than `shellWidth` closer to
the centre than the system just picked.

Deriving rather than storing a shell index is what makes this self-healing: if
anything else surveys a system — another run, a manual scan, a digest ingest —
the shell recomputes from what is genuinely left. A stored index would drift
against the data and there would be no way to notice.

The centre itself is a candidate, at radius 0. A run started on an unscanned
system therefore surveys that system first, with no travel. This is deliberately
unlike `SurveyTargetSuggestions.nearest`, which excludes its anchor: there the
anchor is the vessel's own position and re-surveying it is not the question,
whereas here the centre is a geometric origin that is usually itself unscanned.

Distance is measured **from the vessel** for the pick and **from the centre**
for shell membership. Both halves matter and they are not the same point: shell
membership is what bounds the holes, and vessel-nearest is what keeps the hop
cheap.

Ranking uses squared distance internally, `sqrt` never being needed for an
ordering — the same reasoning as `SurveyTargetSuggestions`, and it matters more
here because the candidate set is the whole census rather than a shortlist.

### A3. Why `attempted` is load-bearing

`attempted` is not bookkeeping. Without it the derived shell deadlocks, in two
ways that both occur in practice:

- **A system that can never be completed pins the shell forever.**
  `StarSystem.isFullyScanned` requires `planetsTotal > 0` (verified in
  `SystemScanState.swift`), so a genuinely planetless system is never fully
  scanned. It would hold `inner` at its own radius permanently: the run targets
  it, completes nothing, and targets it again on the next extend. The shell
  would never open.
- **Skip has to stick.** Decision 3 keeps every stall halting the run, which
  means the player resolves it with Retry or Skip. Skip advances `targetIndex`
  past the target — but if the next extend recomputes candidates from the census
  alone, it re-picks the very system just skipped. Skip would be a no-op.

`Directive.targets` is already append-only and already records every system the
run has aimed at, so it *is* the set. No new column, and it makes `targets` the
run's history rather than its plan. Growth is ~10 KB per thousand systems at
roughly one system per half-hour, which needs no management.

A consequence to accept: a system skipped for a transient reason is never
retried by this run. Re-surveying it means a new run. That is the same
cheap-direction bias the rest of the survey code documents — a missed system
costs coverage that a later run recovers, whereas a re-picked one can wedge the
shell permanently.

## Part B — Engine integration

### B1. One new column

`Directive.roamCentre: String?` — non-nil means continuous, and its value is the
centre's designation. This is the whole schema change.

A new append-only `SchemaMigration` appended to `GameDatabase.manifest`:

```sql
ALTER TABLE "directives" ADD COLUMN "roamCentre" TEXT
```

Migrations are append-only: never edit, rename, or reorder a shipped one. Unlike
the `fullyScannedAt` backfill, this one *does* change the schema, so the
`GoldenSchemaTests` snapshot regenerates (`RC_REGENERATE_SCHEMA_FIXTURE=1`) and
`SchemaManifestTests`' frozen identifier list gains the new entry.

### B2. `MissionAction.extendQueue(centre:)`

A new case, resolved by `DirectiveEngineCore` rather than `DirectiveExecutor` —
the same split, and for the same reason, as `.refreshDevices`: it needs I/O plus
a second call into the machine, and the executor's job is applying one decided
action to the database.

Bounded identically. A second `.extendQueue` coming back from the re-ask means
the planner found nothing, which resolves to `.done`.

### B3. `SurveyRun.preflight`

The only step that changes. Today an exhausted queue falls through to the
`returnToOrigin` check and then `.done`. The roam branch goes **first**:

```swift
guard let target = directive.currentTarget else {
    if let centre = directive.roamCentre { return .extendQueue(centre: centre) }
    guard directive.returnToOrigin, ... else { return .done }
    return .advanceStep(nextStep: Step.returning)
}
```

A roam run never sets `returnToOrigin`, so the two branches cannot both apply
today — the ordering is documented rather than relied upon, so that a future
"roam, then come home" remains expressible.

Everything after the guard is untouched. In particular the existing
`isFullyScanned` skip still earns its keep: if a stale census makes the planner
pick a system that is actually done, preflight `.advanceTarget`s without taking
the trip.

### B4. `resolveExtendQueue`

Alongside `resolveRefresh` and `resolveSystemRefresh`: one scoped census read,
resolve the centre's and the vessel's positions, run the planner, append the
designation to `targets` in a write, then re-ask.

This needs a real if small extension to the existing pattern. `resolveRefresh`
re-reads the **world** and re-asks with the *same* `directive` value, because a
device refresh cannot change the directive row. `.extendQueue` changes the row
itself, so the re-ask must use a freshly-read `Directive` as well — otherwise
the machine is handed a row whose `targets` still lack the target just appended
and immediately asks to extend again.

The census read happens only when the queue is exhausted, which is once per
surveyed system — tens of minutes apart. It is not on the 5 s tick, so reading
the whole `stars` table is affordable, and the candidate filter stays in the
planner where it is unit-tested rather than being pushed into SQL.

A bounding box around the centre was considered and rejected: the band's outer
edge is `inner + shellWidth`, and `inner` is only known once the candidate set
has been scanned, so bounding it needs the very scan it was meant to avoid.

### B5. The re-ask must apply to the freshly-read row

This is the one genuine trap in the integration, and it is not merely a
signature change. `evaluateOnce` currently hands the *pre-resolution*
`directive` value to `DirectiveExecutor.apply`:

```swift
let stillRunnable = await DirectiveExecutor.apply(action, to: directive, machine: machine)
```

Every executor path builds its update as `var updated = directive`, so applying
a post-extend action to the pre-extend value writes `targets` back to what it
was and **rolls the append straight back**. This bites on the ordinary happy
path, not an edge case: the action after a successful extend is normally
`.assignController`, which goes through `move()` and commits the whole row.

So `.extendQueue`'s resolver returns the action *and* the row it must be applied
to, and `evaluateOnce` carries that row forward:

```swift
/// A resolved action plus the directive row it must be applied to. Only
/// `.extendQueue` needs the second half: it is the one resolver that writes the
/// row, so applying its result to the pre-write value would roll the append
/// back.
private struct Resolution {
    let action: MissionAction
    let directive: Directive
}
```

`resolveRefresh` and `resolveSystemRefresh` are unaffected — a device read
cannot change the directive row, which is exactly why they were able to re-ask
with the same value.

`Position` for a designation comes from the `stars` row. A centre with no census
row yields no plan, which resolves to `.done` — the launcher cannot produce one
(it picks from the census), so this is a defensive path rather than a reachable
state.

## Part C — Surfaces

### C1. Launcher

`NewDirectiveFeature.State` gains `isContinuous: Bool` and `roamCentre: String?`.
The mode toggle swaps the target-queue block for a single centre picker that
defaults to `anchorSystem` (the vessel's current system). The picker reuses the
existing `suggestedTargets` resolver — nearest unscanned to the vessel — so no
new UI logic is introduced.

`canLaunch` becomes mode-dependent: a fixed run still needs a non-empty queue, a
continuous run needs a centre. `launchTapped` writes `roamCentre` and an empty
`targets` for a continuous run.

Designations render in a mono token, per the house rule.

### C2. The row's progress readout

`Directive.progress` returns `(min(targetIndex, count), count)`, which for a
roam run is always "n/n" — `targetIndex` equals `targets.count` for the entire
window between finishing one system and extending onto the next. Rendered as-is
it reads as a finished run.

A roam run reads "23 surveyed" instead. `targetIndex` is the honest count:
`.advanceTarget` bumps it once per finished system, and `targets` is the history
of everything aimed at. The current target is not repeated in the subtitle
because `headlineDesignation` already renders it on the row's first line.

The branch goes on `DirectiveRow`, not in the view. That logic currently sits in
a `private var subtitle` on `DirectiveRowView`, where it cannot be tested at all;
`DirectiveRow` is the list's deliberately SwiftUI-free logic type ("pure logic
hanging off a SwiftUI View traps under `swift test`") and already holds
`headline`, `headlineDesignation`, and `title`. Moving `subtitle` beside them is
where it belonged, and it makes this branch testable.

## What deliberately does not change

The stall matrix, the recall/recovery gate (which is what stops a roam from
stranding drones the way POLARISUM did), `returnToOrigin`, and every
fixed-queue code path. With `roamCentre` nil the engine's behaviour is
byte-identical to today's.

## Testing

**`SurveyRoamPlanner`** — the band slides with `inner` (including `inner == 0`
at the centre); a candidate exactly `shellWidth` beyond `inner` is **in** the
band, one a hair further is out; the pick is vessel-nearest, not centre-nearest,
within the band; a nearer-to-the-vessel candidate *outside* the band is
correctly passed over (the test that distinguishes this design from greedy
nearest-neighbour at all); `attempted` excluded; `fullyScannedAt` excluded; the
centre itself eligible at radius 0; empty candidates yield nil; deterministic
tie-break on designation.

**Growth property** — over a fixture census, simulate N extend-and-complete
cycles and assert the filled radius is monotonically non-decreasing and that no
hole deeper than one shell width ever opens. This is the claim the whole design
rests on, so it is pinned by a test rather than by a one-off simulation. Pair it
with a greedy-nearest-neighbour control over the same fixture that *fails* the
hole bound, so the test is demonstrably measuring the property and not passing
vacuously.

**Deadlock regression** — a planetless system (a `StarSystem` with
`planetsTotal == 0`) in the candidate set must not be re-picked after being
attempted once. This is the failure A3 exists to prevent and it is invisible in
any test that only uses well-formed systems.

**`SurveyRun.preflight`** — exhausted queue with a `roamCentre` yields
`.extendQueue`; exhausted with a nil `roamCentre` still yields `.done` (the
fixed-queue regression); a roam pick that is already fully scanned yields
`.advanceTarget`.

**`DirectiveEngineCore`** — `.extendQueue` appends to `targets` and re-asks
against the **freshly-read row**; a second `.extendQueue` from the re-ask
resolves to `.done`.

**`NewDirectiveFeature`** — continuous mode writes a row with `roamCentre` set
and `targets` empty; fixed mode writes exactly what it writes today; `canLaunch`
respects the mode.

**Migration** — `SchemaManifestTests` identifier list, and the regenerated
`GoldenSchemaTests` snapshot.

Test results are read from Swift Testing's JSON event stream, never by scraping
console text — see the `swift-test-event-stream` skill, including its
multi-target truncation trap and the `--filter` suite-name gotcha.

## Out of scope

- An outer radius leash (decision 2).
- Any auto-skip stall policy (decision 3).
- Global route optimisation (2-opt and friends). Greedy-within-shell is the
  decision, and with travel at a few minutes against a survey's tens of
  minutes there is nothing worth optimising for.
- A user-facing shell-width control.
- Retrying a system this run has already attempted (A3).
- **Multi-vessel coordination.** Two roam runs with overlapping centres each
  pick the same nearest-in-shell target, because neither sees the other's
  `targets`. Cheap to close later by excluding other running directives'
  current targets; deliberately left open until more than one vessel roams.
- Relay Run and the rest of Stage 5.
