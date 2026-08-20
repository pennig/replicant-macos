# Directives Architecture — punch list

Small things deliberately not fixed when they were found, kept here so they are not lost between stages. Work the list at the end of the effort; anything still open then is either done or consciously dropped.

**Maintaining it.** When a review defers something, add a line: what it is, where (`file:line`), which stage found it, and why it was deferred. Tick the box when it lands, and say in the commit which item it closed. Do not delete a line to close it — a ticked line is the record that someone decided. If an item turns out to be wrong or no longer real, tick it and say so.

**Not for this list:** anything that blocks a merge, anything that changes behaviour a mission depends on, and anything a stage's own ticket already covers. Those belong in a ticket.

---

## Needs a human decision

- [x] **DONE (ticket 47): `MineFleetPrint.stocking` has no deadline above its open-op guard — now moot.** Ticket 38 (`d3713f5`) deleted `stocking`'s open-op guard entirely: it fans out through `PrintScheduler.choose`/`onOrder` and re-enters itself, dispatching or waiting on scheduler availability rather than gating on any op. There is no guard left for a deadline to sit above. `printing` (the step that follows) already holds `PrintJob.deadline`, so a co-tenant parking a shared bench is bounded there instead.
- [ ] **automation-brain ticket 14 (RestockRun over-print race) is still open.** Stage 0 declined to close it: the ownership and ordering fixes did not touch the clone-row-lag race it describes. It now carries a cross-reference. Decide whether it belongs in a later stage of this effort or stays where it is.

- [ ] **`SurveyRun.wearsFleetTag` / `SalvageRun.wearsFleetTag` are still the pre-ticket-12 rule under a
  new name, and the obvious fix is a diagnostic regression.** The Stage 1 fix wave was asked to route both
  through `FleetMembership.belongs` and STOPPED: `belongs` places a BARE-tagged device by location, so an
  unplaceable one (stowed, mid-cruise, off-census) belongs to no theatre and vanishes from both pools
  these feed. That breaks six shipped tests / nine assertions which pin the opposite on purpose —
  `BrainSurveyTests.aTaggedStowedVesselIsNamedNotReportedUntagged`,
  `.locationlessMistaggedDeviceIsStillNamedAcrossTheatres`, `.mistaggedOnlyFleetNamesTheDevice`,
  `.untaggedHullsAndMistaggedDeviceAreBothNamed` and the two salvage twins. The finding counted two
  callers; there are four (`Brain.swift`, the `mistagged` and `unreachable` filters in
  `salvageReadiness` and `surveyCarrierBlocker`), and the two it did not count are the ones that break.
  Silencing them costs the operator exactly the un-migrated bare-tagged fleet — the live fleet's actual
  state, and the population `unmigratedNote` is written for. The disagreement the finding names is real
  (a device wearing both `auto:survey` and `auto:survey:DEPOT-B` reads as A's here and B's under
  `belongs`); closing it without the regression needs a THIRD predicate — "belongs to this theatre, OR is
  a bare-tagged orphan no theatre can place" — which is a rule to sanction, not a refactor to do
  silently. Decide the rule; the haul side already got its `unreachable` diagnostic in the fix wave
  built on the tag-family pool, matching its two siblings.

- [ ] **A sticky theatre depot that runs dry parks its runs silently and cannot self-heal.** Stage 1
  ticket 16 made recognition sticky per system, and the proviso deliberately tests print-capability and
  not stock (spec §S1.7). So a depot at zero stock keeps the theatre and reads
  `.claimed(missing: [.noStock])` where the old rule would have handed the theatre to a stocked sibling in
  the same system. `readiness` is honest; the run is not — with a second theatre operational,
  `theatreWentClaimed` sends seven mission guards to `.wait` (`HaulRun` ×2, `RelayRun`, `EventRun` ×2,
  `MineRun`, `SalvageRun`) with no stall, no `attentionReason` and no operator surface, and nothing can
  restock it because the brain allocates only over operational theatres and the haul run that would refill
  the depot is itself a waiter. Net still better than the old rule, which fired the same silent wait on
  any stock *shuffle* rather than only on a depot going fully dry. Sits beside the parked
  `theatre-readiness-starves-richer-depots` note. **The cheapest middle path is not changing the sticky
  rule but giving `.claimed(missing: [.noStock])` on a sticky depot a visible surface.**

- [ ] **Two membership rules disagree about a device wearing an unscoped AND a foreign scoped tag.**
  `SurveyRun.wearsFleetTag`/`SalvageRun.wearsFleetTag` (`carries(_, .exactOrUnscoped)`) call it this
  theatre's; `FleetMembership.belongs` calls it the other theatre's. Stage 1's final review asked for the
  first to be routed through the second, and that was tried and reverted: `belongs` places a bare-tagged
  device by location, so a stowed or mid-cruise one belongs to no theatre and vanishes from both
  diagnostic pools — which exist precisely to name an un-migrated bare-tagged vessel the operator can act
  on. Applying it failed 9 assertions across 6 tests that pin the opposite deliberately. All four callers
  are diagnostic-only, so the live cost today is a misattributed idle reason. **Resolving it properly needs
  a third rule** — "this theatre's member, OR a bare-tagged orphan no theatre can place" — which is a
  design decision, not a refactor.

## Measurements owed

