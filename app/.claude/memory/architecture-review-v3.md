---
name: architecture-review-v3
description: "ARCHITECTURE_REVIEW.md V3 (2026-07-20): post-SSE-migration five-axis review; ALL FOUR tranches (P0 correctness, P1 budget, P2 modularity, P3 docs/design-system) done 2026-07-20/21; only V3.9 automation blockers 3-5 + S9 + T6-optionals remain."
metadata:
  type: project
---

`ARCHITECTURE_REVIEW.md` gained a **V3 Review section (2026-07-20)** — a five-axis deep review after
the relay→native-SSE migration. Read it before touching the sync engine.

- **P0 correctness: ALL SIX FIXED 2026-07-20** (commits `e85c3f8`…`2fd14cd`; V3.10 records what each
  fix shipped). Invariants: sequential catch-up→connect with generation stamp + monotonic cursor;
  give-up measured from the first unanswered deadline; inspector loop torn down on
  disappear/background; completion events gated by op family + event time; `.staleGap` handoff +
  restart-through-catch-up; logout = ingestion teardown FIRST, then wipes; EventLog never cleared.
- **P1 budget: ALL FOUR DONE 2026-07-21** (branch `worktree-v3-p1-budget`, four reviewed commits).
  The read-budget architecture is now: (a) every post-command confirm-read funnels through
  `deviceRefresher` and stamps the coordinator TTL (the SSE echo is suppressed; a `.high` refresh
  never joins a pre-command in-flight read); (b) **`DomainFreshness`** (GameServices) gives
  inbox/locationEvents/ftlMesh trailing-debounce `invalidate` + TTL'd `refreshIfStale` — routes do
  nothing slow on the dispatch path; (c) **`StalenessTracker`** implements V3.5 mark-mostly
  ingestion: only live op-closing events read immediately, everything else (incl. ALL catch-up
  replay) marks; drain tiers visible→op-holding→aged-hidden (1/pass); marks are spent by
  `Reconciler.ingest → markSatisfied` under an issue-time guard; the inspector's selection is the
  visibility signal; (d) `Reconciler.applyEventFields` applies the envelope's first-class `location`
  (the device's post-event position — null in transit/stowed) for every device event, event-time
  guarded, stamp clamped to the local clock.
- **Live-traffic findings (2026-07-21)**: per-leg arrival events DO NOT exist post-migration
  (`travel.arrived` = whole-trip; payload destination/origin/travel_type/recalling); the docs event
  catalogue documents `print.started` but NOT `print.completed` — **S9 (the `new_device_code`
  payload key) is still unverified**; a loud route notice announces the real keys if a live
  completion ever lacks it. `location: null` vs omitted is undecodable — a future event omitting
  the field would wipe a row to "in transit" until its mark drains.
- **P2 modularity: ALL FIVE DONE 2026-07-21** (commits `753f822`…`88555da`, each LSP-reviewed
  pre-commit). New invariants: **`GameSession`** (GameClient+KeychainClient; deps API+Dependencies
  only) is the session tier below GameServices — a new domain client `import GameSession` for
  `\.gameClient`, and adds GameServices only for engine services; **no non-feature module declares
  ComposableArchitecture** (by manifest — GameServices/GameSync use `Dependencies`, AccountManager
  `Dependencies`+`Sharing`; rule recorded in CLAUDE.md's module recipe); **`EventRoute` lives in
  GameServices** (router stays in GameSync) and ingestion policies are module-exported
  (`MessagesIngestion`/`LocationEventsIngestion`/`LocationsIngestion` — the last is an instance
  whose `cancelPendingWork()` the root's logout handler must keep calling); UniverseModels is
  pure models behind the public `LocationDecoding` facade (Raw* wire DTOs stay internal);
  CommandClient = spine + `CommandClient+<Family>` files (new command family ⇒ new file + one
  `makeBody` case); GameModelsTests + SSEWire tests exist (S10 closed). **M5 deliberately NOT
  done**: Blueprints/Messages keep GameDatabase for live-store previews — a recorded decision,
  don't "clean it up".
- **P3 shining-example: ALL FOUR DONE 2026-07-21** (commits `a71435e`…`efd7b94`). New facts:
  `app/README.md` is the front-door map (keep it true when the graph changes);
  `IMPLEMENTATION_PLAN.md` is restored WITH an SSE-errata header — its § citations resolve again;
  "relay" in comments now means ONLY the FTL device; `IconSize` (s/m/l/xl/hero/display),
  `rcMicroMono`, `rcFieldLabel` exist — no raw icon/font literals in features (Login wordmark is
  the annotated exception); one log subsystem `name.pennig.replicould`, category = module;
  RCSectionHeader/RCErrorBanner are adopted, not aspirational; testValues are LOUD
  (`unimplemented`) with rich fixtures on `previewValue`; preview-sheet dismissals cancel their
  effects; Reconciler writes + schema bootstrap report failures via IssueReporting. CLAUDE.md
  carries the presentation-dialect, row-file, logging, loud-testValue rules and the
  UI-name↔type-name map.
- **Remaining**: V3.9 automation blockers 3–5 (budget-aware command governor, loop protection,
  RuleFiring audit trail — 1–2 are fixed), S9 print-key verification (loud notice armed), T6's
  deliberately-optional niceties, and the user's in-flight LoggingMiddleware edit (its logger
  still on the old `.api` subsystem).

Full prioritized punch list: V3.10. See [[event-stream-migration]].
