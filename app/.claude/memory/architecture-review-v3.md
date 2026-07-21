---
name: architecture-review-v3
description: "ARCHITECTURE_REVIEW.md V3 (2026-07-20): post-SSE-migration five-axis review; P0 correctness fixes + staleness model prescribed, none applied yet."
metadata:
  type: project
---

`ARCHITECTURE_REVIEW.md` gained a **V3 Review section (2026-07-20)** — a five-axis deep review after
the relay→native-SSE migration. Read it before touching the sync engine.

- **P0 correctness: ALL SIX FIXED 2026-07-20** (commits `e85c3f8`…`2fd14cd`, each subagent-reviewed;
  V3.10 records what each fix actually shipped). Post-fix invariants worth knowing: EventPipeline
  start is sequential (catch-up → connect) with a generation stamp + monotonic cursor saves;
  DeadlineScheduler give-up is measured from the first unanswered deadline (in-memory `overdueSince`);
  the inspector loop is torn down by `onDisappear`/`.background`; completion events are gated by op
  family + event time (`Reconciler.completionEvents` map — `travel.arrived`→recall and
  `scan.completed`→body-scan pairings are ASSUMED, not live-verified); the SSE client hands off via
  `.staleGap` and the engine restarts through catch-up (sleep/wake covered, no NSWorkspace hook);
  logout order = ingestion teardown FIRST, then wipes (registration order is load-bearing in
  `ReplicantApp.init`); EventLog is deliberately never cleared on logout.
- **P1 budget**: command confirm-reads bypass `deviceRefresher` (2-3 reads/command); FTL-mesh route
  = O(relays) serial reads per `relay.*` event ON the router hot path; message/story routes
  un-debounced; **V3.5 prescribes the staleness model** (StalenessTracker + mark-mostly device route
  + drain loop + refreshIfStale + DomainFreshness) — the design for "leverage SSE payloads / mark
  stale" work.
- **Automations**: graph-clean to build, but blocked on replay immunity (the P0 pipeline fixes),
  router hot-path isolation, and a budget-aware command governor. See V3.9.

Full prioritized punch list: V3.10. See [[event-stream-migration]].