- [ ] **Ticket 08's live-stream lag numbers.** The ≥500-event replay proves the route body makes zero network calls; the before/after `EventPipeline` lag under a real stream was never measured, because it needs a logged-in app. Collect during Checkpoint A from the OSLog `catch-up …` lines.
- [ ] **Watch item for Checkpoint A: a stale observation stamped fresh.** `Reconciler.applyDeviceEvent` stamps `updatedAt = now` on the op-closing path regardless of the event's age (spec S0.3, deliberate), and Stage 0 made `isFresh` the single freshness predicate at eleven confirm gates. After an SSE backlog an hours-old observation reads fresh. The tell is a `.stepStarted` immediately following a burst of replayed events with no read between them.

## Robustness

- [ ] **A dropped optimistic row is indistinguishable from "never dispatched".** `CommandClient`'s immediate-branch insert uses `try? await database.write`. Largely defused — the failure counter now compares before/after rather than testing for zero — but the underlying silent drop remains. Consider whether that write should be allowed to fail quietly at all.
- [ ] **The visible-ordinary staleness tier has no per-mark backoff.** A demoted urgent mark, or any never-satisfiable visible mark, still gets one `.low` read every pass forever. The coordinator's TTL does not suppress at that spacing; only the reads-budget floor does. `StalenessTracker.swift`. Strictly better than the old `.high` firehose it replaced, which could starve the budget.
- [ ] **`markNew`'s "rides the periodic loop only" property is not enforced in code.** It delegates to `markUrgent`, so it inherits the visible self-trigger; the property holds only because `visible` can contain at most one code and never a not-yet-known clone. Inert today. Re-examine if `markNew` gains a second caller. `StalenessTracker.swift`.
- [ ] **`EventRun.printing`'s progress witness falls back to `stepStartedAt` when the run holds no open print op.** Reachable when another directive occupies every printer at the depot. The fallback measures genuinely blocked time rather than working time, so it is defensible, but it is the old wide-window behaviour in a narrower case. `EventRun.swift`.
- [ ] **`MineFleetPrint.fleetEvidenceIsStale` became a weaker gate.** It compares `newest < stepStartedAt`, and with same-step dispatches no longer re-stamping that clock it forces fewer fleet sweeps. The risk is a duplicate order, never a false stall. `MineFleetPrint.swift`.

- [ ] **A scoped `.refreshFleet` now costs two API reads.** Stage 1 ticket 10 made a scoped fleet refresh
  fetch both the scoped and the unscoped tag so a half-migrated fleet is fully refreshed. `SalvageRun`
  issues it inside throttled loops (`SalvageRun.swift` `awaitCompletion`, `verify`), so a theatre-scoped
  salvage row doubles its reads-budget spend. Per `theatre-aware-readiness-build.md` the scoped form
  currently answers with an empty device list on the live account, so until the fleet is re-tagged
  server-side one of the two reads is pure cost. Sanctioned by ticket 10's stated exception; revisit
  once the fleet carries scoped tags.
- [ ] **`Brain.unmigratedNote` shows the operator a lowercase tag.** It says re-tag it
  `auto:haul:ainalram-belt-1` where designations render uppercase everywhere else in the UI.
  `Brain.swift` (`unmigratedNote`). The canonical tag form is lowercase per D2 and the string is what
  the operator must literally type, so this may be correct as-is — it is a UI consistency question, and
  no test asserts either form.

- [ ] **`DeviceListAttention.covers` resolves over a synthetic one-device fleet.** Stage 1's final review
  established what this actually does, correcting an earlier framing here: `Ownership.dragEdges` drops any
  edge whose target is absent from the dictionary, so with one device present the join fires on the row's
  own columns **plus one hop down** stow/attach/adoption from them. That widening was accepted
  deliberately — a drone aboard a stalled run's carrier is worth flagging — and is now documented and
  tested. What remains deferred is the shape: a named seeds-only entry point on `Ownership` would be safer
  than a `resolve` over a synthetic fleet, whose behaviour depends on which endpoint happens to be in the
  dictionary. `DeviceListAttention.swift`.
- [ ] **`DirectiveGroup.missionKeys` still hand-writes the `.deviceCode` seed.** Stage 1 ticket 11 left
  it alone deliberately: folding it into `Ownership` would change behaviour, because `missionKeys` is
  first-wins in newest-first row order while `holders(of:)` is id-ordered. `DirectiveGroup.swift`.
  The last hand-written lease seed in the tree.
- [ ] **`covers` and `DirectiveRow.merge` now allocate per render.** `covers` builds several
  dictionaries and runs a sort per (device × flagged directive) on a list-render path; `merge` went from
  O(rows) to O(rows × devices). Almost certainly fine at current fleet sizes, and offset by
  `holdingDirective` shedding an O(rows² × devices) loop — but both are UI paths that used to be
  trivial. Measure before assuming.

- [ ] **A scoped-tagged repair bot silently stops answering a bare-tagged row.** Stage 1 ticket 12 made
  `RepairFleet.answers` one-directionally root-tolerant, as specified. During migration a live row whose
  `fleetTag` is unscoped loses any bot an operator has already given a per-theatre tag, and the
  degradation is silent: `deployBots` returns `.advanceStep` and `awaitRepair` advances to stowing, with
  no stall and no log line, so the run simply never repairs. Needs both a bare-tagged live row and
  hand-scoped bots, and nothing in the codebase writes scoped tags onto service bots — operator-triggered
  only. `RepairFleet.swift`; `survey-repair-fleet-tag.md` already warns this failure is silent.
