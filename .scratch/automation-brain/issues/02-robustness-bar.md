# Robustness bar — the definition of done

Type: grilling
Status: resolved
Blocked by:
Labels: wayfinder:ticket

## Question

What explicit standard must every brain capability clear before it counts as complete?

This ticket exists because B (a global orchestrator) is the operator's stated
complexity/bug fear. The bar is the guardrail: a written, checkable standard that keeps the
brain from becoming fraught, applied to every capability design as a definition-of-done gate.

Candidate properties to accept, sharpen, or reject:
- **Purity.** The brain's decision is a pure function over a world snapshot (like the
  clock-driven engine), touching the network only to *enact* a chosen goal — never to decide.
- **Determinism / testability.** Fully exercised under `TestClock` with scripted world
  states; no observation plumbing to get wrong.
- **Safe degradation.** Uncertain or contended ⇒ **idle**, never thrash. Backoff on empty
  frontiers (the salvage 60s idle precedent). An unknown situation is left entirely alone,
  never guessed (the "unknown scan counts are never fully-scanned" precedent).
- **One enactment path.** Every command the brain issues still flows through
  `CommandGovernor` (budget + per-device in-flight claim) and the per-directive engine —
  the brain originates goals, it does not bypass the machinery.
- **Inspectability.** A "why did the brain do / not do X" surface — the operator can always
  see the goal, the reasoning inputs, and the contention that shaped a decision. What is
  the minimum viable version of this?
- **Blast radius.** Can a bad decision corrupt data or strand a fleet, or is the worst case
  a wasted trip / a stall the operator resolves? What invariants bound the blast radius?

Output: a short, checkable bar that tickets 03–06 and every downstream build must cite.
Independent of ticket 01 — this is a philosophy/standard call and sits on the frontier now.

## Answer

The bar is the acceptance criteria for every brain capability. Canonical home:
`app/.claude/memory/brain-robustness-bar.md` (so out-of-map build/review sessions cite it);
this Answer is the resolution of record.

### The spine (the organising principle)

**The brain is a pure *selector* over the existing safe rails.** It originates and ranks
goals; it never enacts them. Every command flows out through an executor →
`CommandGovernor` → the per-directive engine — machinery that already clears its own bar. The
brain adds **choice, not new powers**, so it grows no enactment path of its own to audit.

Three of the ticket's six candidates stop being separate gates and become consequences of the
spine: **purity** (selection is all the brain does), **one enactment path** (the brain has no
enactment path of its own), and most of **blast radius** (it can't corrupt an executor it
never writes).

**Key reframings established while grilling (load-bearing for 05):**
- The new "primitives" — **print / deliver / shuttle — are new executors** (mission machines
  on the same rails as Survey Run / Salvage Run), not new brain powers.
- **Event fulfilment is a *composing* executor** (print, then a series of deliveries), not a
  brain responsibility. Composition lives in an executor; the brain never sequences sub-goals.
- Hence **the brain is stateless between ticks** — its whole memory is "which executors are
  running," re-read from the directive rows each tick, exactly like `evaluateOnce`. ("for now.")

### The eight clauses (each design shows how it clears every one; review verifies with evidence)

1. **Selector, not enactor.** The brain's only writes are *launch* (create a directive) and
   *retire* (cancel one), **plus driving the sanctioned `DirectiveResolutionClient` verbs
   (`retry`/`cancel`) as an automated operator**, via existing mechanisms; it **never hand-edits** a
   running directive's step/target/status directly. Multi-step behaviour — and all *supply*
   (composing print/deliver/shuttle) — is always an executor (leaf: print/deliver/shuttle; composing:
   event fulfilment, tendMesh); the brain does allocation, never composition. — *Check:* no brain
   command bypasses `CommandGovernor`; no brain code mutates an executor's rows except through the
   sanctioned resolution verbs; `skipTarget`/`pause`/`resume` stay operator-only (auto-skip remains
   rejected). *(Widened by ticket 04, the brain↔executor seam.)*
2. **Stateless between ticks.** No execution state; each tick re-derives goals from the world
   snapshot + running-directive rows. — *Check:* a tick is a pure function of
   (snapshot, running directives); no persistent working memory.
