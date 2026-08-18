# Directives Architecture — punch list

Small things deliberately not fixed when they were found, kept here so they are not lost between stages. Work the list at the end of the effort; anything still open then is either done or consciously dropped.

**Maintaining it.** When a review defers something, add a line: what it is, where (`file:line`), which stage found it, and why it was deferred. Tick the box when it lands, and say in the commit which item it closed. Do not delete a line to close it — a ticked line is the record that someone decided. If an item turns out to be wrong or no longer real, tick it and say so.

**Not for this list:** anything that blocks a merge, anything that changes behaviour a mission depends on, and anything a stage's own ticket already covers. Those belong in a ticket.

---

## Needs a human decision

- [ ] **`MineFleetPrint.stocking` has no deadline above its open-op guard.** Stage 0 owner-scoped the guard to match its three siblings but deliberately did not invent a deadline, because adding one changes mission behaviour outside the ticket's scope. Without it, a co-tenant on a shared bench can park the run for the length of its own print. `MineFleetPrint.swift` — decide whether `stocking` should carry a deadline like `printing` does.
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

- [ ] **`BotPhase.recallArrival` is called by two drone-recovery sites that are not bot phases.** `SurveyRun.swift:499` (inside `recover`) and `SalvageRun.swift:658` (the "mining done, drones still out" branch) both reach into the bot-phase namespace for a function that just answers "latest `activityDeadline` among these devices". Deliberate — the alternative was three copies — but it reads oddly, and ticket 32 is where constants and shared helpers come home. Rehome it somewhere neutral there.
- [ ] **`BotPhase.withoutLocation` re-checks a deadline `confirmRecall` has already checked.** `Steps/BotPhase.swift`. Provably dead in that path; faithful to the original bodies, which had the same shape. Harmless.
- [ ] **`.repairing`'s `case .finished, .more:` arm is half dead in both missions.** `SurveyRun.swift:168`, `SalvageRun.swift:146`. `BotPhase.awaitRepair` never returns `.more` — every non-action exit is `.finished`. Both arms go to the same destination, so it costs nothing but obscures that `.more` cannot happen here.
- [ ] **`.noSubject` is unreachable from both missions.** Each `nextAction` already guards `world.device(directive.deviceCode)` and stalls `.unreachableDevice` before `ctx` is built, so `BotPhase`'s missing-vessel branch never fires. Mapping it to the same stall is correct and consistent; it is simply dead in these two callers, and may be live for a mission a later task migrates.
- [ ] **`StepResult.swift` imports `Foundation` without using it.** Only `MissionAction` is referenced. Copied verbatim from the plan's code block.
- [ ] **The two-bot fixtures' already-deployed bot is not mechanically load-bearing.** `BotPhaseTests.deployGivesUpWithABotAlreadyDeployed` and `SurveyRunRepairTests.theDeployLoopGivesUpWithABotAlreadyDeployedRoutesToArming` both genuinely fail pre-fix, but on the assertion's value rather than on the deployed bot's presence — `deploy` never reads that bot on the path it takes. Their doc comments overstate what the fixture element does. Worth tightening if a future task touches them.
- [ ] **`SurveyRun.recallDeadline` and `BotPhase.recallDeadline` both hold `20 * 60` with nothing linking them.** `SurveyRun` keeps its own because `recover` needs it; the plan accepted the duplication and asked for the trailing comment that is now there. Tuning one no longer moves the other, which is the improvement AND the risk.

## Stage 2 — ticket 28

- [ ] **`RelayRun.carrierRetainsAuthority` (`RelayRun.swift:655`) was left hand-rolled.** Its watermark is two-sided — a row must be both AFTER the step start AND younger than `reclaimFreshness` — and `ConfirmRow.Watermark` has no two-sided case. One site does not justify a fifth case; ruling from the controller was to leave it alone.
- [ ] **`RelayRun.confirmSource` (`RelayRun.swift:507`) was left hand-rolled — a real fit failure, not a style choice.** Every stale-row read it issues carries `thenStall: .unreachableDevice` with no deadline gating it; `ConfirmRow`'s throttle-triggered read is hardcoded to `thenStall: nil` and can only carry a stall reason via `.readThenStall` at deadline expiry, which a `deadline: .infinity` site can never reach. `RelayRunReclaimTests.reclaimSourceConfirmsThenDeactivates` pins the old `.unreachableDevice` exactly, so the migration was reverted rather than the test edited. Also carries a missing deadline — see below.
- [ ] **Three sites have no deadline today** (`deadline: .infinity, onExpiry: .judge` was used rather than inventing one):
  - `RelayRun.confirmSource`, `RelayRun.swift:507` — bounded only by the engine's `paid`-set collapse (this site is unmigrated — see above — but the missing bound stands regardless).
  - `SurveyRun.awaitCompletion`, `SurveyRun.swift:396` — same.
  - `SalvageRun.awaitCompletion`, `SalvageRun.swift:589` — unbounded by design ("never stall, however long the cycle runs"); its throttle advances only on a successful read, so a persistently failing fleet read spends one `.refreshFleet` per tick forever. Accepted cost, not a bug.
- [ ] **`HaulRun.confirm` (`HaulRun.swift:365`) has an exact-equality deadline gap at the collapse.** Old code fired `readThenStall(.commandRejected)` at `elapsed >= confirmDeadline` (both arms); `ConfirmRow`'s deadline check is `elapsed > deadline`, so at exactly `elapsed == confirmDeadline` it falls through to the freshness/throttle path instead. Distinct from the `readInterval` boundary the controller pre-approved — this one is on the deadline itself. `HaulRunTests` never constructs the instant (`-confirmDeadline - 1`, `-confirmDeadline - 900`, both strictly past), so it is untested; practical likelihood is negligible (floating-point equality on a wall-clock delta).

## Stage 2 — tickets 24-29

- [ ] **`SalvageRun.arrivalConfirmDeadline` and `arrivalReadInterval` are aliases onto `TravelTo`, kept only for their readers.** `SalvageRun.swift:70,72`. Five test sites and `SalvageRun.swift:780` still name them; ticket 32 owns constants and should repoint those readers and delete the aliases.
- [ ] **`ReturnHome`'s `.more` arm is unreachable**, as are `BotPhase`'s in the `repairing` case at both missions — `TravelTo` and `awaitRepair` never return `.more`. Four dead arms now, all harmless, all paired with a `.finished` that goes to the same place.
- [ ] **`ReturnHome` reports `.finished` for a device code absent from the world.** Its loop `continue`s past `.noSubject`, so an exhausted loop reads as "arrived". No current caller can trigger it — all four resolve their hulls from the same snapshot moments earlier — but a future caller passing a code from a different snapshot gets a silent arrival instead of an error.
- [ ] **`SalvageRun.swift:597-600` is a 4-line inline comment**, over the 2-line budget. Pre-existing and untouched by ticket 28, so it was ruled out of that task's scope; it is still over budget.
- [ ] **`MineRun.swift:64-65`'s doc says the constant is "shared with the Salvage Run".** True by one more hop now — it goes through `TravelTo`. Stale by a link.
- [ ] **`DirectiveStallDetailTests.swift:5`'s file header describes the legacy fallback ticket 29 deleted.** Made stale by that ticket, not pre-existing. One line.
- [ ] **The per-site rationale for the old travel guard triple went with the code it described.** A reader landing on a bare `TravelTo(...)` at any of the thirteen sites now jumps to `Steps/TravelTo.swift` for the why. Inherent to the refactor; recorded so nobody re-derives it as a loss.