- [ ] **The tendMesh grow path does not get the per-theatre lease property.** `Brain`'s grow pass and
  `commitBlocker` both derive leases account-wide, so S1.2's "a scoped lease elsewhere leaves the carrier
  spendable" does not reach it. Structural for the grow pass — the reserved set is computed before a
  ranked walk that resolves a different theatre per candidate — but `commitBlocker` had a `Theatre` a
  frame up. Ticket-11 residue surfaced by ticket 12's review. `Brain.swift`.
- [ ] **`TagsEditor` accepts free text, so an operator can hand-type an ungrammatical or over-scoped tag.**
  No grammar validation. `auto:carrier:DEPOT-A` parses as a scoped carrier tag, and `.exact` matching then
  reads the device as untagged, silently dropping it from the carrier pool. Since ticket 10 closed the
  `Goal` enum, `auto:other` is likewise no longer a fleet tag anywhere. Pre-existing, not a regression,
  but it is the case that would make several deliberately-dead scoped branches live.
  `DevicesFeature/Sources/TagsEditor.swift`.

- [ ] **No test exercises a migration against a populated pre-migration database.** `GoldenSchemaTests`
  dumps `GameDatabase.bootstrap()`, which is a fresh schema, so an `ALTER TABLE` that would fail on a real
  upgrade from the previous last migration is not covered. Applies to every migration in the repo, not
  only Stage 1 ticket 15's — surfaced by that ticket's review. The live database is the only thing
  currently testing the upgrade path.
- [ ] **Stage 2 must delete three prose fallbacks, not two.** `MissionLogBudget.lastDispatch`,
  `MissionLogBudget.dispatchRounds(kind:)` and `DirectiveStallDetail.detail(for:in:)` each keep a legacy
  parse for rows written before ticket 15's columns, each marked with a one-line comment. Whoever plans
  Stage 2 (ticket 17) should count three.

- [ ] **`HaulRun.deliveryLocation` still exists in the engine.** Stage 1 ticket 13 retired it from the UI,
  which is what spec §S1.8 asks, and deferred the engine half deliberately. Three production readers
  remain — `HaulRun.deliverySink`'s fallback, `HaulRun.hasTakenSomeHaulConfig`, `MineRun.isInForce` — plus
  eight `deliverySink` call sites and ~42 test lines. Deleting it makes `plans()` return `[]` for a nil
  sink and `assign` fall through to `.advanceStep(.hauling)`: a silent no-op cycle, no stall. It cannot go
  until legacy unstamped rows are drained, and nothing drains them today.
- [ ] **Nothing backfills `theatreDepot` on legacy directive rows.** `Brain.adoptTheatres` stamps only via
  `originDesignation` or when exactly one theatre is operational, and no migration fills the column, so a
  row launched before Stage 1 with neither can stay unstamped forever. Blocks the item above.
- [ ] **`NewHaulRunFeature`'s sheet renders "no theatre" while it resolves.** `deliveryDepot` starts nil,
  so for the duration of the `.task` read the sheet briefly asserts something false. A distinct
  "resolving" state, or hiding the row until resolved, would avoid it.
- [ ] **The theatre picker's hint drops one of its claims.** When a preferred depot exists `pickerHint`
  names only that rule and stops mentioning designation order, which still governs the remaining buttons.
  Cosmetic. `DirectivesFeature.swift`.

- [ ] **`.noHaulControllerTagged` is still the wrong words on the mission side.** Stage 1 gave
  `Brain.haulReadiness` the "tagged but not placeable" branch its survey and salvage siblings already had,
  so the launch-path idle reason is now true. But a *running* row whose controller stows or goes mid-cruise
  still stalls `.noHaulControllerTagged` through `HaulRun.preflight`/`assign`, whose theatre-scoped
  `controllers(in:tag:theatreDepot:)` drops it — and the controller plainly is tagged. Pre-existing and
  unchanged by Stage 1. Re-pointing the enum reaches `brainDisposition`, `guidance` and the stall panel, so
  it is a deliberate change rather than a rename. `HaulRun.swift`.

## Constants and coupling

- [ ] **`unresolvedReadBand` is tied to the engine tick by comment only.** The band (15 s) must exceed the worst observed tick period; the tick literal lives separately in `DirectiveEngine.swift`. Changing the tick silently breaks the pairing. Give them one shared constant, or a test that fails when they diverge.
- [ ] **The 60-second unresolved-retry window is an uncalibrated default.** Chosen without measurement. Tune against real API latency, or record it as a tunable with its bounds the way the other calibrations are.

## Tests

- [ ] **`StalenessTrackerTests.urgentMarkOnAVisibleDeviceSelfTriggersADrain` is flaky under a narrow `--filter`.** Its 200-yield spin is too short for an actor hop plus a GRDB read; it passes in full-target runs. It cannot produce a false green. Fix it early anyway — RED checks are run with exactly that filter, so the next person meets a red test that is not theirs. Replace the spin with a `confirmation` or an awaited drain handle.
- [ ] **`RestockRunTests` lacks an "own print open, past the deadline" case.** The courier suite has the matching one. No functional gap — the deadline check runs unconditionally before the op guard — but only one of the two runs pins the ordering that Stage 0 fixed.
- [ ] **The catch-up replay test's `processed` counter asserts nothing.** It is trivially true regardless of route behaviour; `markedOrdinary.value.count` carries the real proof. Drop it or make it mean something. `GameSyncTests.swift`.
- [ ] **The arrival atomicity test reads the op and the device separately.** Atomicity is guaranteed structurally by the single `database.write`, so the test is weaker than the guarantee rather than wrong. `ReconcilerDeviceEventTests.swift`.