3. **Selection is pure; the API vetoes, never chooses.** Ranking is pure over the `WorldView`
   snapshot; the only network in the loop is the at-dispatch confirm-read, whose sole authority
   is to abort/defer an already-chosen goal. — *Check:* the confirm-read has two outcomes —
   proceed or defer — and never re-ranks. ("network" here = the API; local persisted state is
   the pure function's *input*, governed by clause 4.)
4. **Snapshot fidelity (three tiers).** (a) **Ride what already flows** — SSE drain +
   executors' confirm-reads; no dedicated brain poller (ticket 01's rule). (b) **One-way facts
   stay sticky** — depleted / fullyScanned / meshed are recorded so ranking can't optimistically
   un-rot them. (c) **Confirm-fresh before any irreversible/expensive commitment** — spend, a
   permanent emplacement, or a strand-risking delivery; reachability is read from the
   authoritative `in_control_range`, never a derived-mesh view. Cheap/reversible goals may run
   best-effort (worst case a bounded wasted trip). — *Check:* each design names how each ranking
   input stays honest and which commitments are confirm-fresh gated. **Net guarantee: staleness
   degrades efficiency, never safety.**
5. **Determinism / testability.** The decision is exercised under `TestClock` over scripted
   global world states, **end-to-end through the real dispatch-to-rails seam** (executors faked
   below). — *Check:* a pure-unit test of the ranker alone does **not** satisfy the bar; the
   end-to-end seam test does. (This is the salvage lesson: `SalvageTargetPlanner` was unit-green
   with zero production callers and the inverse filter.)
6. **Safe degradation.** Transient uncertainty/contention → **defer with backoff** (no thrash,
   no budget burn — the salvage 60s idle / `.deferred`-writes-nothing precedents); unknown →
   **left entirely alone, never guessed** (`isFullyScanned(nil) == false`); persistent failure →
   **escalate to a visible stall**. Idle is surfaced but **not** escalated (an efficiency signal);
   stall is surfaced **and** escalated (a fault signal). In doubt: idle or stall, never guess and
   act. — *Check:* every non-acting state carries a surfaced reason — **"silently hang" is a
   violation.**
7. **Bounded blast radius.** Worst case of any single decision = a wasted trip or an
   operator-resolvable stall — **never** data corruption, a stranded/unrecoverable fleet, or a
   breached ceiling. Enforced by: **additive writes** (clause 1); **don't-strand** (no delivery
   outside command range without the mesh/recovery that restores it — a deliver/shuttle contract
   obligation for 05); **rail-enforced spend ceiling** (a gate at *enactment*, sibling to
   `CommandGovernor`, unbreachable even by a buggy brain — the ceiling's value + what counts as
   spend is policy for 03/06). — *Check:* each design states its worst case and shows it's within
   the bound.
8. **Inspectability — the live "why" view (its minimum viable version).** An always-available,
   **derived** surface (no new table — like `WorldView`): the ranked goals + ranking inputs; the
   gate on the top goal (dispatching / deferred / idle / stalled + reason); and limit pressure —
   governor headroom, spend-ceiling headroom, and any recent **429**. The brain's *actions* ride
   the existing `DirectiveLogEntry` timeline (a launch is a new directive, a retire is a cancel —
   both already logged). — *Check:* any brain state can be explained live; a state that can't is a
   violation. A **durable idle/defer *history*** is out of scope (deferred to fog — graduate only
   if the live view proves insufficient).

**Limits are signals, not walls.** The brain doesn't own its limits. Whenever our machinery
(`CommandGovernor` / the spend-ceiling sibling) *or* the server (an HTTP **429**) restricts the
brain, that restriction is surfaced to the operator, never swallowed — the 429 in particular
means we mis-estimated and must show it, distinct from our own self-throttling.

### Enforcement

Every capability design (03–06) and every build plan carries a **"Robustness" section** that
answers each of the eight clauses explicitly; a design that can't answer a clause **isn't done**.
Code-review verifies each clause **with evidence** — clause 5 in particular means a real
end-to-end-through-the-seam test exists, not a green unit test.

### Notes for downstream tickets

- **03 (goal/decision policy)** owns the spend-ceiling *value* and what counts as spend (clause 7
  fixes only that a hard, rail-enforced ceiling exists).
- **05 (primitive contracts)** inherits the reframing: print/deliver/shuttle are executors,
  event fulfilment is a composing executor, and the deliver/shuttle contract must satisfy
  **don't-strand** (clause 7).
- No candidate property was rejected; **purity** and **one enactment path** were *absorbed into
  the spine* rather than kept as standalone gates. Nothing surfaced as out-of-scope.
