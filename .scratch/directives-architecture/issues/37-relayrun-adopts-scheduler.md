# 37 — `RelayRun.acquire` adopts the scheduler

Type: task
Status: open
Blocked by: 36
Labels: directives-architecture, stage-3

The second hand-rolled site, and the largest behaviour change in Stage 3.

**Plan:** `.scratch/directives-architecture/plan-stage-3.md` — Task 5. **Carries C5, C6 and C7.**

**The dispatch is in `acquire`, not `printing`.** Stage 2's hand-off note said `RelayRun.swift:359`; that is the poll step and it dispatches nothing. The `enqueue_print` is at `RelayRun.swift:348`, inside `acquire` (`:305-353`). A ticket that migrated `printing` would change nothing and report success.

**Four things change at once, because `RelayRun` differs from the other four on four axes:**

- **C5** — `hub(near:in:)` anchors on `carrier.location` (`:150`), a device location, which `PrintJob.swift:20-21` warns against: a hub that unfurls elsewhere must not drag the run with it. It becomes the theatre depot.
- **C6** — `hub` prefers "anything but our own carrier", then lowest code. Never a free bench, and a carrier hull is a legal pick.
- **C7** — `acquire` has no open-op guard at all, alone among the five sites.
- The per-device freshness gate (`hub.updatedAt > hubFreshness`, `:328`) becomes the depot-wide `PrintJob.fleetEvidenceIsStale` the other sites use, placed last before the spend.

**What does NOT change:** `RelayRun` stays the one site that stalls on a short rail. It passes `onRailShort: .stall(.printStockShort)`. See Open Question 1.

**The C7 guard has a trap in it.** `world.openOperation(for: directive.deviceCode, owner:)` asks about the carrier, not the bench — and the bench is recomputed every tick, so "is my print open?" cannot be asked of a device the chooser may have moved on from. That is punch-list line 255 in a different mission. Use `PrintJob.stillPrinting`, and read it first (`Steps/PrintJob.swift:52-60`) to confirm it answers "does this owner have a print open anywhere" rather than "is this device busy". If it answers the latter, widen it here and say so.

---

- [ ] **Step 1:** Write the three failing tests — depot anchor, free-bench-and-no-hulls, and no-double-order.
- [ ] **Step 2:** Confirm all three fail.
- [ ] **Step 3:** Rewrite `acquire`'s tail. Keep the rail stall.
- [ ] **Step 4:** Delete `hub(near:in:)` (`:149-157`). Confirm with LSP, then with a build — an empty `findReferences` is a cold index, not proof.
- [ ] **Step 5:** All six targets green. `RelayRunTests` is the largest suite in the module; read failures individually.
- [ ] **Step 6:** Record the borrow count; `check-comments.sh`; commit.

**Done when:** a carrier standing away from its theatre depot still prints at the depot, with a test.