- [ ] **`OwnershipTests.perTheatreTagsCannotCollide` asserts only the negative.** No positive companion,
  so it proves a collision does not happen without proving the non-colliding case still matches.
  Faithful to the `Brain.reservedDevices` test it was ported from, so not a regression — the weakest of
  the fourteen ported cases.

- [ ] **`MineRun` and `SurveyRun` have no unknown-step test.** Stage 1 ticket 14 gave all nine machines one
  unknown-step policy (`.wait` plus a log line) and added tests for seven of them. These two were already
  `.wait` before the ticket, so their behaviour did not change and the gap predates the effort — but the
  rule is unenforced on them. One test each, matching the seven that exist.

- [ ] **`TheatreRegistry`'s `.derived` tier resolves two persisted systems in one mesh component by
  `.min()` on designation, and that tie-break is untested.** The loop is per mesh component while the
  sticky rule is per system, so the code had to invent a rule the spec does not define. Reachable only via
  a removed pin or a vanished hub. `TheatreRegistry.swift`. **Still open after the Stage 1 fix wave**:
  re-pinning `aForeignRecordIsIgnored` on the per-system key was expected to close this for free and does
  not — `.min()` → `.max()` leaves all 1,499 `DirectiveEngineTests` green, because the fixture holds one
  record, so the filtered set never has two elements. Reaching it needs two systems in ONE component,
  each with its own persisted print-capable depot.

## Cosmetic

- [ ] **`completeOpenOperation`'s `logger.notice` diagnostics are absent from the device-event path.** Inlining the op-close into `applyDeviceEvent` dropped the kind-mismatch and stale-time rejection lines. No behaviour depends on them; they are the lines that would explain a silent non-close. `Reconciler.swift`.
- [ ] **The `print.completed` clone read no longer runs when an event carries no device code.** Stage 0 hoisted the `deviceCode` guard above it and later kept the mark inside that guard deliberately. Unreachable in practice — print completions always carry a code.
- [ ] **`DirectiveExecutor.move`'s doc comment is 13 `///` lines against a 3-line budget.** Inherited, not grown by this effort, and `check-comments.sh` cannot see it.
- [ ] **`DirectiveEngineCore.collapse`'s doc is a 4-line `///`.** Same class, adjacent to code Stage 0 touched.
- [ ] **`GameModels.Operation` is fully qualified in one test file and bare in its sibling.** Cosmetic inconsistency between `DirectiveEngineTests` and `CommandDedupTests`.
- [ ] **Every `.dispatch` tick now runs one extra `SELECT count(*)`.** The failure counter reads before and after. Small, but it is per tick for the life of a step that defers every tick. Measure before assuming it is free.

## Stage 2 — tickets 20-23

- [ ] **`BotPhase.recallArrival` has ONE caller that is not a bot phase, not two** (corrected by ticket 32). `SalvageRun.swift:630`, the "mining done, drones still out" branch. The `SurveyRun.swift:499` caller the original entry named is gone — ticket 29 replaced it with `ladder.waitsOutArrival = true`, and `Steps/ConfirmRow.swift:70` now inlines the identical `rows.compactMap(\.activityDeadline).max()`. Ticket 32 ruled the rehome optional at one caller and left it: `BotPhase.swift:233` uses it itself, so the namespace is not wrong, and a neutral home for one call would be a new namespace holding one line. Revisit only if a third caller appears.
- [ ] **`BotPhase.withoutLocation` re-checks a deadline `confirmRecall` has already checked.** `Steps/BotPhase.swift`. Provably dead in that path; faithful to the original bodies, which had the same shape. Harmless.
- [ ] **`.repairing`'s `case .finished, .more:` arm is half dead in both missions.** `SurveyRun.swift:168`, `SalvageRun.swift:146`. `BotPhase.awaitRepair` never returns `.more` — every non-action exit is `.finished`. Both arms go to the same destination, so it costs nothing but obscures that `.more` cannot happen here.
- [ ] **`.noSubject` is unreachable from both missions.** Each `nextAction` already guards `world.device(directive.deviceCode)` and stalls `.unreachableDevice` before `ctx` is built, so `BotPhase`'s missing-vessel branch never fires. Mapping it to the same stall is correct and consistent; it is simply dead in these two callers, and may be live for a mission a later task migrates.
- [ ] **`StepResult.swift` imports `Foundation` without using it.** Only `MissionAction` is referenced. Copied verbatim from the plan's code block.
- [ ] **The two-bot fixtures' already-deployed bot is not mechanically load-bearing.** `BotPhaseTests.deployGivesUpWithABotAlreadyDeployed` and `SurveyRunRepairTests.theDeployLoopGivesUpWithABotAlreadyDeployedRoutesToArming` both genuinely fail pre-fix, but on the assertion's value rather than on the deployed bot's presence — `deploy` never reads that bot on the path it takes. Their doc comments overstate what the fixture element does. Worth tightening if a future task touches them.
- [ ] **`SurveyRun.recallDeadline` and `BotPhase.recallDeadline` both hold `20 * 60` with nothing linking them.** `SurveyRun` keeps its own because `recover` needs it; the plan accepted the duplication and asked for the trailing comment that is now there. Tuning one no longer moves the other, which is the improvement AND the risk.

