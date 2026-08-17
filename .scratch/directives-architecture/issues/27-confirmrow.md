# 27 — `ConfirmRow`, and the ten shared-ladder sites

Type: task
Status: open
Blocked by: 20
Labels: directives-architecture, stage-2

The ordering rule — probe delay, deadline, arrival wait, staleness, throttled read — as one value. Then the ten `MissionConfirm.ladder` callers move onto it and `MissionConfirm` is deleted.

**Plan:** `.scratch/directives-architecture/plan-stage-2.md` — Task 8.

**`ConfirmRow` does not decide success, and the spec's `predicate:` parameter is deliberately rejected.** The 21 hand-rolled ladder sites disagree on success in six incompatible ways — a containment column, a `statusBase` string, a config-content test, `RepairFleet.isRepairing`, a scalar `cargoUsed`, a non-`Device` event row. A closure would cover them at the cost of making `ConfirmRow` non-`Equatable` and untestable as a value. **The bug class Stage 2 retires is ordering, not predicate.** So `verdict(_:_:)` answers `.judge` when the rows are fresh enough and the mission applies its own test — which is exactly how `probe` already works.

Honest coverage across this ticket and ticket 28: **26 of the 31 ladder sites**. The five left alone have a non-`Device` subject (`EventRun:607`, `SalvageRun:451`, `RelayRun:765`, `SalvageRun:982`); the four print polls go to ticket 30.

---

- [ ] **Step 1:** Write `Tests/Steps/ConfirmRowTests.swift`. The first test is **the deadline is read before the staleness gate** — that is the rule the whole sub-machine exists to hold. Then: fresh rows judged, a stale row buying a throttled read, a recently-read row waiting, all three `Expiry` cases, the arrival wait, the skewed watermark, the fleet refresh, the probe delay.
- [ ] **Step 2:** Confirm the build fails.
- [ ] **Step 3:** Write `Sources/Steps/ConfirmRow.swift` with `ConfirmVerdict`, `Expiry`, `Watermark`, `Refresh`.
- [ ] **Step 4:** Migrate the ten sites (`EventRun:477,529,596,737,798`; `MineRun:340,371,405,442,533`). **Verify each `.judge` branch per site** rather than assuming `.wait`; if a site's success test is not already above the ladder call, move it there first.
- [ ] **Step 5:** Delete `MissionLogBudget.swift:95-119`; `grep MissionConfirm` returns nothing.
- [ ] **Step 6:** `swift test --filter DirectiveEngineTests`; `check-comments.sh`; commit.

**Done when:** eleven tests green, ten sites migrated, `MissionConfirm` gone, and the target green unedited.
