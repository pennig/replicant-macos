# 28 — The hand-rolled ladders adopt `ConfirmRow`

Type: task
Status: open
Blocked by: 27, 23
Labels: directives-architecture, stage-2

Sixteen sites in four families: an ETA wait, an extra success predicate, a different watermark, a fleet-scoped refresh. Both `probe` copies are deleted — `probe` is `ConfirmRow` with `onExpiry: .judge` and the deadline checked by the caller, which `ConfirmRow` now folds in.

Blocked by 23 as well as 27: tickets 22–23 already delete the six `probe` callers inside the bot phase, and migrating the rest first would fight them.

**Plan:** `.scratch/directives-architecture/plan-stage-2.md` — Task 9 carries the per-site configuration table.

Three sites are deliberately **left alone**, and that is the finding rather than a gap:

- `RelayRun.swift:656` `carrierRetainsAuthority` — a two-sided watermark (after the step start AND younger than `reclaimFreshness`) that `ConfirmRow` does not model. One site; inventing a fifth `Watermark` case is not worth the surface.
- `SalvageRun.swift:451` and `RelayRun.swift:765` `unresolvedSystem` — duplicated verbatim, but their subject is a system blob with no `updatedAt` to throttle on. Worth their own extraction later; not here.

Two sites have **no deadline today** (`RelayRun:507` `confirmSource`, `SurveyRun:355` `awaitCompletion`) and one has none by design (`SalvageRun:613` `awaitCompletion`). Give them `deadline: .infinity, onExpiry: .judge` rather than inventing a bound, and put the missing bounds on the punch list.

---

- [ ] **Step 1:** Migrate the ETA-wait family; run `DirectiveEngineTests`; commit.
- [ ] **Step 2:** Migrate the extra-predicate family. `HaulRun.swift:365` needs care — its deadline is currently tested inside **both** arms of a two-armed shape and `ConfirmRow` tests it once, above; prove the collapse with the existing `HaulRunTests`. `RelayRun.swift:706`'s success exit is `.claimRelay`, an action carrying a write — which is exactly why success stays in the mission.
- [ ] **Step 3:** Migrate the watermark family. Run; commit.
- [ ] **Step 4:** Migrate `SalvageRun:613`'s fleet refresh. Run; commit.
- [ ] **Step 5:** `grep "static func probe" Sources` returns nothing.
- [ ] **Step 6:** **Pin the throttle boundary.** `ladder` waits at exactly `readInterval`; `probe` reads. `ConfirmRow` adopts `ladder`'s `>`, so every migrated `probe` site now waits one extra tick at that instant. If a test fails only there, that is the finding — record it and decide the boundary deliberately rather than editing the test.

**Done when:** sixteen sites migrated, both `probe` copies gone, the three excluded sites recorded, and the target green.
