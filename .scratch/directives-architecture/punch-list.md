# Directives Architecture — punch list

Small things deliberately not fixed when they were found, kept here so they are not lost between stages. Work the list at the end of the effort; anything still open then is either done or consciously dropped.

**Maintaining it.** When a review defers something, add a line: what it is, where (`file:line`), which stage found it, and why it was deferred. Tick the box when it lands, and say in the commit which item it closed. Do not delete a line to close it — a ticked line is the record that someone decided. If an item turns out to be wrong or no longer real, tick it and say so.

**Not for this list:** anything that blocks a merge, anything that changes behaviour a mission depends on, and anything a stage's own ticket already covers. Those belong in a ticket.

---

## Needs a human decision

- [ ] **`MineFleetPrint.stocking` has no deadline above its open-op guard.** Stage 0 owner-scoped the guard to match its three siblings but deliberately did not invent a deadline, because adding one changes mission behaviour outside the ticket's scope. Without it, a co-tenant on a shared bench can park the run for the length of its own print. `MineFleetPrint.swift` — decide whether `stocking` should carry a deadline like `printing` does.
- [ ] **automation-brain ticket 14 (RestockRun over-print race) is still open.** Stage 0 declined to close it: the ownership and ordering fixes did not touch the clone-row-lag race it describes. It now carries a cross-reference. Decide whether it belongs in a later stage of this effort or stays where it is.

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

- [ ] **`DeviceListAttention.covers` is correct only because its caller passes a one-device fleet.** It
  routes through `Ownership.resolve` over a synthetic single-device fleet, deliberately truncating the
  stow/attach closure. The doc says so, but a future "bug fix" passing the real fleet would silently
  make every stowed drone inherit its carrier's run's attention flag. `DeviceListAttention.swift`.
  A named seeds-only entry point on `Ownership` would be safer than a `resolve` over a synthetic fleet.
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

## Cosmetic

- [ ] **`completeOpenOperation`'s `logger.notice` diagnostics are absent from the device-event path.** Inlining the op-close into `applyDeviceEvent` dropped the kind-mismatch and stale-time rejection lines. No behaviour depends on them; they are the lines that would explain a silent non-close. `Reconciler.swift`.
- [ ] **The `print.completed` clone read no longer runs when an event carries no device code.** Stage 0 hoisted the `deviceCode` guard above it and later kept the mark inside that guard deliberately. Unreachable in practice — print completions always carry a code.
- [ ] **`DirectiveExecutor.move`'s doc comment is 13 `///` lines against a 3-line budget.** Inherited, not grown by this effort, and `check-comments.sh` cannot see it.
- [ ] **`DirectiveEngineCore.collapse`'s doc is a 4-line `///`.** Same class, adjacent to code Stage 0 touched.
- [ ] **`GameModels.Operation` is fully qualified in one test file and bare in its sibling.** Cosmetic inconsistency between `DirectiveEngineTests` and `CommandDedupTests`.
- [ ] **Every `.dispatch` tick now runs one extra `SELECT count(*)`.** The failure counter reads before and after. Small, but it is per tick for the life of a step that defers every tick. Measure before assuming it is free.
