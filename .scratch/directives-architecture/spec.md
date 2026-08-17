# Directives architecture — spec

**Date:** 2026-08-16
**Status:** Approved (decisions locked with the operator; execution by a fresh session)
**Source:** the 2026-08-16 architecture audit — https://claude.ai/code/artifact/01f7ea53-da1d-46e1-8c33-0654e459b0ed — read it once for the evidence; this spec carries only the decisions and the reasoning an executor needs.
**Plan:** `.scratch/directives-architecture/plan.md`; tickets under `issues/`.

## Why this effort exists

Of ~150 distinct Directives bugs fixed 2026-07-20 → 2026-08-16, 47% are three mechanical
classes — stale local evidence (24), step-machine clock/guard mechanics (23), tag/lease scoping
(23) — and 14 of them recurred in a second mission after being fixed in a first. The
`MissionStepMachine` seam is deep and correct; below it the missions are shallow bags of statics
that borrow from each other, and the substrate hands them ownerless device-keyed operations and a
`Device.updatedAt` that mixes a server clock and a client clock. Above the seam the brain reads
through mission statics and constructs rows at thirteen sites by hand.

Two operator goals are not additive under that shape: **(A)** printing that scales with the number
of autofactories, and **(B)** replicating vessels into new survey / salvage / relay runs. This effort
gets both, in five stages, each retiring a named bug class before the next begins.

## Locked decisions

Decisions the operator made on 2026-08-16. Do not relitigate; if a ticket seems to need one
reopened, stop and ask.

| # | Decision | Consequence |
|---|---|---|
| D1 | **The `operations` table may change fundamentally**, including schema, as long as every UI surface reading it stays honest (progress bars, Operations Log, Print Queue). | Stage 0 adds ownership columns and writes rows for immediate verbs. Stage 3 may relax the one-live-op index for print benches. |
| D2 | **Per-theatre tags are not local-only.** They may be sent to the server exactly as written. The server does exact match on lowercased strings with no hierarchy. | One canonical `FleetTag` string form; no "root before the wire" convention; a fleet refresh for a scoped tag fetches the scoped and the unscoped form during migration. |
| D3 | **Replication stays human-in-the-loop forever**, but the automation must reduce a Directive-oriented replication to one or two clicks. | Stage 4's StageFleet executor ends at "cradle stowed at depot, replicate is yours" with a stall reason + a Replicate button on the stall panel that pre-fills source and target. No engine `replicate` dispatch. |
| D4 | **Theatre identity may persist.** | Stage 1 adds a `theatres` table making recognition sticky: once a depot is recognised for a system it stays that system's depot until the operator re-pins. `Theatre.id` = the persisted depot designation. |
| D5 | **Not a rewrite.** Stages are independently shippable; each ends with the app running and green. The UX (list, timeline, stall panel, launchers) does not change shape. | Every ticket lands on `main` (or a worktree merged to `main`) with tests. |
| D6 | **`Directive.step` stays a `String` column.** Each machine gets an exhaustive `enum Step: String`; the row is unchanged. | No migration, no cross-kind enum. |
| D7 | Stage 0 keeps **one live op per device**. The N-deep print queue is designed in Stage 3 with the printer's own `print_queue` snapshot as the depth source and op `directiveID` as the owner source. | Bounded blast radius for Stage 0. |

## The five stages

### Stage 0 — Substrate: own the op, fix the clocks

Retires: most of buckets A and B; the two open co-tenant print defects (`RestockRun`,
`EventCourierPrint`); the log-prose parsing in `MissionLogBudget.lastDispatch`; the "deadline
BEFORE read" ordering rule that every mission restates.

Decisions:

- **S0.1 Every dispatch writes an `Operation` row, immediate verbs included.** New nullable
  columns `directiveID TEXT`, `step TEXT`, `paramsDigest TEXT` on `operations` (one appended
  migration). Tracked kinds stamp them on the optimistic insert. Immediate verbs (`stow`, `adopt`,
  `set_directive`, `activate`, `deploy`, `launch`, `recall`, `deactivate`, `attach`, `detach`,
  `configure`, `collect_resources`, `deposit_resources`, every `.simple`) write a row that is
  **already terminal at accept time**: `status: .completed`, `completesAt: nil`, `source:
  .optimistic`, `startedAt = lastConfirmedAt = now`, `detail = {params}`. A 4xx writes the same
  row with `.rejected`; a transport/undeclared-status failure writes `.failed`. UI honesty: the
  Operations Log gains rows it never had (a `stow` you did is now listed) — that is more honest,
  not less. Progress readers use open ops only and are unaffected. `OperationRetention` already
  prunes terminal rows past 7 d.
- **S0.2 The governor de-duplicates.** `CommandGovernorClient.dispatch` gains an optional
  `owner: CommandOwner?` (`directiveID`, `step`, `since: Date`). Before POSTing, if an op exists
  with the same `(directiveID, step, entityCode, kind, paramsDigest)` and `startedAt >= since`,
  return `.deferred(.duplicate)`. The executor treats `.duplicate` like every other deferral: no
  write, no re-stamp, `stepStartedAt` keeps accumulating. `since` is `directive.stepStartedAt`,
  so a Retry (which re-stamps) or a step change re-opens the window. `CommandParams.dedupKey` is
  a canonical JSON of the set fields, sorted keys.
- **S0.3 The arrival is one transaction.** `Reconciler.applyDeviceEvent(event)` closes the open
  op **and** applies the envelope's `location`/stow in the same `database.write`. When the event
  closed an op, the field patch is **unconditional** (the completion is the authority for the row
  it closes). When it did not, the existing guard stays with a one-second tolerance:
  `eventTime.addingTimeInterval(1) >= device.updatedAt`. Event patches stamp `updatedAt = now`
  (client clock) — an event *is* an observation of the row, and every mission watermark compares
  against client-clock `stepStartedAt`. `GameSync.deviceRoute` calls the combined method; the
  print-completed clone read and the post-close `.high` read stay where they are, *after* the
  transaction.
- **S0.4 Reads never re-stamp the mission's own clock.** `DirectiveExecutor.move` gains
  `restamp: Bool`; the four best-effort read/housekeeping actions (`.refreshSystem`,
  `.scanSystem`, `.refreshBody`, `.setDeviceTags`) and the `.refreshFootprint` fallback pass
  `restamp: nextStep != directive.step`. `.dispatch` applies the same rule: it re-stamps when it
  names a different step, and leaves the clock alone when it names its own, because a dispatch
  into the current step is not a transition. S0.2 requires this — `since` is
  `directive.stepStartedAt`, so an unconditional re-stamp pushes the de-dup window past the row
  the dispatch just wrote and no repeat can ever match. `.advanceStep`, `.assignController`,
  `.claimRelay` and `.advanceTarget` keep re-stamping unconditionally (a real transition starts a
  new deadline). A step that dispatches into itself and also carries a deadline must measure that
  deadline from its own progress witness rather than from `stepStartedAt`: `EventRun.printing`
  measures from the newest print op it still holds open.
- **S0.5 `.failed` is not `.rejected`.** A transport error or undeclared status is transient.
  The executor counts this directive's `.failed` ops in the current step since `stepStartedAt`;
  below `DirectiveExecutor.failedDispatchBudget = 3` it logs and returns `true` (wait); at the
  budget it stalls with a new reason `.commandFailed` (`brainDisposition: .retry`,
  `displayName: "Command failed"`, guidance: transient server error, retry).
  Two carve-outs, both found while building this: a failure that wrote **no** `Operation` row is
  not transient — the count cannot advance, so the executor stalls on the first tick rather than
  retrying a malformed request forever. And `DirectiveExecutor.nonRetryableKinds` (`print`,
  `dequeuePrint`, `collectResources`, `depositResources`) stall immediately, because a `.failed`
  here often means the command landed and only the response was lost — this API's default
  `ErrorSchema` forbids the `error` key the server actually sends, so every undeclared status
  throws a decode error — and repeating those four spends materials, double-transfers cargo, or
  dequeues a different job. `.commandFailed` is `brainDisposition: .retry`, so the brain's own
  budgeted retry still applies to them, and it re-reads the world first.
  Worst case for a retryable verb against a persistent failure is 16 dispatch attempts: the brain
  re-stamps `stepStartedAt`, so each of its 3 retries opens a fresh 4-attempt window.