## Stage 2 — ticket 28

- [ ] **`RelayRun.carrierRetainsAuthority` (`RelayRun.swift:601`) was left hand-rolled.** Its watermark is two-sided — a row must be both AFTER the step start AND younger than `reclaimFreshness` — and `ConfirmRow.Watermark` has no two-sided case. One site does not justify a fifth case; ruling from the controller was to leave it alone.
- [ ] **`RelayRun.confirmSource` (`RelayRun.swift:454`) was left hand-rolled — a real fit failure, not a style choice.** Every stale-row read it issues carries `thenStall: .unreachableDevice` with no deadline gating it; `ConfirmRow`'s throttle-triggered read is hardcoded to `thenStall: nil` and can only carry a stall reason via `.readThenStall` at deadline expiry, which a `deadline: .infinity` site can never reach. `RelayRunReclaimTests.reclaimSourceConfirmsThenDeactivates` pins the old `.unreachableDevice` exactly, so the migration was reverted rather than the test edited. Also carries a missing deadline — see below.
- [ ] **Three sites have no deadline today** (`deadline: .infinity, onExpiry: .judge` was used rather than inventing one):
  - `RelayRun.confirmSource`, `RelayRun.swift:454` — bounded only by the engine's `paid`-set collapse (this site is unmigrated — see above — but the missing bound stands regardless).
  - `SurveyRun.awaitCompletion`, `SurveyRun.swift:396` — same.
  - `SalvageRun.awaitCompletion`, `SalvageRun.swift:579` — unbounded by design ("never stall, however long the cycle runs"); its throttle advances only on a successful read, so a persistently failing fleet read spends one `.refreshFleet` per tick forever. Accepted cost, not a bug.
- [ ] **`HaulRun.confirm` (`HaulRun.swift:365`) has an exact-equality deadline gap at the collapse.** Old code fired `readThenStall(.commandRejected)` at `elapsed >= confirmDeadline` (both arms); `ConfirmRow`'s deadline check is `elapsed > deadline`, so at exactly `elapsed == confirmDeadline` it falls through to the freshness/throttle path instead. Distinct from the `readInterval` boundary the controller pre-approved — this one is on the deadline itself. `HaulRunTests` never constructs the instant (`-confirmDeadline - 1`, `-confirmDeadline - 900`, both strictly past), so it is untested; practical likelihood is negligible (floating-point equality on a wall-clock delta).

## Stage 2 — tickets 24-29

