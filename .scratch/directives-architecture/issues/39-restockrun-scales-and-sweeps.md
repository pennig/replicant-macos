# 39 — `RestockRun` scales its cap and sweeps before it spends

Type: task
Status: resolved
Blocked by: 38
Labels: directives-architecture, stage-3

The `min(10, 3 × benches)` cap ticket 18 specifies, and the pre-spend fleet-evidence gate that closes automation-brain ticket 14.

**Plan:** `.scratch/directives-architecture/plan-stage-3.md` — Task 7. **Carries C8. Resolves `.scratch/automation-brain/issues/14-restockrun-over-print-race.md`.**

**Read automation-brain ticket 14 in full before starting.** Its "The fix" section specifies the gate, the witness and why `thenStall` must be non-nil. Do not re-derive any of it. That ticket has been open since 2026-08-10 and directives ticket 07 re-confirmed it still open on 2026-08-16.

**The race, briefly.** A printed clone's device row lands off the SSE frame 28–117 minutes after its print op closes (measured live on 2026-08-10). `printing` hands back to `stocking` the moment no own op is open, `stocking` re-counts a pool that has not seen the clone, and prints another. `thenStall` must be non-nil: a nil fallback waits, `.wait` does not re-stamp `stepStartedAt`, and the gate would buy one read every 5-second tick forever.

**The cap will usually change nothing, and the test must be honest about that.** `desiredIdle(for:) = min(idleCap, directive.targets.count)` and ticket 14 measured `targets.count` at 1 in the live row, so demand binds and the cap has never engaged. The formula is still right — it stops the cap becoming the binding term once `Brain.tendRestock` grows the list — but the test has to manufacture the case where it binds, and should say so.

Keep `idleCap` public and named as it is: `RelayReturnAndRestockTests.swift:377,379` reads it, and ticket 38 already touched that suite once.

---

- [x] **Step 1:** Write the cap test with literals — 1 bench gives 3, 3 benches give 9, 4 benches give 10, 0 benches give 0 — plus the case where demand binds below the cap.
- [x] **Step 2:** Write the sweep test: every device row at the depot predating the step stamp buys `.refreshDevicesInSystem(designation: depot, thenStall: .unreachableDevice)`. Write its partner too — a met demand buys no read, because the gate sits after every branch that declines.
- [x] **Step 3:** Confirm both fail.
- [x] **Step 4:** Implement `desiredIdle(for:benches:)` with `idlePerBench = 3` and `idleCap = 10`.
- [x] **Step 5:** Add the sweep as the LAST gate in `stocking`, after the demand check and the rail, immediately before the dispatch — the position `MineFleetPrint.swift:96-100` uses.
- [x] **Step 6:** All six targets green. Then resolve automation-brain ticket 14 with the sha, saying which of its two asks landed (the gate) and confirming the implemented order matches the one it specifies: census first, reserve veto, then the device sweep.
- [x] **Step 7:** **Mutation probe.** Set `idlePerBench` to 4 and confirm the 3-bench case reddens. Set `idleCap` to 12 and confirm the 4-bench case reddens. Revert both.
- [x] **Step 8:** `check-comments.sh`; commit.

**Done when:** automation-brain ticket 14 is resolved with a test that fails if the sweep is removed.

## Comments

**Built and reviewed 2026-08-19**, subagent-driven, on worktree branch
`worktree-directives-stage-3` off local `main` at `b7228f1`. **Not merged** — merging is Matt's
call. Every claim below was checked against the source or the event stream, not taken from a
subagent's summary.

| Commit | What |
|---|---|
| `30b783b` | `fix(directives): RestockRun scales its cap and sweeps before it spends (C8)` |
| `235c025` | `docs(automation-brain): resolve ticket 14` |
| `90376fa` | `fix(directives): review round 1 — pin the sweep's position, trim comments` |

C8 lands and **automation-brain ticket 14 is closed**, open since 2026-08-10. The review checked
the shipped gate order against `MineFleetPrint.stocking`'s and against the ticket's own "The fix"
section: census first, reserve veto, then the device sweep, `thenStall` non-nil.

`desiredIdle` gains its `benches:` argument — `min(idleCap, idlePerBench * benches,
targets.count)`. **There were two call sites, not the one the brief discussed**: `stocking` and
`printing`. Both compute `benches` with the identical expression off the same `depot`/`world`,
and only one runs per tick, so they cannot disagree. `idleCap` stays public and named, because
`RelayReturnAndRestockTests` reads it.

**The gate's position had no defender until review.** `staleEvidenceBuysASweep` proves the sweep
exists; nothing proved it sits **last**, after every cheaper decline — which is the whole point of
ticket 14. The brief's `metDemandBuysNoSweep` could not prove it either: with demand met, the
guard returns `.wait` before the sweep is reached, so it cannot tell a correctly-placed gate from
a missing one. Replaced by `shortReserveDeclinesBeforeTheSweep`, which makes the rail short and
the evidence stale at the same moment and expects the rail's `.wait`. Hoisting the sweep above
the rail reddens it alone.

**The brief's mutation arithmetic was wrong** and the implementer caught it: mutating
`idlePerBench` to 4 gives `min(10, 12, 20)` = 10, not the 12 the brief predicted — it ignored its
own outer clamp. The test reddens either way, so the pin is genuine.

One out-of-set edit, disclosed and judged faithful: `BrainGrowLifecycleE2ETests.swift` needed a
`devicesClient.fetchAtLocation` stub, because the new sweep gate reaches a dependency that suite
never stubbed. No assertion in it was touched.
