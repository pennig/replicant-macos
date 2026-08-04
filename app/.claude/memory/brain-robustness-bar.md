---
name: brain-robustness-bar
description: "The definition-of-done / acceptance criteria for every automation-brain capability (the standing global orchestrator). Spine: the brain is a PURE SELECTOR over the existing safe rails — it ranks goals, never enacts them; print/deliver/shuttle are new EXECUTORS, event fulfilment is a COMPOSING executor, the brain is stateless between ticks. Eight checkable clauses; every capability design (automation-brain tickets 03-06) and build plan must carry a Robustness section answering each, verified in review with evidence."
metadata:
  type: project
---

The **robustness bar** is the acceptance criteria every capability of the automation brain (the
standing global orchestrator — "B") must clear before it counts as complete. It exists because a
global orchestrator is the operator's stated complexity/bug fear; the bar is the guardrail that
keeps the brain from becoming fraught. Resolved in `.scratch/automation-brain/issues/02-robustness-bar.md`
(the wayfinder map is `.scratch/automation-brain/map.md`). See [[salvage-run-design]],
[[directives-feature]], [[ftl-authority-rule]], [[ami-drones-are-event-silent]],
[[device-tags-and-control-range]], [[confirm-steps-need-fresh-evidence]].

## The spine (organising principle)

**The brain is a pure *selector* over the existing safe rails.** It originates and ranks goals; it
never enacts them. Every command flows out through an executor → `CommandGovernor` → the
per-directive engine — machinery that already clears its own bar. The brain adds **choice, not new
powers**, so it grows no enactment path of its own.