- [x] **DONE (ticket 32): `SalvageRun.arrivalConfirmDeadline` and `arrivalReadInterval` deleted.** `arrivalConfirmDeadline` had zero production readers (the `SalvageRun.swift:780` this entry named did not exist at ticket 32's HEAD); `arrivalReadInterval` had two, `SalvageRun.swift:732,:733`. Both production readers and all five test sites now name `TravelTo` directly.
- [ ] **`ReturnHome`'s `.more` arm is unreachable**, as are `BotPhase`'s in the `repairing` case at both missions — `TravelTo` and `awaitRepair` never return `.more`. Four dead arms now, all harmless, all paired with a `.finished` that goes to the same place.
- [ ] **`ReturnHome` reports `.finished` for a device code absent from the world.** Its loop `continue`s past `.noSubject`, so an exhausted loop reads as "arrived". No current caller can trigger it — all four resolve their hulls from the same snapshot moments earlier — but a future caller passing a code from a different snapshot gets a silent arrival instead of an error.
- [ ] **`SalvageRun.swift:587-590` is a 4-line inline comment**, over the 2-line budget. Pre-existing and untouched by ticket 28, so it was ruled out of that task's scope; it is still over budget. (Line numbers re-pinned by ticket 32.)
- [ ] **`MineRun.swift:48-49`'s doc says the constant is "shared with the Salvage Run".** No longer true at all after ticket 32: `SalvageRun.arrivalConfirmDeadline` is deleted, so `MineRun.arrivalConfirmDeadline` shares `TravelTo.arrivalConfirmDeadline` with `TravelTo`'s other readers and with nothing in `SalvageRun`. One sentence to rewrite. (Line numbers re-pinned by ticket 32.)
- [ ] **`DirectiveStallDetailTests.swift:5`'s file header describes the legacy fallback ticket 29 deleted.** Made stale by that ticket, not pre-existing. One line.
- [ ] **The per-site rationale for the old travel guard triple went with the code it described.** A reader landing on a bare `TravelTo(...)` at any of the thirteen sites now jumps to `Steps/TravelTo.swift` for the why. Inherent to the refactor; recorded so nobody re-derives it as a loss.

## Stage 2 — ticket 31

- [ ] **`StowOrAttach`'s `.noSubject` is dead at all six migrated sites — measured, not argued.** Replacing all five `.noSubject` arms (`EventRun.swift:437`, `:740`; `MineRun.swift:321`, `:404`, `:448`) plus `EventRun.staging`'s grouped arm with `fatalError("unreachable")` leaves the full 1774-case target at 0 issues. None of the six looks a device up by code: five derive subjects from `world.devices.values`, and `EventRun.recovering` takes them from `EventRun.convoy` (`EventRun.swift:110-122`), which resolves every hull out of the same dictionary. Live the moment a caller builds `deviceCodes` from a persisted list rather than the live snapshot. `Tests/Steps/StowOrAttachTests.swift:143` is the only test that observes `StowOrAttach`'s `.noSubject` at all (`TravelToTests.swift:158` and `ReturnHomeTests.swift:76` observe their own sub-machines').
- [ ] **At `EventRun.staging` the whole non-`.action` half is unreachable, not just `.more`.** `EventRun.swift:578-581`. `staged` filters on `attachedToDeviceCode == convoy.carrier.deviceCode` (`EventRun.swift:546-552`), so inside `if !aboard.isEmpty` every row is pending and `next` can only answer `.action` — `.finished`, `.more` and `.noSubject` are all dead together. Covered by the same `fatalError` run above.
- [ ] **`StowOrAttach`'s `.more` arm is unreachable at all six sites — the fifth instance of the pattern.** `next` has three return paths and none is `.more`, yet six mission sites must switch exhaustively. Same shape as `TravelTo` (nine sites), `ReturnHome`, `BotPhase.awaitRepair` and `PrintJob`. A `StepResult` split — a two-case result for sub-machines that never loop — would retire all of them at once; ticket 32 is the place.
- [ ] **`ConfirmField.loose` is not carrier-scoped, unlike its two siblings.** `Steps/StowOrAttach.swift:73-78`: `.attachedTo` and `.controlledBy` compare against `carrierCode`, `.loose` only tests `== nil`. A device on a DIFFERENT carrier reads as pending, so a job would order `carrierCode` to detach something it is not holding. Both shipped sites pre-filter to their own carrier (`MineRun.swift:393-394`, `EventRun.swift:546-552`), so nothing is broken — it is a trap for a seventh site. Deliberately left as-is (ticket 31 was authorised no behaviour changes) and now pinned by `Tests/Steps/StowOrAttachTests.swift:149`.
- [ ] **`deviceCodes` is never de-duplicated.** `Steps/StowOrAttach.swift:61`. Harmless at both whole-list sites today, since `roster` and `staged` are built from a dictionary's values, but a duplicated list would name one code twice inside one `CommandParams(devices:)`.
- [ ] **Contract delta against the plan's `Interfaces` block (`plan-stage-2.md:2550`).** `func placed(_ ctx: StepContext) -> [Device]` is declared there and deliberately unshipped — no in-scope caller can use it, because the confirm halves do not migrate and `MineRun.confirmDetach` needs the whole roster plus two conjuncts it cannot express. `MissionLogBudget.dispatchRounds` is declared as a Consumes at `plan-stage-2.md:2549` and is likewise not consumed by the sub-machine: every round budget stayed at its mission. Recorded so a later task does not go looking for either.
- [ ] **`StowOrAttach` reads no clock, so the deadline/watermark constraint (`plan-stage-2.md:31`) is vacuously satisfied here.** It touches neither `ctx.now`, `ctx.elapsed` nor any `updatedAt`; ordering and staleness stay with `ConfirmRow` on the confirm side. Recorded so a mechanical checklist pass does not score ticket 31 as skipping it.
- [ ] **`BrainLoopTests.swift:169-173`'s comment is the defect, not the flake it explains.** It claims `await clock.advance(by: .zero)` is "a real (if virtual-time-free) synchronization point, not a timing guess". One full-target run recorded an issue at `Tests/BrainLoopTests.swift:175`, which falsifies that: `tickBrain()` reaches a real `GameDatabase.bootstrap()`, the cross-thread hop the same doc block admits `TestClock` cannot wait out. Not reproduced in 26 review runs plus six here. Fix the claim, or wait on a real signal.
- [ ] **Four guards in the migrated pair were undefended before ticket 31; all four now have a sole defender.** Each was found by deleting it and watching the full target stay green: `MineRun.attach`'s `guard roster.count == Self.carriedTotal` (`MineRun.swift:324-326`), `EventRun.recovering`'s busy-carrier wait (`EventRun.swift:738`), `MineRun.detach`'s folded empty-grid advance (`MineRun.swift:403`), and all three conjuncts of `MineRun.confirmDetach`'s landing predicate (`MineRun.swift:418-421`) — the last because `detachConfirmed` has all three true and `detachStaleRowsBuyARead` falsifies two at once, so no test ever varied one alone. Six probes into two files found six holes. A systematic mutation sweep over the engine's remaining guards is very likely to find more, and this feature's recurrence history is exactly "green in the module I edited".

## Stage 2 — ticket 32

The deferrals ticket 32 declared, plus what its own sweep turned up. Ticket 32 also corrected six
stale entries above in place (`recallArrival`, the `SalvageRun` `TravelTo` aliases,
`carrierRetainsAuthority`, `confirmSource`, `SalvageRun.awaitCompletion`, the `SalvageRun` 4-line
comment and the `MineRun` doc).

### The plan's six deferrals

