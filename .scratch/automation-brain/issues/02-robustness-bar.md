# Robustness bar — the definition of done

Type: grilling
Status: open
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