Consequences that absorb three of the original candidate properties: **purity** (selection is all
the brain does), **one enactment path** (the brain has none of its own), and most of **blast
radius** (it can't corrupt an executor it never writes).

**Reframings this establishes (load-bearing for the primitive-contracts work):**
- print / deliver / shuttle are **new executors** (mission machines on the Survey/Salvage rails),
  NOT new brain powers.
- **event fulfilment is a *composing* executor** (print, then a series of deliveries) — composition
  lives in an executor, never in the brain.
- therefore **the brain is stateless between ticks**: its whole memory is "which executors are
  running," re-read from the directive rows each tick, like `evaluateOnce`. (Held "for now".)

## The eight clauses

Each capability design must show how it clears every clause; review verifies each **with evidence**.

1. **Selector, not enactor.** Brain's only writes are *launch* (create a directive) / *retire*
   (cancel one) **plus driving the sanctioned `DirectiveResolutionClient` verbs (`retry`/`cancel`) as
   an automated operator**, via existing mechanisms; it **never hand-edits** a running directive's
   step/target/status directly. Multi-step behaviour — and all *supply* (composing `print`/`deliver`/
   `shuttle`) — is always an executor; the brain does allocation, never composition. — *Check:* no
   brain command bypasses `CommandGovernor`; no brain code mutates an executor's rows except through
   the sanctioned resolution verbs (safe, single-transaction, logged-no-op-guarded — the same surface
   a human uses); `skipTarget`/`pause`/`resume` stay operator-only (auto-skip remains rejected).
   *(Widened by the brain↔executor seam, `.scratch/automation-brain/issues/04-brain-executor-seam.md`;
   see [[brain-executor-seam]].)*
   **One stated exception, found when `tendMesh` shipped:** the write list above is GAME-STATE writes.
   The confirm-read gate (`Brain.confirmCarrier` → `DeviceRefreshClient.refresh(_, .high)` →
   `PollCoordinator` → `Reconciler.ingest`) also upserts `Device` and inserts/upserts `Operation` rows
   as a local-mirror sync — the shared path every feature uses, not a mutation the brain composes.
   Audit clause 1 against that reading, not against a closed three-item list; see
   [[brain-tendmesh-build]].
2. **Stateless between ticks.** No execution state; each tick re-derives goals from the snapshot +
   running-directive rows. — *Check:* a tick is a pure function of (snapshot, running directives).
3. **Selection is pure; the API vetoes, never chooses.** Ranking is pure over the `WorldView`
   snapshot; the only network in the loop is the at-dispatch confirm-read, whose sole authority is
   to abort/defer an already-chosen goal. — *Check:* the confirm-read only proceeds or defers, never
   re-ranks. ("Network" = the API; local persisted state is the pure input, governed by clause 4.)
4. **Snapshot fidelity (three tiers).** (a) **Ride what flows** — SSE drain + executors' reads, no
   dedicated brain poller (ticket 01's rule). (b) **One-way facts stay sticky** — depleted /
   fullyScanned / meshed, so ranking can't un-rot them. (c) **Confirm-fresh before any
   irreversible/expensive commitment** — spend, permanent emplacement, strand-risking delivery;
   reachability from the authoritative `in_control_range`, never a derived-mesh view. Cheap/reversible
   goals may run best-effort. — *Check:* each design names how each ranking input stays honest + which
   commitments are confirm-fresh gated. **Net: staleness degrades efficiency, never safety.**
5. **Determinism / testability.** Exercised under `TestClock` over scripted world states,
   **end-to-end through the real dispatch-to-rails seam** (executors faked below). — *Check:* a
   pure-unit test of the ranker alone does NOT satisfy the bar. (The salvage lesson:
   `SalvageTargetPlanner` was unit-green with zero production callers and the inverse filter.)
6. **Safe degradation.** Transient → **defer with backoff** (no thrash/no budget burn — salvage 60s
   idle, `.deferred` writes nothing); unknown → **left alone, never guessed** (`isFullyScanned(nil)
   == false`); persistent failure → **escalate to a visible stall**. Idle is surfaced but NOT
   escalated (efficiency signal); stall is surfaced AND escalated (fault signal). In doubt: idle or
   stall, never guess and act. — *Check:* every non-acting state carries a surfaced reason —
   **"silently hang" is a violation.**
7. **Bounded blast radius.** Worst case of any single decision = a wasted trip or an
   operator-resolvable stall — **never** corruption, a stranded/unrecoverable fleet, or a breached
   ceiling. Enforced by: **additive writes** (cl. 1); **don't-strand** (no delivery outside command
   range without the mesh/recovery that restores it — a deliver/shuttle contract obligation);
   **rail-enforced spend ceiling** (a gate at *enactment*, sibling to `CommandGovernor`, unbreachable
   even by a buggy brain — its value + what counts as spend is policy for tickets 03/06). — *Check:*
   each design states its worst case and shows it's within the bound.
8. **Inspectability — the live "why" view (the minimum viable version).** An always-available,
   **derived** surface (no new table, like `WorldView`): ranked goals + inputs; the gate on the top
   goal (dispatching / deferred / idle / stalled + reason); and limit pressure — governor headroom,
   ceiling headroom, any recent **429**. Actions ride the existing `DirectiveLogEntry` timeline (a
   launch is a new directive, a retire is a cancel — both already logged). — *Check:* any brain state
   can be explained live; one that can't is a violation. A durable idle/defer **history** is out of
   scope (deferred to fog).

**Limits are signals, not walls.** The brain doesn't own its limits. Whenever our machinery
(`CommandGovernor` / the spend-ceiling sibling) or the server (an HTTP **429**) restricts the brain,
that restriction is surfaced to the operator, never swallowed — the 429 especially, since it means
we mis-estimated and it must show distinct from our own self-throttling.

## Enforcement

Every capability design (automation-brain tickets 03–06) and every build plan carries a
**"Robustness" section** answering each of the eight clauses; a design that can't answer a clause
**isn't done**. Code-review verifies each **with evidence** — clause 5 means a real
end-to-end-through-the-seam test, not a green unit test. No original candidate property was rejected;
**purity** and **one enactment path** were absorbed into the spine rather than kept as standalone
gates.
