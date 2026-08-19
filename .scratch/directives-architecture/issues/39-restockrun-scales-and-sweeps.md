# 39 — `RestockRun` scales its cap and sweeps before it spends

Type: task
Status: open
Blocked by: 38
Labels: directives-architecture, stage-3

The `min(10, 3 × benches)` cap ticket 18 specifies, and the pre-spend fleet-evidence gate that closes automation-brain ticket 14.

**Plan:** `.scratch/directives-architecture/plan-stage-3.md` — Task 7. **Carries C8. Resolves `.scratch/automation-brain/issues/14-restockrun-over-print-race.md`.**

**Read automation-brain ticket 14 in full before starting.** Its "The fix" section specifies the gate, the witness and why `thenStall` must be non-nil. Do not re-derive any of it. That ticket has been open since 2026-08-10 and directives ticket 07 re-confirmed it still open on 2026-08-16.

**The race, briefly.** A printed clone's device row lands off the SSE frame 28–117 minutes after its print op closes (measured live on 2026-08-10). `printing` hands back to `stocking` the moment no own op is open, `stocking` re-counts a pool that has not seen the clone, and prints another. `thenStall` must be non-nil: a nil fallback waits, `.wait` does not re-stamp `stepStartedAt`, and the gate would buy one read every 5-second tick forever.

**The cap will usually change nothing, and the test must be honest about that.** `desiredIdle(for:) = min(idleCap, directive.targets.count)` and ticket 14 measured `targets.count` at 1 in the live row, so demand binds and the cap has never engaged. The formula is still right — it stops the cap becoming the binding term once `Brain.tendRestock` grows the list — but the test has to manufacture the case where it binds, and should say so.

Keep `idleCap` public and named as it is: `RelayReturnAndRestockTests.swift:377,379` reads it, and ticket 38 already touched that suite once.

---

- [ ] **Step 1:** Write the cap test with literals — 1 bench gives 3, 3 benches give 9, 4 benches give 10, 0 benches give 0 — plus the case where demand binds below the cap.
- [ ] **Step 2:** Write the sweep test: every device row at the depot predating the step stamp buys `.refreshDevicesInSystem(designation: depot, thenStall: .unreachableDevice)`. Write its partner too — a met demand buys no read, because the gate sits after every branch that declines.
- [ ] **Step 3:** Confirm both fail.
- [ ] **Step 4:** Implement `desiredIdle(for:benches:)` with `idlePerBench = 3` and `idleCap = 10`.
- [ ] **Step 5:** Add the sweep as the LAST gate in `stocking`, after the demand check and the rail, immediately before the dispatch — the position `MineFleetPrint.swift:96-100` uses.
- [ ] **Step 6:** All six targets green. Then resolve automation-brain ticket 14 with the sha, saying which of its two asks landed (the gate) and confirming the implemented order matches the one it specifies: census first, reserve veto, then the device sweep.
- [ ] **Step 7:** **Mutation probe.** Set `idlePerBench` to 4 and confirm the 3-bench case reddens. Set `idleCap` to 12 and confirm the 4-bench case reddens. Revert both.
- [ ] **Step 8:** `check-comments.sh`; commit.

**Done when:** automation-brain ticket 14 is resolved with a test that fails if the sweep is removed.