- [ ] **Restated (ticket 47): all 13 travel sites still use the unowned `openOperation` guard, and what it sees changed under them.** `Steps/TravelTo.swift:56` reads `ctx.openOperation(for:)`, backed by `WorldSnapshot.openOperations`. Ticket 12 (C9) narrowed that dictionary to the ACTIVE op only, so a co-tenant merely `enqueued` (an owner-scoped print on a shared bench, for instance) no longer blocks travel the way an open-in-the-old-sense op once did — only a co-tenant's ACTIVE op still does. Narrower than before, still unowned; the human decision (own it or leave it) is unchanged.
- [ ] **`SalvageRun.unresolvedSystem` (`SalvageRun.swift:425`) and `RelayRun.unresolvedSystem` (`RelayRun.swift:705`) are duplicated verbatim and were not extracted.** Their subject is a system blob, not a `Device`, so no existing sub-machine fits. Three callers on the Salvage side (`:456`, `:491`, `:707`), one on the Relay side (`:732`).
- [ ] **`stagingFreshness = 5 * 60` is declared three times with no alias linking them.** `SurveyRun.swift:101`, `SalvageRun.swift:67`, `HaulRun.swift:62`; read at `SurveyRun.swift:235`, `SalvageRun.swift:224`, `HaulRun.swift:259` and `:271`. All three docs describe different-but-adjacent rules, so ticket 32 left them rather than inventing a sub-machine to hold one number. Nothing prevents drift.
- [x] **DONE (ticket 47, closed by tickets 36 `ccaf2c9`/`45c0201` and 37 `1ed99fe`/`bea0196`): Two print sites remained outside `PrintJob`.** `EventRun.printing` and `RelayRun.acquire` both now dispatch through `PrintScheduler.choose`/`PrintJob`, so all five print sites share one policy.
- [ ] **`RelayRun.confirmSource`, `SurveyRun.awaitCompletion` and `SalvageRun.awaitCompletion` still have no deadline** — carried above under ticket 28 with re-pinned line numbers, not repeated here.
- [ ] **`RelayRun.carrierRetainsAuthority` is still hand-rolled** — carried above under ticket 28 with a re-pinned line number, not repeated here.

### Carried forward from ticket 30 (Task 11 items 8 and 9)

- [x] **DONE (ticket 38, commits `d3713f5`..`a50ff53`): `RestockRun.printing` was chooser-scoped and defeated by substitution — a live, pre-existing duplicate-spend path.** `RestockRun.swift:159`. Trace: the pin is `"compacted"` so `PrintJob.bench` substitutes to a free bench and `stocking` dispatches there; `DirectiveExecutor` does not rewrite `directive.deviceCode` on dispatch, so next tick `bench` excludes the bench now carrying our own open op and returns a third one, the owner-scoped guard misses, and `stocking` can dispatch a **second print**. `CommandGovernor`'s de-dup misses on both keys because the entity code differs and `advanceStep` re-stamps `stepStartedAt`. `stillPrinting` is the instrument for this. The sibling escapes at `RestockRun.swift:95` and `MineFleetPrint.swift:86` are chooser-scoped the same way but weaker. **Closed by ticket 38** exactly as predicted: demand is netted against `PrintScheduler.onOrder` rather than guarded at the chosen bench. Pinned by `RestockRunTests` "a substituted bench does not buy a second relay" (C2), and by the required own-print case — own print open on bench A, bench B free at the same depot, demand already covered, no second dispatch.
- [x] **DONE (ticket 32): `EventCourierPrintTests` computing its stale timestamp from `RestockRun.printDeadline`.** That alias is deleted; the test reads `PrintJob.deadline`, the same value the code under test reads.

### Found by ticket 32's own sweep

- [ ] **`EventRun.carrierDeviceType` (`EventRun.swift:48`) and `MineRecipe.carrierDeviceType` (`MineRecipe.swift:26`) are the same literal `"surge_carrier"` declared twice, with nothing linking them** — and `Brain.swift:2030` mixes the two namespaces in one call: `freeHull(type: EventRun.carrierDeviceType, tag: MineRecipe.carrierTag, …)`. Same class of hazard as `stagingFreshness`. Ticket 32 ruled both declarations "leave" on ownership grounds, so the drift risk stands.
- [ ] **`EventRun.arrivalConfirmDeadline` (`EventRun.swift:58`) is a fourth, independent declaration of `5 * 60` with no link to `TravelTo.arrivalConfirmDeadline`.** Read at `EventRun.swift:536`. `TravelTo.swift:24` holds the root and `MineRun.swift:50` aliases it; this one does not.
- [ ] **`Steps/StepResult.swift:11` imports `Foundation` without using it.** The file references only `MissionAction`. Ticket 32 touched `Steps/` but not this file, and left it rather than widen the diff.

### Found by ticket 47's print-policy audit

- [ ] **Depot anchor is a 2-way split, not the one answer Stage 3's print-policy count implies.** `RestockRun`, `MineFleetPrint` and `RelayRun` (`RelayRun.swift:319`, since ticket 37) resolve a print depot via `PrintJob.depot(for:in:)` — stamped theatre, else the pinned device's location. `EventRun.swift:321` and `EventCourierPrint.swift:51` resolve it via `world.theatreDepot(for:)` instead — stamped theatre ONLY, and only if that theatre is still `.operational`; no device-location fallback. `EventCourierPrint`'s use of the stricter function predates this whole plan (confirmed by `git log -p`), so the plan's own Stage 3 baseline table was already wrong claiming all of sites 1-3 agreed. No Stage 3 ticket targeted either site's depot anchor. Worth deciding whether `EventRun`/`EventCourierPrint` should move onto `PrintJob.depot`, or whether the stricter no-fallback behaviour is intentional for those two missions specifically.

