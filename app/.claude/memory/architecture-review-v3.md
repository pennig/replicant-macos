---
name: architecture-review-v3
description: "ARCHITECTURE_REVIEW.md V3 (2026-07-20): post-SSE-migration five-axis review; P0 correctness fixes + staleness model prescribed, none applied yet."
metadata:
  type: project
---

`ARCHITECTURE_REVIEW.md` gained a **V3 Review section (2026-07-20)** — a five-axis deep review after
the relay→native-SSE migration. Read it before touching the sync engine. Headlines (none fixed yet as
of the review date):

- **P0 correctness**: catch-up races the live stream (`.catchUp` provenance is a coin flip;
  EventPipeline.start connects before catchUp) + non-monotonic cursor saves; DeadlineScheduler
  `giveUpAfter` measured from `startedAt` (any op >5min that slips its ETA → falsely `unknown`);
  device-inspector refresh loop leaks past view removal (no `viewingChanged(nil)` on teardown, no
  scenePhase gating anywhere); `completeOpenOperation` has no event-time/kind guard; dead stream is
  silent (`onStreamError` nil, `resumeStream` uncalled); no gap repair on reconnect/wake; logout
  misses 6 tables (Blueprint, KnownReplicant, SystemDetail, LocationFootprint, FTLLinkRecord,
  EventLog) + cursor + unstructured tasks.
- **P1 budget**: command confirm-reads bypass `deviceRefresher` (2-3 reads/command); FTL-mesh route
  = O(relays) serial reads per `relay.*` event ON the router hot path; message/story routes
  un-debounced; **V3.5 prescribes the staleness model** (StalenessTracker + mark-mostly device route
  + drain loop + refreshIfStale + DomainFreshness) — the design for "leverage SSE payloads / mark
  stale" work.
- **Automations**: graph-clean to build, but blocked on replay immunity (the P0 pipeline fixes),
  router hot-path isolation, and a budget-aware command governor. See V3.9.

Full prioritized punch list: V3.10. See [[event-stream-migration]].