- **S0.6 The snapshot answers ownership and freshness.** `WorldSnapshot.openOperation(for
  deviceCode: String, owner directiveID: String?)` returns the device's live op only if its
  `directiveID` matches (nil owner = today's behaviour). `WorldSnapshot.dispatchedOperations`
  is read by `directiveID` column with the legacy log-join as a fallback for rows written before
  the migration. `WorldSnapshot.isFresh(_ device: Device, since: Date) -> Bool` is
  `device.updatedAt >= since`. `RestockRun.stocking` and `EventCourierPrint`'s printer guard use
  the owner-aware overload with the deadline checked **above** the guard (the `1994d07` /
  `75ca544` shape).
- **S0.7 Reads leave the SSE dispatch path.** In `GameSync.deviceRoute`, the post-close `.high`
  read and the print-clone read become `deviceStaleness.markStale(code, event.event)` marks
  drained by the existing tracker at its `.high` tier, so a burst of events never serialises
  behind network reads. Only if the tracker cannot express "read this new device code that has
  no row yet" does the clone read stay inline. This is the last Stage 0 ticket and may be deferred
  to Stage 2 if it destabilises catch-up.

### Stage 1 — Typed vocabulary

Retires: bucket C's three top patterns; the launcher/brain `theatreDepot` gap; the survey /
salvage bare-fallback hole; the three owning-status copies; `DirectiveStallDetail`'s prefix parse.

Decisions:

- **S1.1 `FleetTag`** lives in `GameModels`. `goal: Goal` (`haul`, `survey`, `salvage`, `mine`,
  `carrier`, `event`, `tendMesh`, raw values lowercase, `tendMesh` → `"tendmesh"`); `scope:
  Scope?` where `Scope` is `.theatre(depot: String)` or `.belt(designation: String)`; `init?
  (parsing: String)`; `var string: String` = `"auto:<goal>[:<scope>]"` all lowercased (the
  server lowercases anyway — D2). `var unscoped: FleetTag`. `Device.fleetTags: [FleetTag]` and
  `Device.carries(_ tag: FleetTag, policy: FleetTag.MatchPolicy) -> Bool` with `.exact` and
  `.exactOrUnscoped`. `mine` ferry tags use `.belt`; the other goals use `.theatre`. Six
  formatters and seven parsers named in the audit collapse onto this type; `auto:carrier` has one
  definition.
- **S1.2 Ownership is one function.** `Ownership.resolve(directives:devices:theatres:) ->
  Ownership` in `DirectiveEngine`, `Holder = .row(directiveID: String, via: Via)` with `Via ∈
  {deviceCode, controllerCode, freighterCode, fleetTag, stow, attach, adoption}`.
  `reserved: Set<String>`, `reserved(in theatre: Theatre) -> Set<String>` (a scoped-tag lease
  reserves only inside its theatre; an unscoped-tag lease reserves account-wide and is reported
  as such), `holder(of:) -> Holder?`. `Brain.reservedDevices`, `holdingDirective`,
  `unmigratedHold`, `DirectiveRow.merge`'s owners, `DeviceListAttention.covers`,
  `DirectiveGroup.missionKeys` become views over it. `Brain.owningStatuses` and
  `DirectiveRow.owningStatuses` are deleted in favour of `DirectiveStatus.openCases`.
- **S1.3 One theatre resolver.** `WorldSnapshot.owningTheatre(of:)` and
  `WorldView.owningTheatre(of:)` become one function on a shared `TheatreResolver` value both
  hold; rule stated once: **an explicit scoped tag outranks location; location decides only for
  unscoped devices**. `SurveyRun`/`SalvageRun`/`RepairFleet.answers` adopt `HaulRun.belongs`'s
  rule through `FleetTag.MatchPolicy`. `Brain.adoptTheatres` uses the same resolver.
- **S1.4 One row factory.** `Directive.launch(kind:deviceCode:theatre:targets:...)` in
  `DirectiveEngine` owns `id`, `status: .running`, `targetIndex: 0`, `step:
  MissionRegistry.firstStep(for:)`, `stepStartedAt/createdAt/updatedAt: now`,
  `theatreDepot`, and `fleetTag` (per-kind rule inside the factory). All thirteen construction
  sites call it. The three sheet launchers stamp `theatreDepot`; Print Mine Fleet stamps the
  per-theatre mine tag; the two dialog launchers gain a theatre picker when more than one theatre
  is operational (default: the theatre of the selected device's location).
- **S1.5 Per-machine `enum Step: String, CaseIterable`.** `nextAction` switches over
  `Step(rawValue: directive.step)`; an unknown string is `.wait` in every machine (the four that
  reset to first step today change to `.wait` and log). Column unchanged (D6).
- **S1.6 Typed log columns.** `DirectiveLogEntry` gains `commandKind TEXT`, `targetDeviceCode
  TEXT`, `detail TEXT` (one appended migration). `DirectiveExecutor` writes them; the summary
  string stays for display. `MissionLogBudget.dispatchRounds(kind:)` and `lastDispatch` read the
  columns; `DirectiveStallDetail` reads `detail`.
- **S1.7 Persistent theatre identity.** New table `theatres (depot TEXT PRIMARY KEY, system TEXT
  NOT NULL, origin TEXT NOT NULL, establishedAt TEXT NOT NULL)`. `TheatreRegistry.recognise`
  takes the persisted rows; for `.systemHub`/`.derived` a system that already has a persisted
  depot keeps it (sticky) instead of re-deriving "richest stocked location"; a newly recognised
  depot is persisted by the brain tick (one write site, `Brain.persistTheatres`). Pins still win
  and re-pinning rewrites the row.
- **S1.8 `HaulRun.deliveryLocation` literal is retired from the UI.** `DirectiveRow`/
  `DirectiveTargetsSection` read the row's `theatreDepot` (always stamped after S1.4).

### Stage 2 — Step library

Retires: the copy-propagation mechanism; ~12 travel frames, ~13 hand ladders, 4 return-homes,
5 tag rules, 4 log walkers; `SalvageRun` as accidental library.

Shape (design; the plan is written by ticket 17):

- New module-internal namespace `MissionSteps` in `DirectiveEngine` with typed sub-machines,
  each a pure value with `func next(_ ctx: StepContext) -> StepResult` where `StepResult` is
  `.action(MissionAction)` or `.finished`. Sub-machines: `TravelTo(destination:, deviceCode:,
  arrivalTest: .system|.exactLocation)`, `ConfirmRow(deviceCodes:, predicate:, deadline:,
  thenStall:)` (the ladder, deadline first), `PrintJob(deviceType:, at depot:, owner:)`
  (select via Stage 3's chooser once it exists; until then `MineFleetPrint.printer`),
  `StowOrAttach(device:, into carrier:, verb:)`, `BotPhase(owner:, vessel:, phase: .deploy|.arm|
  .await|.recall)`, `ReturnHome(deviceCode:, destination:)`.
- Composition: a mission's `Step` case maps to one sub-machine plus an exit; missions keep bespoke
  cores (Survey launch/await/confirm/scan; Salvage nextBody/configure/verify/sameBodyAgain; Haul
  planner/assign/confirm; Relay reclaim + FIFO claim; Mine adopt/arm ordering; Event blueprint
  closure/loading/commit/sweep).
- Migration order: Survey/Salvage bot phase first (2×~200 lines → one `BotPhase`), then travel
  legs + return-home, then confirm ladders, then the four print-only kinds onto `PrintJob`.
  Every migration keeps the mission's existing test suite green before adding sub-machine tests.
- Constants (`printDeadline`, `stowDeadline`, `botDispatchRounds`, `pollInterval`…) move onto the
  sub-machine that uses them; sibling static references (`RelayRun→SalvageRun` ×17 etc.) go to
  zero.

### Stage 3 — Print scheduler (goal A)

Shape (design; the plan is written by ticket 18):

- `PrintScheduler` in `DirectiveEngine`: `benches(at depot: String, in world: WorldSnapshot) ->
  [Bench]` where `Bench = (device: Device, activeJob: Operation?, queueDepth: Int, owners:
  [directiveID])`; depth from the printer's `print_queue` snapshot, owners from op `directiveID`
  (S0.1). `choose(job: PrintJob, at depot:, in world:) -> Device?` prefers a free bench, then the
  shallowest queue, deterministic tie-break by device code. All five enqueue sites call it.
- Index decision (D7): relax `operation_one_open_per_device` to `WHERE status = 'active'` so N
  `enqueued` prints coexist per bench; audit `Reconciler.completeOpenOperation` (which live op a
  `print.completed` closes → match by `detail.params.device_type` then oldest), `WorldSnapshot.
  openOperations` (becomes "the active op"; add `queuedOperations`), `DeadlineScheduler` (active-
  only, unaffected).
- Demand aggregation: `RestockRun` demand and `MineFleetPrint`'s recipe shortfall are computed per
  theatre and dispatched one job per free bench per tick (the `EventRun.printing` shape).
  `RestockRun.idleCap` scales with bench count.
- `PrintQueueFeature` shows the owning run for each queued job (join on `operations.directiveID`).

### Stage 4 — StageFleet executor + growFleet (goal B)

Shape (design; the plan is written by ticket 19):

- `FleetRecipe` (generalising `MineRecipe`): `carrierType`, `carried: [DeviceType: Int]`,
  `controllerType`, `adopts: [DeviceType]`, `tag: FleetTag`. Recipes for survey, salvage, relay-
  carrier, mine.
- `StageFleetRun` (new `DirectiveKind.stageFleet`): print the recipe at the depot (Stage 3
  scheduler) → stow carried devices into the carrier → adopt drones under the controller (the
  `MineRun.adopting` shape) → tag everything with the recipe's scoped tag → if the recipe wants a
  replicant: print `empty_replicant_matrix` + `matrix_container`, stow the cradle, stall
  `.awaitingCourierReplication` with a **Replicate** action on the stall panel that opens the
  existing replicate flow pre-filled (D3) → on Retry, confirm the replicant is hosted → done.
- Brain `growFleet` goal: derives demand from readiness idles (`surveyReadiness == .idle(no
  vessel)` etc.), launches `stageFleet` per theatre subject to the reserve rail, at most one in
  flight per theatre.
- Theatre bootstrap: a `stageFleet` for a new theatre is launched at an existing depot; the
  operator pins the destination (`EstablishTheatreSheet`); the staged carrier's first run is a
  `relayRun`/`haulRun` toward the pin.

## Invariants every ticket keeps

- `MissionStepMachine` stays pure: no I/O, `world.now` only, one action per evaluation.
- `DirectiveExecutor` stays the single write site; one transaction per transition.
- The `paid`-set refresh bound in `DirectiveEngineCore.reAsk` is untouched.
- `DirectiveAttentionReason` stays a closed enum with its three co-located switches.
- The brain launches and retires; it does not enact. (`rehomeHaulRuns`'s live-row rewrite is
  grandfathered until Stage 1's `Ownership` makes it unnecessary.)
- Migrations are append-only; `SchemaManifestTests` + `GoldenSchemaTests` regenerate only when
  the change is intended.

## Out of scope

- Any change to the list/timeline/stall-panel UX shape.
- Replacing the 5 s tick or the per-directive `WorldSnapshot.read` (a shared per-tick world is a
  Stage 3/4 performance ticket, added when bench count multiplies rows).
- Server-side changes.