- [ ] **`RelayRun.activationDeadline`'s VALUE has no defender — measured, not argued.** `RelayRun.swift:90`. Changing `10 * 60` to `11 * 60` leaves the full 1774-case `DirectiveEngineTests` at 0 issues, because its one test (`RelayRunTests.swift:1452`) expresses its fixture as `-RelayRun.activationDeadline - 1` and therefore tracks whatever the constant says. Pre-existing — it was equally undefended as `SalvageRun.activationDeadline` — and surfaced by ticket 32's move probe. The same shape is likely on other relative-fixture constants.
- [x] **DONE (ticket 32 review round): `Steps/PrintRail.swift`'s four over-budget doc comments trimmed to 3 lines each**, each ending in a pointer to `brain-relay-reserve-floor`, which carries every fact they held (and the concrete 999,999-against-35,078 case besides). `Steps/` is a clean island again.
- [ ] **`PrintRail.printStockShortDiagnosis`'s `?? "unarmed"` fallback cannot fire.** `Steps/PrintRail.swift:53`. Its only caller (`RelayRun.swift:342`) is reached only when `printStockIsShort` returned true, which `:43` makes impossible for a nil `reserveFloor`. Carried verbatim from `RelayRun`. It cannot be deleted without either a force-unwrap or an equivalent `guard`+string, so the ticket-32 review round cut the doc line that explained it and left the expression. A signature taking a non-optional floor would retire it properly.
- [ ] **`RelayRun.pollInterval` now sources its cadence from `PrintRail`, which is semantically backwards for three of its readers.** `RelayRun.swift:104` aliases `PrintRail.pollInterval`; the relay confirm ladders at `RelayRun.swift:579,:580`, `:662,:663` and `:822,:823` and the staleness gate at `:797` are relay-poll cadence, not census freshness. The two happened to be the same 60 and ticket 32 was authorised no behaviour change, so the alias preserves that. If they ever need to diverge, `RelayRun` takes its own root back.

- [ ] **`PrintQueueFeature` and the engine disagree on what a printer is.** The screen filters on `Device.canPrint` = `features.contains("print")` (`Printing.swift:132`, read at `PrintQueueFeature.swift:60`); the engine uses `isPrintHub` = `availableCommands.contains("enqueue_print")` (`Device.swift:177`); `EventRun.swift:363` uses `deviceType == "autofactory"` and nothing else does. After directives ticket 36 the engine's answer is the only one used for dispatch, so the Print Queue can list a device the scheduler will never choose. Deferred by ticket 18 deliberately: settling it means establishing which of the two the server actually guarantees, which is a live-probe question like Open Questions 3 and 4 in `plan-stage-3.md`. Found 2026-08-19.

### Found by the Stage 3 final fix-wave review

- [ ] **Nothing reaps an orphaned `enqueued` op.** The supersede loop (`CommandClient.swift`, the `kind != .print` branch) was the de-facto collector before Phase B: dispatching travel/mine cleared out whatever else was open on the device, prints included. The fix wave scoped that supersede correctly to non-print kinds (Important 3), so a queued print now survives a travel dispatch — but that also means a print op that never gets a completion event (a missed/dropped stream event, a server-side failure with no `print.completed`) has no path back to a terminal state. `OperationRetention` never prunes OPEN rows by design (`operations-table-retention.md`); settle (`Reconciler.apply`'s `isSettled` branch) only closes `.active`, never `.enqueued`; and `PrintScheduler.depth`'s `max(device.queuedJobCount + ..., ops.count)` floors a bench's counted depth at its live-ops count regardless of what the device's own snapshot says, so a phantom enqueued row keeps one queue slot permanently occupied in the scheduler's eyes. Needs a design decision: a deadline on `enqueued` (mirroring `PrintJob.deadline` for the active side), a periodic reconcile against the server's actual queue, or an explicit TTL-based reap. Found while implementing CRITICAL 1/IMPORTANT 3 of the Stage 3 final fix wave, 2026-08-19.
- [ ] **`PrintScheduler.openOps`'s fallback onto `openOperations` exists only so ~70 pre-existing test fixtures keep working, which means the production path and the test path read different collections.** `PrintScheduler.swift` (`openOps(for:in:)`, renamed from `liveOps` by Important 5): `let queued = world.queuedOperations[deviceCode] ?? []; return queued.isEmpty ? world.openOperation(for: deviceCode).map { [$0] } ?? [] : queued`. Production's `WorldSnapshot.read` always populates `queuedOperations` (it groups the same `openCases` fetch that seeds `openOperations`), so the one-op fallback is dead in the live app — but a fixture built by hand with `queuedOperations: [:]` (the default) silently falls back onto the single-op `openOperations` reading instead of exercising the real multi-op path, so a scheduler test can pass against a collection production never actually hands it. Ticket 46 (`46-scheduler-real-depth.md`) knowingly accepted this to avoid a ~70-fixture rewrite. Resolving it means either populating `queuedOperations` in every scheduler fixture (the rewrite ticket 46 deferred) or deleting the fallback and accepting the break. Found while re-reading `PrintScheduler.swift` for the Stage 3 final fix wave, 2026-08-19.
