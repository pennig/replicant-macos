# Replicould macOS — Architecture Review

_Reviewer: Claude (Opus 4.8). Date: 2026-06-25. Scope: modularity, extensibility, and fitness for the core requirement — driving long-running server actions and giving best-effort real-time progress feedback while minimizing polling against a rate-limited, increasingly-paged API._

_Revised 2026-06-25 with answers to §7's open questions folded in. The most consequential answers: dispatch responses come in two shapes (some return full entity state, some only "enqueued"); the relay is **account-wide** while backfill is per-replicant; and a heavy account has **fewer than 10 replicants but hundreds-to-1000+ devices.** These reshaped §4.2, §5, §6, and §7._

_Revised again 2026-06-25: the relay is confirmed reachable (`https://replicant.pennig.name/api/stream`) and is a **single SSE connection multiplexing three logical streams** — game events, account messages, and Bobnet chat. `GameSync` must therefore be a router/demultiplexer, not just an event→row mapper. See §5.1 (now §5.1's "router" framing) and the new §4.5._

_**V2 — 2026-07-03.** Most of the architecture prescribed below is now built, and built faithfully. This revision records conformance, the three points where the implementation drifted from the spec (one of them defeats the §5.3 correctness guarantee), and a concrete **shared-layer / module split** proposal for the `DependencyClients` god-module concern raised in §3.3. It is written as a self-contained update: the sections below (§1–§7) are preserved verbatim as the original design record._

_**V3 — 2026-07-20.** A fresh five-axis deep review after the largest architectural shift since this document began: backend v2.3.0's **first-party SSE endpoint replaced the custom Rust relay** (2026-07-19). Everything in §4.5/§5.1 and the V2 text that says "relay" describes decommissioned infrastructure — the V3 section opens with the concept-migration map. V3 covers: sync-engine correctness post-migration, API-budget discipline, a prescribed **staleness / payload-leverage model** (the missing piece), TCA/Point-Free fidelity, modularity, approachability, and **automations readiness**. **Read the "V3 Review" section immediately below first.** V2 and §1–§7 remain as the historical design record._

This is a reference document, not a change request. It is organized as: (1) verdict, (2) what the codebase gets right, (3) modularity/extensibility critique, (4) the core problem reframed, (5) candidate architectures for the core problem with trade-offs, (6) prioritized recommendations, (7) open questions for you to resolve with your product context.

---

# V3 Review — 2026-07-20

_Method: five parallel deep-dive reviews (sync engine, API budget, TCA fidelity, modularity, approachability/design-system), each reading sources in full, cross-verified against a first-hand read of the entire sync core. Scope: the whole app package (24 targets, ~46k LOC, 219 Swift files) plus the app target and docs._

## V3.1 Verdict

**The architecture survived its first major migration with its spine intact — and that is the strongest possible evidence the design is right.** The relay → native-SSE cutover deleted an entire subsystem (RelayClient, RelayRoute, fingerprint dedup, three-channel multiplexing) and the replacement landed *simpler*: one envelope, one cursor, one choke point, dedup by server stream id. Every V2 punch-list item is verifiably done. The module graph's three invariants held under three weeks of rapid growth (11 features): **acyclic, zero feature→feature edges, TCA-free GameModels**. TCA/Point-Free usage remains reference-quality. The codebase is genuinely close to the "shining example" bar.

What stands between it and that bar, in order of consequence:

1. **The stream startup choreography contradicts its own design** — catch-up and the live stream race, so replayed history can arrive tagged as live, and the provenance guard everything downstream trusts is currently a coin flip (V3.3-S1). This is also the single blocker for safe automations.
2. **Two operation-layer logic bugs** silently mis-state operation history (the `giveUpAfter` clock, the unguarded completion event — V3.3-S3/S4).
3. **Three read-budget leaks** — a poll loop that outlives its view, an un-debounced O(relays) mesh rebuild on the event hot path, and command confirm-reads that bypass the coordinator and double-pay (V3.4).
4. **The staleness model doesn't exist yet.** Today's event policy is binary — read-now or forget. The design in V3.5 is the piece that turns "responsible API usage" from discipline into structure, and it slots into the existing `PollCoordinator`/route registry with no re-architecture.
5. **The documentation layer rotted while the code stayed clean** — the relay narrative survives in three docs and ~20 files' comments, and the deleted `IMPLEMENTATION_PLAN.md` is still cited by section number from 11 production files (V3.8).

Nothing needs re-architecting. Every finding below is a targeted fix inside the existing shapes.

## V3.2 The migration map — what replaced what, and what held

| V2 concept (dead) | V3 reality (live) |
|---|---|
| Custom Rust relay at `replicant.pennig.name/api/stream`, separate static bearer token | First-party `GET /v1/events/stream`, ordinary session token read fresh from Keychain per (re)connect (`EventStreamClient.swift`) |
| `RelayClient` + `UnifiedEvent` + SHA-256 fingerprint dedup across relay/game-log channels | `EventStreamClient` + `GameEventEnvelope`; dedup = "seen this Redis stream id?" (`BoundedEventIDSet`, O(1) FIFO) |
| Three multiplexed logical streams (`event`/`message`/`bobnet`) | One channel, one dotted taxonomy (`travel.arrived`, `print.completed`, `site.depleted`, `scan.completed`…); `category` + first-class `star`/`location` envelope fields |
| `RelayRoute` registry (tier-2 `gapRepair` **inert** — V2 finding) | `EventRoute`/`EventMatcher`/`EventRouter`; `gapRepair` **wired and tested**; messages + location-events own real tier-2 |
| Per-replicant game-log backfill (tier-2) | Account-wide `GET /v1/events` pull, cursor-gated (15-min freshness window), bounded (2000-event cap) |
| `RelayCursorStore` (foreign id space) | `EventCursorStore` under `replicant.events.cursor` (deliberately fresh key) |

**V2 punch-list audit — all six items done and verified:** reconciliation clock (request-issue-time stamp, regression-tested) ✅ · `print_complete` off the fleet walk (single coordinated read, regression test fails on any walk) ✅ · `GameModels` extraction + zero feature→feature edges ✅ · tier-2 `gapRepair` + continuous-mining sweep backstop ✅ · design-system composites + tokens shipped ✅ (adoption regressed — V3.8) · watch items (bad-token retry stop, `PrintingUI`, cursor-gated backfill, `GameServices` rename) ✅.

New since V2 and **done well**: the `EventRouter.dispatch` choke point logs every event with payload at `.info`, flags non-device events with no specific route as `⚠️ UNHANDLED` at `.notice`, and persists every envelope to the `EventLog` ledger (Tools ▸ Event Log window) with an `isHandled` flag mirroring the dispatcher's own logic — the taxonomy-discovery loop §4.4's forward-compat note demanded, actually operationalized. Budget surfacing (V2 rec #3) is done: `gameClient.budget(.reads)` exists and the `PollCoordinator` defers low-priority reads at a 12-token floor.

## V3.3 Sync-engine correctness (the load-bearing findings)

**S1 [critical] — Catch-up races the live stream; `.catchUp` provenance is a coin flip.** `EventPipeline.start()` connects the SSE stream from the *pre-catch-up* cursor immediately (`EventPipeline.swift:66`), while `catchUpIfStale` runs as a parallel task (`GameSync.swift:140`). When the cursor is stale — exactly the case catch-up exists for — the server replays the whole gap **over SSE tagged `.stream`**. The roster-advance route explicitly gates on `.stream` to avoid "walking the roster through stale waypoints" (`ReplicantApp.swift:148`); that guard now depends on which channel wins the dedup insert, per event. The pipeline's own header documents the intended sequence ("catch-up… *then* open the stream from the tip"); the implementation inverted it. **Fix:** await `catchUp()` before `resumeStream()` when the cursor is stale; belt-and-braces, treat events whose `createdAt` predates connect time as replay.
**S2 [major] — The persisted cursor is not monotonic.** Concurrent catch-up (saving per pulled event) and live ingestion (saving per frame) interleave at await points and can regress the stored cursor (`EventPipeline.swift:112` vs `:149`); a quit in that window replays the gap on next launch against a fresh dedup set. **Fix:** `saveIfNewer` comparing parsed Redis ids — the parser already exists (`cursorDate`). Sequencing per S1 removes most of the interleave.
**S3 [critical] — `giveUpAfter` measures from `startedAt`, so every op longer than 5 minutes that slips its ETA is falsely marked `unknown`.** `DeadlineScheduler.processDue` (`DeadlineScheduler.swift:145-155`): a 30-minute travel arriving 10s late hits the deadline, confirms "still travelling," and — because dispatch was 30 minutes ago — takes the give-up branch instead of the re-arm branch the whole mechanism was built around. The re-arm test dodges this by setting `startedAt` 50s back (`PollAndDeadlineTests.swift:230-234`) — the test was shaped around the bug. `unknown` is terminal, so the real completion is later re-adopted as a *new* op: history pollution, progress-bar identity loss. **Fix:** measure give-up from the op's original deadline (or count re-arm attempts); add a long-op regression test.
**S4 [major] — `completeOpenOperation` applies completion events with no event-time or kind guard.** A replayed/stale `site.depleted` closes *whichever* op is currently open on the device (`Reconciler.swift:205-272`) — even a travel op adopted after a server-driven re-task. §5.2 said "`kind` becomes a sanity check"; it is not checked at all, and `eventTime` is only stored, never compared. Self-heals on the next confirm-read, but history corrupts and any future automation keying on op completion misfires. **Fix:** skip when `eventTime < op.startedAt` (small skew tolerance) and sanity-check event family vs `op.kind`.
**S5 [major] — A dead stream is silent.** `GameSyncEngine` calls `pipeline.start()` without an `onStreamError` handler (`GameSync.swift:132`); on a mid-session 401/403 the stream finishes permanently, the engine's `for await` idles on a dry stream forever, and the app degrades to REST-only with no log, no retry, no UI signal — indistinguishable from "nothing is happening." `resumeStream` (built for exactly this) is dead code. **Fix:** wire the handler — log, back off, re-check the token, `resumeStream`; surface a live/stale indicator features can observe.
**S6 [major] — Reconnects and sleep/wake get no gap repair.** Reconnection lives entirely inside `EventStreamClient`'s retry loop, invisible to the pipeline; `catchUpIfStale` + `runGapRepair` run **only at `start()`**. A laptop asleep past stream retention wakes, reconnects, and silently loses the un-replayable middle. V2 prescribed repair on "launch/**wake**/error"; only launch survived the migration. **Fix:** surface reconnects (synthetic marker or move the retry loop up), run the stale-gated catch-up + gap repair on reconnect; add an `NSWorkspace.didWakeNotification` hook.
**S7 [minor] — Fixed-interval retry.** Transient stream errors retry at a flat 1s (clean closes at 100ms) with no exponential backoff or jitter (`EventStreamClient.swift:73,169,176`) — a fast-failing server gets hammered at 1–10 connects/sec. `hasConnected` already exists as the backoff-reset signal.
**S8 [minor] — Lifecycle leaks around `stop()`/logout.** The spawned catch-up/gap-repair tasks are unstructured and survive `stop()` (`GameSync.swift:140-141`) — a quick logout leaves a page walk running on the old token, advancing the cursor into a dead continuation. The scheduler `start()` task has a matching tiny race. Logout also never clears the event cursor or the six tables outside the current cleanup set (see V3.6 T2). **Fix:** retain + cancel the tasks in the engine actor; add a cursor-clear login/logout handler.
**S9 [watch] — `print.completed` still keyed to the pre-migration payload key** (`new_device_code`, `GameSync.swift:199-201`, self-documented as unverified). The UNHANDLED log will *not* catch a rename (the event carries a `deviceCode`, so it counts as handled); if the key changed, printed clones appear only on the next cold walk. One Event Log window check against live traffic settles it.
**S10 [nits]** — SSE parser trims full whitespace per `data:` line vs the spec's single leading space (harmless for JSON); the parser — the subtlest code in the module — has zero tests, as does `catchUp` paging; `catchUp`'s 2000-event cap can't signal "capped" vs "done"; `EventLog` grows unboundedly (only manual clear); empty `Modules/API/Sources/Relay/` directory.

## V3.4 API-budget discipline

The prescribed tiers are real and mostly honored: all four paged walks (devices, replicants, stars, blueprints) are cold-only behind empty-table gates and explicit refresh buttons; progress is a local clock everywhere; deadline confirmation skips the read when the completion event already closed the op; catch-up is bounded and cursor-gated; the governor's `min()` reconciliation, 429 penalize-with-jitter, and reserve floor are careful concurrency code. Two routes (passive scan, location events) model exactly the right trailing-debounce burst behavior, with written rationale.

The leaks (budgets: 120 reads/min, 60 actions/min):

**B1 [critical] — The device-inspector refresh loop outlives its view.** `DeviceDetailView` starts the while-viewing loop via `.task(id: refreshKey) { store.send(.viewingChanged(...)) }` (`DeviceDetailView.swift:114`); the loop itself is a store effect (`CancelID.refresh`, `DevicesFeature.swift:399-432`) cancelled only by `viewingChanged(nil)` — which nothing sends when the *view is removed* (sidebar category switch, window close): SwiftUI cancels the view task, not the store effect, and `MainFeature`'s eager state keeps the store alive. A viewed-once diverting device costs ~240 reads/hr forever; mining/diverting never settle to break the loop. There is **no `scenePhase`/occlusion/`onDisappear` handling anywhere in the repo** — §5.4's "visibility gating is load-bearing" is unimplemented. (The pattern itself — clock-driven cadence, pure tested `refreshDelay` — is exemplary; only teardown is missing.)
**B2 [critical] — FTL mesh rebuild: O(relays) serial reads per `relay.*` event, on the router's critical path.** Every relay event triggers a full mesh rebuild — one `GET devices/{code}/network` per relay, serial, un-debounced (`GameSync.swift:225-231`, `DevicesClient.swift:120-145`). Ten events × 15 relays = 150 reads — more than the entire minute's budget — and because `EventRouter.dispatch` awaits routes serially, a throttled rebuild **head-of-line-blocks all event ingestion** behind it. The star map additionally rebuilds on every pane appear. **Fix:** trailing debounce (the pattern exists 100 lines away); patch only the named relay's edges; move expensive applies off the dispatch path.
**B3 [major] — Message/story routes fire one head-page inbox read per event**, un-debounced (`ReplicantApp.swift:70-92`) — an overnight catch-up replaying 15 message events = 15–30 identical 50-row reads. Copy the debounce from the adjacent routes.
**B4 [major] — Post-command confirm-reads bypass the coordinator and double-pay.** `CommandClient` (`:177,204,316`) and `updateTags` call `devicesClient.read` directly, so the coordinator never stamps `lastReadAt` — the near-certain SSE echo (`travel.started`…) 1–2s later is not TTL-suppressed and reads again: 2–3 reads per command where 1 was designed. **Fix:** funnel through `deviceRefresher.refresh(code, .high)` (reconcile already happens inside the coordinator's task). Halves the cost of every command; also what the project's own memory note says is the rule.
**B5 [major] — No staleness model** — see V3.5.
**B6 [minor] — On-appear refetches ignore SSE-kept warmth.** `MessagesFeature.task` (1 read/visit) and `LocationEventsFeature.task` (**a full paged walk per pane appear**, `LocationEventsFeature.swift:88-96`) refetch unconditionally although their SSE routes keep those tables live; Devices/Blueprints/Replicants gate on empty-table correctly. This is where `refreshIfStale` (V3.5) belongs.
**B7 [minor] — Duplicate quest walks:** the deposit path (`CommandClient.swift:186-196`) and `LocationEventsClient.complete` each full-walk `accounts/events` when the SSE `event.*` echo will trigger the same (debounced) refresh — 2–3 walks per flow.
**B8 [minor] — Budget surfacing is built but nearly unconsumed**: two consumers total (coordinator floor, stars cooldown). No HUD, no actions-bucket consumer, no deferral for mesh rebuilds or paged walks. The `Snapshot` type was built for a budget HUD that still doesn't exist.
**B9 [watch]** — no catch-up provenance discount on the reads a replay triggers (50 replayed completions = 50 immediate high-priority reads at launch); a stuck deadline op can spend ~60 reads across its 5-minute give-up window (`rearmBackoff` 4s — add decay).

## V3.5 The staleness + payload-leverage model (prescription)

This is the gap between today's engine and the stated goal — *"leverage as much data from the SSE endpoint as possible to either update local state, or mark entities stale for interval/on-demand refresh."* Today's policy is binary: an event either triggers an immediate read (coalesced, 2s-TTL'd, budget-floored) or nothing; a suppressed/deferred refresh is **forgotten**, not remembered. And device rows never absorb payload data — every device event costs a read even when the payload carried the fact (per-leg travel locations, mining yields, status transitions are discarded; only op-closing results, bobnet messages, scan-payload catalog ingestion, and the roster fast-path use payloads today — those four are the model to generalize).

**Event-handling policy (replaces the device route's uniform confirm-read):**

| Event class | Action | Reads |
|---|---|---|
| Op-closing (`print.completed`, `travel.arrived`, `site.depleted`, `scan.completed`) | Close op from payload (as today) + **one** high-priority confirm-read (finished activity block must clear) | 1 |
| Payload-complete field change (per-leg arrival's `location`, status transitions) | **Apply directly** via a new `Reconciler.applyEventFields(deviceCode:fields:eventTime:)` — guarded by `eventTime >= existing.updatedAt` (skew tolerance documented) — then **mark stale** instead of reading | 0 |
| Thin/ambiguous/unknown device event | **Mark stale** (today: immediate low read) | 0 now; ≤1 later |
| `provenance == .catchUp` | Mark stale only, never immediate reads (today: full price) | 0 now |
| Non-device domain events (message, quest, mesh) | Set a domain-level stale flag; debounced drain per domain | amortized |

**Mechanism (three small pieces, no re-architecture):**

1. **`StalenessTracker` actor (GameServices)** — `stale: [deviceCode: (markedAt, reason)]` + a visibility registry (`setVisible(_:)` fed by DevicesView/DeviceDetailView `.task`/teardown, `MainFeature`'s active category, and `scenePhase != .active` clearing the set — which also structurally fixes B1). `drainCandidates(budget:)` orders visible-first, then op-holding, then FIFO.
2. **A drain loop on `PollCoordinator`** (mirror of `DeadlineScheduler.run`): every 5–10s and immediately on visibility change, drain candidates through the existing `refresh(_:priority:)` path — TTL, coalescing, and the budget floor all still apply. Non-visible, non-op devices *stay marked at zero cost* until viewed.
3. **`refreshIfStale(code)` / `refreshIfStale(domain:)`** — the on-demand entry: read only if marked stale or older than a per-tier TTL (visible ~30s; hidden ∞). The inspector's selection path and the B6 on-appear refetches become calls to this. A tiny `DomainFreshness` map generalizes it for `inbox`/`locationEvents`/`ftlMesh`/`roster`, replacing the three ad-hoc `LockIsolated<Task>` debounces in `ReplicantApp` with one mechanism that gives every domain interval *and* on-demand semantics.

In-memory state is sufficient — relaunch staleness is already covered by cursor-gated catch-up plus the cold-load gates. (A nullable `staleAt` column is a one-migration upgrade later if wanted.) Net effect: an event burst costs O(1) marks instead of O(events) reads; catch-up costs zero immediate reads; hidden entities cost nothing until looked at; and "refresh cadence" becomes one tunable drain policy instead of N scattered call sites.

## V3.6 TCA / Point-Free fidelity

**The V2.3 "reference-quality" verdict holds after an 11-feature growth spurt** — which is the harder test. Verified across every feature module: domain collections live in SQLite observed via `@FetchAll`/`@FetchOne`/`@Fetch` in `@ObservableState` with reducers holding only intent; zero Combine, zero legacy `ViewStore`, zero direct `UserDefaults`, `#sql` strictly DDL-only, migrations centralized in `GameDatabase`; all ~15 clients are struct-of-closures whose `liveValue` resolves `@Dependency(\.gameClient)` internally — no feature builds a client, the token is never threaded. Clock discipline (`continuousClock`) is universal *in reducers*. Teaching-example material: `AppFeature`'s `@Reducer enum` session root with synchronous first-frame resolution; the while-viewing cadence loop (pure, tested `refreshDelay`); `EndEditingClient` (AppKit global as a documented dependency); `LocationForest: FetchKeyRequest` + in-place `$forest.load` (kills empty-state flashes); `ReplicantsFeature`'s full enum-destination navigation kit; `TravelUI`/`PrintingUI` as store-free shared UI; single-writer `@Shared(.account)` discipline.

Drift to correct:

- **T1** — `PrintQueueDetailView.swift:53` uses `.sheet(isPresented:)` for the print preview, the exact bug class the project's own rule ("preview sheets need `.sheet(item:)`") exists to prevent; the other three call sites were already fixed. One straggler.
- **T2 [major]** — **Logout teardown is incomplete**: `Blueprint`, `KnownReplicant`, `SystemDetail`, `LocationFootprint`, `FTLLinkRecord`, `EventLog` are never cleared (6 of 13 tables), so a second account inherits the first's data *and* the "if count == 0" cold-load gates then skip the correct fetch. Plus the S8 unstructured tasks. Fix: a wipe-all handler enumerating off `GameDatabase`, and task retention in the engine.
- **T3 [major]** — **IssueReporting is essentially unadopted**: one production `withErrorReporting` vs ~142 `try?`s, including `prepareDependencies { try? bootstrapDatabase() }` (a failed schema bootstrap = silently broken app) and every `Reconciler` write (a DB failure in the correctness core vanishes). Keep genuine best-effort `try?`s; wrap the correctness core and bootstrap.
- **T4** — Two presentation dialects coexist: the PF idiom (Login's `AlertState`, Replicants' enum destination) vs the house dialect (parallel presentation optionals + `String?` errors + hand-rolled bindings in Devices/PrintQueue/Locations/StarMap), with inconsistent dismissal-cancellation. The house dialect is a defensible trade for plain-value sheets — but **pick it deliberately**: bless it in CLAUDE.md (value sheets → optionals; feature sheets → `@Presents`) and make dismissal cancel uniformly, or converge on `@Presents` enums.
- **T5** — `testValue` discipline is split ~50/50 between loud `unimplemented` and quiet inert stubs (`CommandClient`, `MessagesClient`, `LocationsClient`, `StarsClient`…) — a TestStore test that forgets to stub passes silently today. Promote the quiet ones.
- **T6 (smaller)** — NewStarMap keeps five primary `@FetchAll`s view-local (undocumented exception — defensible for a Metal renderer; write it down); `BlueprintDetailView` re-derives selection from a view-local query instead of state (unify); `PreferencesFeature` declares a `BindingReducer` nothing uses; the CommandGrid embeds real policy (availability gating, directive seeding) in the view — extract to `DevicePresentation` per the established precedent; composition-root debounces use raw `Task.sleep` instead of the clock (untestable — a small clock-based `Debouncer`, which V3.5's `DomainFreshness` would subsume anyway); two XCTest files remain vs 36 swift-testing; zero `expectNoDifference`/`customDump` despite the house skill; no Tagged types (raw `String` codes everywhere) and `CommandParams` is a nine-optional bag — the one PF nicety left unadopted, adopt opportunistically or never, but decide.

## V3.7 Modularity

**Invariants verified: acyclic ✅ · zero feature→feature edges ✅ · GameModels TCA- and SwiftUI-free ✅ · composition only in the root ✅.** The V2.5 surgery took, and the layering demonstrably works: `GameSync` is the churn leader (16 touches since 06-20) with a blast radius of **one** target — the clearest delivered win — and `TravelUI`/`PrintingUI` (3 and 2 consumers, 3-symbol surfaces, plain values + callbacks) prove the shared-UI template. A sweep found **no remaining cross-feature view duplication**. iOS portability is surprisingly good: the entire shared layer is AppKit-free; AppKit is confined to ~7 files + the app target.

- **M1 [high]** — **`UniverseModels` drifted into models-plus-clients**: `StarsClient`/`LocationsClient` live there and force `UniverseModels → GameServices`, which drags `GameDatabase` (which only needs the *migrations*) transitively **above the service layer** — so engine edits rebuild the schema composer and, via preview-only edges (M5), Blueprints/Messages. Move the two clients to `GameServices`; `UniverseModels` then matches `GameModels`' clean shape and `GameDatabase` drops below services. ~2 file moves; dependency keys unchanged.
- **M2 [high]** — **`CommandClient` is a god-file again (34KB → 42.7KB / 756 LOC)** and `GameServices` edits rebuild 16 of 24 targets. Two-part fix: (a) decompose by command family (`CommandFamily+Travel/+Mining/+Printing/+Lifecycle` — the spine stays; a new family becomes a new file, not 100 more lines in the hottest file); move the embedded scan-sightings side-channel out of the generic dispatcher. (b) **The deferred `GameSession` split's trigger has fired**: read-only features (Blueprints, Messages, Account, Sidebar) import `GameServices` *only* for `\.gameClient` (verified) and ride every engine edit — the exact promise the V2.5 split made and measurably didn't deliver for them. Extract `GameClient` + `KeychainClient` into `GameSession`.
- **M3 [medium]** — **The composition root accreted ~225 lines of ingestion policy** (`registerGameSync`, `ReplicantApp.swift:43-266`): debounce state machines, DB writes, event-name matching — in the one target with no test target. The *decisions* are in tested modules (`LocationEventPolicy.decide` — itself the miniature rules-engine pattern); the glue isn't. Have owning modules export declared `EventRoute` values (`MessagesFeature.eventRoutes` etc.) so the root collapses to ~10 registration calls. Building Automations would force this anyway — do it first.
- **M4 [medium, cheap]** — `GameServices`/`GameSync`/`AccountManager`/`UniverseModels` declare full `ComposableArchitecture` but use only `@Dependency`/`DependencyKey` (zero TCA symbols, verified). Swap to `swift-dependencies` so "TCA is for features" is true *by manifest*, not just discipline.
- **M5 [low]** — Blueprints/Messages depend on `GameDatabase` solely for `#Preview` bootstrap (9 other features manage without); drop for consistency. **M6** — delete the vestigial root `app/Package.swift` ("ReplicantKit" — target dir doesn't exist, zero pbxproj refs). **M7** — remove the stale `ReplicantsFeature → API` declaration. **M8** — eager instantiation of all 11 feature states (~15 SQLite observations from login) is *not* the V2-feared polling hazard (effects are appearance-gated) but grows linearly; adopt lazy content panes (the `account` `@Presents` pattern) when login cost becomes measurable. **M9** — rename `NewStarMapFeature` → `StarMapFeature` when convenient; record the UI-name mapping (Event Log → "Operations Log", Location Events → "Missions") in module headers.
- **Test-target gaps**: **GameModels has no test target at all** — it holds every tolerant `init(schema:)` mapping, the app's malformed-payload firewall, currently tested only incidentally. That plus the SSE parser (S10) are the two highest-value test additions. The app target is the only untestable code (M3 reduces it).

## V3.8 Approachability ("a mere mortal") + design system

The code itself clears the bar: **zero TODO/FIXME/HACK across 45.8k lines**, two commented-out lines total, constraint-stating file headers as the uniform house style (`Reconciler`, `EventPipeline`, `EventStreamClient`, `LocationEventRow`'s documented crash workaround), MARK discipline that scales, domain-honest naming. The docs do not:

- **D1 [high] — The relay narrative survives its own decommissioning.** This document (pre-V3), `relay/README.md` (still presents itself as live middleware; the app has zero references to it), and `NewStarMapFeature/README.md` (describes a standalone-app + bridging-header setup that predates the SPM `CShaderTypes` reality, and a procedural galaxy the live map replaced) would each send a newcomer building the wrong thing. `CLAUDE.md:55` points at a deleted file (`Event Log/GameLogFetching.swift` → now `EventStream/GameEventsFetching.swift`). `IN_SYSTEM_VISUALIZATION_PLAN.md` says "planned (not started)" above per-phase ✅ markers.
- **D2 [high] — `IMPLEMENTATION_PLAN.md` was deleted but is cited by section number from 11 production file headers** (`CommandClient`, `Reconciler`, `PollCoordinator`, `Operation`, `Device`, `BobnetMessage`, `GameSync`, `DeadlineScheduler`, `OperationProgressView`). The best comments in the codebase point at a 404. Restore it from git with an SSE-errata header, or rewrite the 11 citations.
- **D3 [high] — "relay" now means two things.** ~20+ files' comments use infra-sense "relay" (dead) in a codebase whose *game domain* has FTL relay devices (live: `relayLinks`, `relay.*` events, `StatusRelay`). One sweep: infra-sense "relay" → "event stream"/"SSE".
- **D4 — No "how it fits together" map.** The module graph is a 549-line `Package.swift`; the event and command lifecycles — the app's two central ideas — are assemblable only by reading five file headers in the right order. The 48 `.claude/memory/` fragments hold real institutional knowledge on an agent-facing shelf. **The single highest-leverage artifact is a 1–2 page `app/README.md`**: module-graph diagram, event lifecycle (SSE → pipeline → router → reconciler → SQLite → `@FetchAll`), command lifecycle (optimistic op → POST → confirm-read → reconcile → deadline), and a read-these-five-files-first path. Then: DESIGN_SPEC refresh (token tables are stale, §3.5 lacks all six composites, §5's sidebar is a different app); a CLAUDE.md "adding a feature" cookbook (where the domain client goes — the rule exists in practice but is written nowhere; row-structs-in-separate-files *because of the preview crash*; logging convention; route registration).
- **D5 — Design-token erosion: ~75–110 violations vs ~18 at the V2 cleanup**, concentrated in features built since. The galling class: exact token values re-inlined *after* the tokens shipped (`size: 28` = `rcDisplay`, `size: 9 semibold` = `rcMicro`); `RCErrorBanner` re-duplicated twice (Locations, LocationEvents — the control's own doc comment describes eliminating exactly this); **`RCSectionHeader` has zero adopters** vs 39 inline sites — adopt or delete, because a shipped-but-unused control teaches newcomers the design system is aspirational. The systemic gap: **no icon-size scale** — most raw font literals are SF Symbol sizes; add `IconSize.s/m/l/hero` and the sweep becomes mechanical. Colors and status→tone discipline, by contrast, held essentially perfectly, and `AccountFeature` shipped 100% token-conformant — proof the system works when used. Logging: one mechanism (`os.Logger`, no `print`) but five subsystem spellings including a stray `space.replicant.Replicould` (`GameDatabase.swift:96`); standardize (one subsystem, category = module).
- **D6 — Consistency divergences that confuse newcomers**: list-view naming (2 of 8 lack `ListView`); row placement (3 inline rows survive only because those files lack `#Preview` — the crash-trap memory makes separate files the rule); the Operations-Log naming knot (sidebar "Operations Log" = `ActivityView` inside DevicesFeature; module `EventLogFeature` = the Tools-menu SSE diagnostic — three names, two features, zero docs); `RCContentUnavailableView` vs raw system version mixed within the same feature.

## V3.9 Automations readiness

The bones are genuinely good — the two planes an automation needs already exist headless:

- **Event plane**: `EventRoute` registration is UI-free and public; the passive-scan route is already a hand-written rule (trigger → pure tested condition (`LocationEventPolicy.decide`) → debounced action) — the rules-engine seam in miniature. An Automations feature is graph-clean: observe `EventLog`/`Operation`/`Device` tables + register routes; no new module-graph machinery (verified dry-run).
- **Command plane**: `CommandClient.dispatch` is a UI-free dependency — optimistic op staging, `CommandOutcome`, supersede semantics under the one-open-op index, no auto-retry. Effects are observable as rows.

Blocking gaps, in order:
1. **Replay immunity (hard blocker)** — S1/S2/S6 mean `.stream` cannot be trusted as "happening now"; an automation would re-fire on every reconnect replay. Fix the pipeline ordering *and* give the trigger path an event-time freshness guard.
2. **Hot-path isolation** — `EventRouter.dispatch` awaits routes serially; a slow rule (condition read + POST + confirm) blocks all ingestion. Automations need their own executor off the dispatch path (B2's fix generalizes).
3. **Budget-aware dispatch** — nothing consults the *actions* bucket before POSTing, and there's no per-device pending-command guard beyond supersede. The read-side `PollCoordinator` is the template for a command governor.
4. **Loop protection** — an automation's own command echoes back as events with no server correlation id; suppress triggers keyed off the optimistic op for N seconds after own-dispatch.
5. **Audit trail** — a `RuleFiring` row (trigger event id → resulting op id), browsable in the existing Event Log window, makes automations debuggable with zero new UI machinery.

The staleness model (V3.5) is also load-bearing here: automations will multiply event traffic, and mark-mostly ingestion is what keeps that from multiplying reads.

## V3.10 Prioritized punch list

**P0 — correctness (do first, small diffs):** — **all six done 2026-07-20** (commits `e85c3f8`…`2fd14cd`), each subagent-reviewed pre-commit; adversarial review surfaced and fixed several second-order holes (catch-up-failure replay leak, accept-then-close connect storm, restart/stop interleaves, gap-repair zombie).
1. ~~Sequence catch-up before stream connect + monotonic `saveIfNewer` cursor (S1/S2)~~ — done; plus generation stamp against stop-mid-walk resurrect, loud catch-up failure with retry backoff.
2. ~~Fix `giveUpAfter` to measure from the deadline; long-op regression test (S3)~~ — done; window tracked per-op from the first unanswered deadline, reset by a genuinely later server ETA.
3. ~~Fix the inspector-loop leak (B1)~~ — done; `onDisappear` teardown + `scenePhase` gated on `.background` only (`.inactive` is ambiguous on macOS and must not freeze a visible readout).
4. ~~Event-time + kind guard in `completeOpenOperation` (S4)~~ — done; completion events declare the op families they may close; 5s skew tolerance; poll path unconstrained. `travel.arrived`→recall and `scan.completed`→body-scan pairings are assumed-additive, not live-verified.
5. ~~Stream-death recovery + reconnect/wake gap repair (S5/S6/S7)~~ — done; `.staleGap` handoff (seeded staleness clock) + engine restart-through-catch-up covers sleep/wake with no NSWorkspace hook; jittered exponential backoff reset only on a productive connection; auth ladder 5s→10min.
6. ~~Complete logout teardown (T2/S8)~~ — done; 5 tables + cursor cleared (EventLog exempt by documented design), ingestion teardown ordered before wipes, all engine side-tasks under `stop()`'s control. `GameDatabase.migrator()` documents the new-table-needs-a-logout-decision rule.

**P1 — budget (the "responsible API usage" tranche):** — **all four done 2026-07-21**, each subagent-reviewed pre-commit; adversarial review surfaced and fixed several second-order holes (a `.high` refresh joining a pre-command in-flight read, TTL stamps from failed/superseded reads, mid-refresh invalidates dropped by the domain debounce, aged-tier starvation, a future-stamp wedge in payload application).
7. ~~Funnel command confirm-reads through `deviceRefresher` (B4)~~ — done; all three `CommandClient` sites + `updateTags` (now PATCH-only; the feature confirms through the refresher). Hardened: the coordinator refuses to join a read issued before a `.high` request's own time (seq-guarded slot takeover), and stamps its TTL only for non-superseded successful reads.
8. ~~Debounce FTL-mesh + message routes; hot-path isolation (B2/B3)~~ — done via **`DomainFreshness`** (GameServices): per-domain trailing debounce + TTL + `refreshIfStale` + `reset`, clock-injected. Routes now only `invalidate(domain)` — nothing slow runs on `EventRouter.dispatch`. Mid-refresh invalidates earn a follow-up pass; failed refreshes don't stamp freshness; logout `reset()` is generation-guarded.
9. ~~Build the staleness model (V3.5)~~ — done: **`StalenessTracker`** (mark-mostly device route: only live op-closing events read immediately; thin events and all catch-up replay mark), drain tiers = visible (prompt) → op-holding (5s loop) → aged hidden (1/pass, 30s gate, 60s per-mark retry backoff), marks spent centrally by `Reconciler.ingest → markSatisfied` under an issue-time guard, `pruneDevices` forgets marks. Visibility = the inspector's selection (`inspectorVisibilityChanged`, deliberately not `refreshKey`). B6 appear-paths (`Messages`/`LocationEvents` `.task`, star-map pane appear) go through `refreshIfStale`; explicit toolbar refreshes stay direct. Known trade: unselected list rows' *status* can lag until drain/selection (payload application covers location; item 10).
10. ~~Payload application + S9~~ — done with a live-traffic correction: **per-leg arrival events don't exist post-migration** (docs catalogue + full retained-stream walk, 2026-07-21); the envelope's first-class `location` is the device's post-event position (null in transit/stowed). `Reconciler.applyEventFields` folds it in for every device event, guarded at-or-newer by event time with the stamp clamped to the local clock. **S9 remains open** — no `print.*` event exists in retained traffic and the catalogue documents only `print.started`; the route now logs a loud `⚠️ print.completed WITHOUT new_device_code` notice (with actual payload keys) the moment a real completion disproves the assumed key.

**P2 — architecture hygiene:** — **all five done 2026-07-21** (commits `753f822`…`88555da`), each subagent-reviewed pre-commit (reviews LSP-driven per the CLAUDE.md comprehension protocol). Post-change topology: `GameSession` (GameClient+Keychain; API+Dependencies only) sits below `GameServices` (engine + all shared domain clients incl. Stars/Locations + `EventRoute` + the ingestion bundles) below `GameSync` (router + engine); `UniverseModels` and `GameDatabase` are pure model-tier leaves; no non-feature module declares TCA.
11. ~~`UniverseModels` client split; `GameDatabase` below services (M1)~~ — done (`753f822`); StarsClient/LocationsClient → GameServices, UniverseModels pure-models. The clients consumed the internal `Raw*` wire DTOs, so the boundary got a narrow public `LocationDecoding` facade (footprint/location/scannedSystem/scanResultBody) instead of leaking ~20 wire types.
12. ~~`CommandClient` family decomposition + `GameSession` extraction (M2)~~ — done (`1a4960a` spine + 7 `CommandClient+<Family>` files, side-channels out of the dispatcher, tracked path byte-identical; `ebbaf26` GameSession). Account/AccountManager/Blueprints (and via AccountManager, Login) no longer rebuild on engine edits; Messages/Sidebar legitimately keep GameServices (P1's `refreshIfStale`, `replicantsClient` — the finding's "only for gameClient" claim had gone stale). Review caught StarsClient/AccountClient leaning on leaky member visibility; imports now explicit.
13. ~~Export `EventRoute`s from owning modules; shrink the composition root (M3)~~ — done (`d6d4101`); `EventRoute`/`EventMatcher` moved down to GameServices (router stays in GameSync); `MessagesIngestion`/`LocationEventsIngestion`/`LocationsIngestion`/`FTLMeshRefresher.domainRegistration` own their policies; `registerGameSync` is ~50 lines of wiring. The newly-testable glue got tests: roster-provenance gate, debounce burst-collapse + logout cancel, invalidate gates.
14. ~~TCA → swift-dependencies in the non-feature manifests (M4); M5–M7 cleanups~~ — done (`12076aa`): GameServices/GameSync declare `Dependencies`, AccountManager `Dependencies`+`Sharing`; "TCA is for features" is now true by manifest (rule added to the CLAUDE.md module recipe). M7: ReplicantsFeature's stale API/Utils deps dropped; stale `import GameServices` removed from SidebarProgress/SidebarView/MainFeature (LSP-verified GameModels-only usage). M6 had already been done (`59a0e96`). **M5 examined and deliberately kept**: Blueprints/Messages' GameDatabase deps serve live-store previews over a seeded schema; converting to value-driven previews is feature surgery with fidelity loss, and post-M1 GameDatabase is a cheap below-the-service-layer leaf.
15. ~~GameModels test target + SSE-parser tests~~ — done (`88555da`): GameModelsTests decodes GENERATED schemas from raw JSON (the live wire path) for Device/Replicant/Blueprint mapping + tolerance; the SSE wire protocol extracted to `SSELineFramer`/`SSEFieldParser` (byte-for-byte, adversarially diffed) with 12 framing tests (S10 closed). Catch-up tests existed from P0. Remaining mapping fixtures (Account/Achievement/KnownReplicant) are cheap follow-ups in the now-existing target; a latent no-fractional-seconds date-transcoder gap is recorded in the drift backlog.

**P3 — the shining-example tranche:**
16. `app/README.md` map + IMPLEMENTATION_PLAN restoration/citation rewrite + relay DECOMMISSIONED banner + CLAUDE.md pointer fix + StarMap doc consolidation (D1/D2/D4).
17. "relay" → "event stream" comment sweep (D3).
18. `IconSize` tokens + raw-font/spacing sweep; 2 `RCErrorBanner` swaps; adopt-or-delete `RCSectionHeader`; logging-subsystem unification (D5).
19. Codify the presentation dialect + client-home rule + row-file rule in CLAUDE.md; fix the PrintQueue sheet (T1/T4/D6); promote quiet `testValue`s (T5); IssueReporting on the correctness core (T3).

---

# V2 Update — 2026-07-03

_Scope of this pass: re-review against the original prescription across four axes — (a) the sync engine / operation model / plumbing, (b) modularity, (c) framework usage (TCA, SQLiteData/StructuredQueries, Dependencies, Sharing), (d) design-system consistency._

## V2.1 Verdict

The 2026-06-25 document was largely a to-build list. **Almost all of it now exists, and it was implemented faithfully.** `GameSync` is the single relay consumer + type-routed sink registry; the `Operation` table has the prescribed fields and the partial-unique "one open op per device" index; the command template is optimistic-insert → POST → confirm-read → reconcile with 4xx→`rejected` and no auto-retry; the deadline scheduler is a single-timer-to-nearest design that excludes nil-deadline ops and backs off to `unknown`; the poll coordinator does coalescing + TTL + budget deferral; the rate budget is surfaced through `GameClient`; progress is a local-clock `TimelineView`. **Nothing needs re-architecting.**

Three things drifted from the design — one quietly defeats the correctness promise the whole real-time effort rests on — and the design system, pristine at the primitive level, has accumulated component-level duplication. Framework usage is reference-quality.

## V2.2 Sync engine / operations / plumbing — appropriate, one load-bearing bug

Still the right design; it has scaled to the full command surface (travel/mine/print/search/scan/census/directives/lifecycle) with the two-class (self-describing vs enqueued) completion model intact. Extending it is one line per surface: a new relay surface registers a `RelayRoute`; a new command adds an `OperationKind` + `Completion` case.

- **[Correctness-critical] The §5.3 reconciliation guard is guarding the wrong clock.** §5.3 promised last-writer-wins *by event time, not arrival time*. But `Reconciler.ingest` compares `Device.updatedAt` (`Reconciler.swift:46`), and `updatedAt` is always fetch wall-clock (`Device.swift:127`, set at `DevicesClient.swift:51,67`) — never a server modification time or the relay event timestamp. Events never write the device row directly; the device route only triggers a confirm-read (`GameSync.swift:189-190`), which also stamps wall-clock. So the ordering key degrades to "whichever network response resolves last wins," and the central §3.3 hazard is **not actually guarded.** Compounding it: `Device` has no `source`/provenance column, so the optimistic/event/poll precedence rule (§5.3) is absent for entity snapshots (it exists only on `Operation`). Closing this requires flowing the relay event `timestamp` into event-driven device writes and adding an event-time/provenance column — a real design task, since payloads carry no server modified-time. **This is the only finding that can silently corrupt state.**
- **`print_complete` re-walks the whole fleet on the relay hot path** (`GameSync.swift:178-180,198-208`): a full paged `GET /v1/devices` per completion event, bypassing the coordinator, so N concurrent completions = N simultaneous walks — exactly the §5.5 "never re-walk the list to learn about one item" anti-pattern. The new device code is already in the event payload (`new_device_code`); adopt it via one coordinated single-read instead.
- **Tier-2 gap-repair is inert.** `RelayRoute.gapRepair` (`RelayRoute.swift:34`) is defined but never invoked; event catch-up is hardcoded as `backfillAllReplicants` in the engine (fine for events), but the **messages route has no tier-2**, so beyond Redis retention missed messages recover only incidentally. The registry's extension point exists in shape but is dead code.
- Lesser: continuous mining ops (`completesAt == nil`) have no completion backstop if `site_resource_depleted` is lost (`Reconciler.swift:229`) — they linger until an incidental read; `RelayClient` retries a permanently-bad token forever (`RelayClient.swift:149-157`); backfill runs `since: nil` on every start despite the persisted cursor.

## V2.3 Framework usage — exemplary, consistent

TCA + SQLiteData usage is a reference-quality example. Thin reducers upheld **everywhere** (no reducer holds a domain collection); `@FetchAll`-in-state for every primary list; sophisticated correct touches (deriving selection synchronously to avoid inspector-blanking; `@Fetch` + custom `FetchKeyRequest` for the Locations forest; in-place `.load` on search to avoid empty-state flashes). Migrations are clean and centralized; **raw `#sql` appears only for DDL** (incl. the partial unique index), never for reads. `@Dependency` wiring is correct — every client is struct-of-closures with `liveValue` resolving `\.gameClient`, no client built in a feature, `testValue`/`unimplemented` throughout. **Zero Combine, zero legacy `ViewStore`.**

One decision to record, not a bug: the "query lives in state, not view" convention is strict for *primary lists* but *secondary/derived* queries live view-side (`DeviceDetailView.swift:28,599-601`; `SidebarView.swift:22-31`) — a legitimate SQLiteData pattern applied unevenly. Recommendation: **amend the convention** to "primary lists in state; read-only leaf derivations may be view-local" rather than hoist them.

## V2.4 Design system — thorough primitives, duplicated composites

Hard rules upheld: colors all route through `rc*` tokens (only raw colors are legitimate SceneKit scenes + Login canvas art), and **status→color discipline is excellent** — everything goes through `DeviceStatus.tone(for:)`, no invented per-status palettes. The weakness is the **composite layer**: the same components are rebuilt per-feature and re-inline the same magic numbers (30/52 tiles, `0.5` hairlines, `size:15/32` fonts, `opacity 0.12/0.4` pills), which is the source of nearly all the ~18 font/spacing "violations." Promote to `Controls.swift`, by payoff:

1. **`RCGlyphTile`** — duplicated ~8× (`DevicesView.swift:146`, `BlueprintsListView.swift:129`, `PrintQueueListView.swift:158`, `ReplicantsListView.swift:162`, + inlined large variants in the detail views).
2. **`RCSectionHeader` + `RCReadoutCard`** — uppercase section header ~20×; `LocationDetailView.swift:301-337` already extracted it privately (right move, wrong place — hoist it).
3. **`RCErrorBanner`** — byte-identical `errorBanner(_:)` in 5 list views.
4. **`RCPill`** — the `rcAccent.opacity(0.12)` capsule (duplicates `StatusBadge`'s own treatment) rebuilt 4×.
5. **`RCMeterBar`** — accent-over-separator bar reimplemented 5×.
6. **`RCDetailRow`** — key-value row with arbitrary per-view label widths (72/80/88/120).

Missing tokens the inlining reveals: a display font (~28–32) and a micro font (~9–10) beyond the current `rcTitle`/`rcCaption` range, a tile-size token, and a hairline (`0.5`) token. Secondary offender: **LoginFeature ignores `Space.*`** (`spacing: 13`, `padding 24/56/22`) even in non-canvas chrome.

## V2.5 Modularity — still good, one narrow regression + the shared-layer proposal

Graph is **still acyclic**, leaf/shared/feature layering intact, cross-feature *composition* still confined to `MainFeature`. But §2's headline "**no feature-to-feature edges**" is now **false** — three edges, every one caused by a shared *data* symbol homed inside a *feature*:

| Edge | Reason it exists | Fix |
|---|---|---|
| `SidebarFeature → MessagesFeature` | just the `Message` `@Table` (`SidebarView.swift:14,22`) | move `Message` to the shared data layer |
| `SidebarFeature → ReplicantsFeature` | just `ReplicantsClient` (`SidebarFeature.swift:16,43`) | move the client to the shared client layer |
| `Devices/PrintQueue → BlueprintsFeature` | the `Blueprint` `@Table` **and** the `PrintPlanSheet` view (`DeviceDetailView.swift`, `PrintQueueDetailView.swift`) | move `Blueprint` to the shared data layer; extract `PrintPlanSheet` into a shared `PrintingUI` module |

_(Correction, folded in during the fix: the third edge was **not** "just the `Blueprint` table" as first stated — both consumers also embed `PrintPlanSheet`, a BlueprintsFeature view. **Fully resolved 2026-07-03:** `Blueprint` moved to `GameModels` (data coupling gone), and `PrintPlanSheet` — whose view-models (`PrintPreview`/`PrintRequirements`) already live in GameModels and whose only feature tie was the SwiftUI-free `BlueprintPresentation` helper (also moved to GameModels) — was extracted into a new **`PrintingUI`** module that Devices, PrintQueue, and Blueprints all consume. **No feature→feature edges remain** in the graph.)_

None introduces a cycle or couples feature *logic* to feature *logic* — they only reach shared *data*. But fixing them is the natural trigger for resolving the `DependencyClients` god-module question, because both problems have the same root cause: **there is no dedicated home for shared domain data, so it lands wherever it was first needed** — sometimes in `DependencyClients`, sometimes in a feature.

### The shared layer, as I'd draw it

`DependencyClients` today (19 files, ~3.4k LOC) is doing three distinguishable jobs that happen to be co-located because it is the designated cycle-breaker layer:

1. **Session/auth** — `GameClient`, `KeychainClient` (the token lives here and nowhere else).
2. **Domain data** — the `@Table` rows (`Account`, `Replicant`, `KnownReplicant`, `Device`, `BobnetMessage`, `Operation`) + their mapped display value types (`Mining`, `Printing`, `Diversion`, `TravelPlan`, `PrintRequirements`).
3. **The command/refresh engine** — `CommandClient` (34 KB, the hottest-churn file), `Reconciler`, `PollCoordinator`, `DeviceRefreshClient`, `DevicesClient`.

Job 2 (data) is the seam worth cutting **now**; the session-vs-engine cut is gold-plating **today** (see verdict below). Proposed target:

```
Leaves / foundation
  Utils · UI                         (no internal deps)
  API → Utils                        (generated OpenAPI client + governor)

Shared layer
  GameModels → API, Utils            NEW. The persisted domain: every @Table row + its
                                     display value types + schema→domain mapping + each
                                     table's registerMigrations. Depends on nothing but
                                     API (for Components.Schemas) and Utils. No TCA.
                                       ← Account, Replicant, KnownReplicant, Device,
                                         BobnetMessage, Operation, Mining, Printing,
                                         Diversion, TravelPlan, PrintRequirements,
                                         + Message (from MessagesFeature),
                                         + Blueprint (from BlueprintsFeature)

  GameServices → GameModels, API     RENAMED residual of DependencyClients: the authed
                                     clients + the command/reconciliation engine.
                                       ← GameClient, KeychainClient, DevicesClient,
                                         CommandClient, Reconciler, PollCoordinator,
                                         DeviceRefreshClient,
                                         + ReplicantsClient (from ReplicantsFeature)

Orchestration / domain-plus
  UniverseModels  → GameModels, GameServices, API
  AccountManager  → GameModels, GameServices, API
  GameSync        → GameServices, GameModels, API

Features (+ TCA, SQLiteData, UI)
  MessagesFeature   → GameModels, GameServices        (keeps its own MessagesClient)
  BlueprintsFeature → GameModels, GameServices        (keeps its own BlueprintsClient)
  DevicesFeature    → GameModels, GameServices, UniverseModels   (Blueprint via GameModels)
  PrintQueueFeature → GameModels, GameServices, UniverseModels   (Blueprint via GameModels)
  SidebarFeature    → GameModels, GameServices        (Message via GameModels;
                                                       ReplicantsClient via GameServices)
  ...
App target → everything + GameSync
```

Key moves and why:
- **`GameModels` is the missing home.** `Message` and `Blueprint` move here (not into `GameServices`) because they are pure data every layer reads; that single move erases all three feature→feature edges and restores the §2 invariant as a *side effect* of the split, not a separate chore. Features keep their own feature-specific clients (`MessagesClient`, `BlueprintsClient`) — only the tables move.
- **`ReplicantsClient` is the one genuinely-shared client trapped in a feature** (Sidebar drives it). It moves to `GameServices` beside `DevicesClient`; `ReplicantsFeature` then imports it back — a feature→shared edge, which is allowed.
- **The layering stays acyclic and gets sharper:** `GameServices → GameModels → API`. `Reconciler` and `CommandClient` stay co-located in `GameServices`, so the cycle-avoidance rationale documented in `Reconciler.swift:6-10` still holds.
- **The concrete payoff beyond tidiness is incremental build:** today, touching `CommandClient` (highest churn) recompiles everything downstream of `DependencyClients` — i.e. every feature. After the split, read-only features depend on `GameModels` for the data and only pull `GameServices` where they actually dispatch/refresh, so a `CommandClient` edit stops rebuilding the read-only surface. That, plus test isolation, is what makes this more than cosmetic.

Two principles govern the cut (agreed with the design owner, 2026-07-03):

- **`GameModels` is TCA-free.** It carries only `@Table` rows, their mapped value types, and schema→domain mapping — no `@Reducer`, no `@ObservableState`, no TCA dependency at all. **TCA is for features.** Keeping the domain data layer free of it means the models can be read by `GameServices`, `GameSync`, `AccountManager`, and every feature without dragging the app-architecture framework into the foundation, and keeps "data" and "behavior/UI" cleanly separated.
- **The "services layer" is already two modules, not one.** `GameServices` (the authed clients + command/reconciliation engine) and the *existing* `GameSync` (relay ingestion) together form the services tier over `GameModels`. So the mental model of "a domain-models layer + a services layer" is satisfied by this 2-module split — `GameSync` need not move or change; it simply re-points its `DependencyClients` import at `GameServices`/`GameModels`.

### God-module verdict: gold-plating or not?

**Split #1 (extract `GameModels`) — not gold-plating; do it now.** It is *forced anyway* by the feature→feature fix (the shared tables need a home that isn't a feature), it delivers a real incremental-build win, and it gives both resulting modules a one-sentence charter. Low risk (mostly moving files + `public` already in place + Package.swift edits).

**Split #2 (further separate `GameSession` = `GameClient`/`KeychainClient` out of `GameServices`) — gold-plating today.** Those are two small, stable files; isolating them from the engine buys almost nothing until the engine grows enough that "session" and "engine" churn independently. Keep them together in `GameServices`; revisit only if `GameServices` crosses ~20 files or the two start changing for different reasons.

Net (agreed 2026-07-03): a **2-way split now** — `GameModels` + `GameServices`, joining the existing `GameSync` — not the 3-way sketched in the original §3 remedy. The `GameSession` cut is real but premature; revisit per the trigger above.

## V2.6 Prioritized punch list

1. ~~**Fix the reconciliation clock**~~ — **done (2026-07-03).** `Device.updatedAt` is now stamped at request-*issue* time in `DevicesClient.read`/`fetchAll`, so a slow earlier read can't clobber a newer one; no provenance column needed (device rows are written only from authoritative reads). Regression tests added.
2. ~~**Take `print_complete` off the full-fleet walk**~~ — **done (2026-07-03).** The route now reads only the `new_device_code` via one coordinated high-priority read; `refreshFleet` deleted; pruning left to the explicit cold-load. Regression test guards against re-walking.
3. ~~**Extract `GameModels`** and relocate `Message` / `Blueprint` / `ReplicantsClient`~~ — **done (2026-07-03).** New TCA-free `GameModels` module holds all `@Table` rows + value types + `Message` + `Blueprint`; `ReplicantsClient` moved into `DependencyClients`. `Sidebar→Messages` and `Sidebar→Replicants` edges fully removed; `Devices/PrintQueue→Blueprints` reduced to the legitimate `PrintPlanSheet` UI edge (see V2.5 correction). Package + app build; 201/201 tests pass. Rename to `GameServices` still deferred.
4. **Wire per-channel tier-2 `gapRepair`** (esp. messages) + a bounded completion sweep for silently-settled continuous mining ops.
5. **Consolidate the six composite views into `Controls.swift`** + add display/micro/tile/hairline tokens (V2.4). — **done (2026-07-03).** Tokens (`Font.rcDisplay`/`rcMicro`, `Hairline`, `TileSize`) and controls: `RCErrorBanner` (×5, byte-identical), `RCGlyphTile` (Devices/PrintQueue/Blueprints; Replicants keeps its own — `isOwn` selection styling), `RCSectionHeader`/`RCReadoutCard` (hoisted from LocationDetailView), `RCPill` accent/neutral modifier (queueBadge, HOST, ×2 NPC — padding normalized to 2/6), `RCMeterBar` (capacity + resource bars). All six added to the gallery "living spec". **`RCDetailRow` evaluated and intentionally skipped** — the key/value rows differ too much per pane (label font rcCaption vs rcBody, value mono vs body, widths 72/80/88/120, selection) for a shared control to be faithful without becoming over-parameterized. StarMap's pill/meter are genuinely different patterns (rounded-rect button; colored scene readouts) and correctly excluded.
6. Watch items: ~~`RelayClient` bad-token infinite retry~~ (**done** — stops on 401/403); ~~extract `PrintPlanSheet`~~ (**done** — `PrintingUI` module, last feature→feature edge erased); ~~gate backfill on cursor freshness~~ (**done**); ~~rename `DependencyClients` → `GameServices`~~ (**done 2026-07-03** — module dir, Package.swift, ~47 imports, and the pbxproj product reference; package + app build, 204 tests pass); still open: defer the `GameSession` split; document the secondary-query convention.

Items 1 and 2 were genuine divergences from the prescribed architecture; the rest are refinements.

---

## 1. Verdict

**The foundation is unusually well-suited to the core requirement — better than the current feature code makes obvious.** The single most important decision already made — *SQLite as the source of truth, observed via `@FetchAll`/`@FetchOne`, with thin TCA reducers that hold only UI/intent* — is exactly the substrate you want for "faithfully maintaining local state across several screens." Cross-screen consistency is, for any entity that has a table, **already solved**: a write anywhere re-emits to every observing view automatically.

What's missing is not the substrate but the **layer that fills and refreshes it**: there is no action-dispatch path, no notion of an in-flight operation, no polling coordinator, and the one real-time channel (`EventPipeline`) is fully built but unwired. So the app today is a high-quality *read-once, manual-refresh* client. The core requirement — drive long actions, reflect their progress live, poll as little as possible — is **not yet supported**, but almost nothing in the current architecture works against building it. The gaps are additive, not structural.

The biggest conceptual lever is described in §4: because the API's working states carry `started_at`/`completes_at`, **progress is mostly a local clock problem, not a polling problem.** Build around that and the rate-limit pressure largely evaporates.

---

## 2. What the codebase gets right

These are load-bearing strengths; the recommendations later are designed to preserve them.

- **SQLite-as-truth + thin reducers.** `MessagesFeature`, `StarMapFeature`, and the `Replicant` roster all follow the same discipline: reducers hold `selectedID`, `isLoading`, intent flags — never domain collections. Domain data lives in `@Table` rows observed by views (`@FetchAll(Message...)`, `@FetchAll(Star...)`, `@FetchAll var replicants`). This is the correct answer to multi-screen state coherence and it's applied consistently.
- **Clean, acyclic module graph.** `Utils`/`UI` are leaves; `API` is the generated-client layer; `DependencyClients` holds shared clients + shared models (`GameClient`, `KeychainClient`, `Account`, `Replicant`); `AccountManager` orchestrates session; feature modules sit on top with **no feature-to-feature edges**. Cross-feature composition happens only in the app target (`MainFeature`). This is a healthy shape that will scale to many features.
- **One place for the token, one place for the budget.** `GameClient.liveValue` reads the bearer token fresh from Keychain on every `make()` and captures a single process-wide `RateLimitGovernor`. Features never see the token and never build a client; login/logout require zero client reconfiguration. The governor's `min()`-on-remaining and zero-on-429 reconciliation is genuinely careful concurrency code.
- **A disciplined schema→domain boundary.** Every `init(schema:)` coalesces all generated optionals and parses timestamps tolerantly. Malformed payloads degrade rather than crash. Hand-written DTOs (`GameLogEntry`, `GameEvent`) deliberately insulate event fingerprinting from regenerated OpenAPI types.
- **A real-time design that already understands the hard parts.** `EventPipeline` isn't a stub — it correctly models the relay (fast, lossy, at-most-once) vs. the game log (authoritative, re-readable, rate-limited), merges them, dedups via a bounded SHA-256 fingerprint set with epoch-normalized timestamps, and uses `backfill`'s recovered-count as a gap-detection signal. The conceptual work for "best-effort real-time with a reconciling backstop" is done. It's just not connected.
- **Session lifecycle is modeled, not improvised.** `AppState` as a `@Reducer enum` (`loggedOut`/`loggedIn`) makes invalid states unrepresentable; `SessionLifecycleHandler` lets the app wire per-feature cleanup without the manager knowing about feature tables; launch reads the Keychain synchronously so the first frame is correct.

---

## 3. Modularity & extensibility critique

### 3.1 The "add a backend-reading feature" path is well-paved

Adding a feature that reads an endpoint is a known, repeatable recipe: new SPM module depending on `API` + `DependencyClients` + `UI`; a domain `FooClient` that resolves `@Dependency(\.gameClient)` inside each closure and maps schemas to value types; a `@Table` for persistence; a thin reducer; views observing the table; register cleanup via `SessionLifecycleHandler` from the app target. `MessagesFeature` and `StarMapFeature` are clean templates. **This part of extensibility is good.**

### 3.2 The "add an action-dispatching feature" path does not exist yet

Every domain client today is read-or-trivially-mutating (`getV1Messages`, `postV1MessagesRead`, `getV1AccountsMe`). There is **no template for issuing a long action and tracking it**, despite the spec exposing `travel`, `mine`, `scan`, `print`, `teleport`, `transfer`, `transfer`, `contribute`, etc., and the design spec calling for parameterized, confirmable, progress-bearing commands (DESIGN_SPEC lines 100, 105–106). When you build the first one, you will be inventing the pattern — so it's worth deciding the pattern deliberately (§4–5) rather than letting the first command feature improvise it.

### 3.3 Specific friction points and smells

| Issue | Where | Why it matters |
|---|---|---|
| **Rate-limit budget is computed but never surfaced.** | `RateLimitGovernor.snapshot` exists; `GameClient` vends only `make: () -> Client`. | No feature can read remaining budget / reset time. You can't build proactive backoff, a budget HUD, or "defer this refresh because we're low." Throttling is invisible — callers just experience slow `await`s. This is the most direct obstacle to *intelligent* polling reduction. |
| **`EventPipeline` is single-consumer.** | `start()` makes one `AsyncStream` and stores one continuation. | Many features care about events (devices, replicants, messages, bobnet). A single consumer must fan out. There's no broadcast/multicast and no relay base-URL/clientToken plumbed anywhere, which is the proximate reason it's dormant. |
| **No reconciliation/provenance model.** | Survey upsert preserves local-only columns, but nothing guards entity *freshness* across sources. | When optimistic writes, lossy events, and slow polls all write the same row, a slow poll that started before an event can land *after* it and clobber newer data. The governor guards the rate budget with `min()`; there is no equivalent guard for entity state. This is the central correctness hazard of the whole real-time effort. |
| **Hardcoded `defaultReplicantCode = "99380EDF"`.** | `StarMapFeature.swift:20`. | The active replicant already lives in `@Shared(.appStorage)` but isn't consumed. Multi-replicant accounts will break silently. |
| **Eager instantiation of all feature states.** | `MainFeature.State` builds `messages`, `rawAPI`, `starMap` at construction. | Fine now, but as feature count grows this means every feature's `.task`/subscriptions are live regardless of which pane is visible — directly relevant to polling cost. You'll want visibility-aware activation. |
| **Navigation is scalar selection, not routes.** | `category: SidebarItem?`, `detailSelection: String?`. | Works for the current three-pane shape, but deep-linking to "this device's active task" or restoring a drill-in won't compose cleanly. Not urgent. |
| **Content/detail panes are placeholder-driven for most categories.** | `MainFeature` content/detail switches with `sampleItems`. | Confirms only Messages/Stars are real; Devices/Replicants/Blueprints/Print Queue are scaffolding. The action layer has no home yet. |

None of these are architectural dead-ends. They're the predictable edges of a codebase that has built its read path and not yet its write/refresh path.

---

## 4. The core problem, reframed

The prompt frames the challenge as "reduce polling while keeping several screens faithful to long-running server actions, with truth from polling + the EventPipeline." Before choosing an architecture, reframe what "progress" actually requires, because it changes the cost model dramatically.

### 4.1 There are three writers; there must be one reader-of-truth

State about an entity can be produced by:

1. **Optimistic prediction** — you POST `travel`; the dispatch response (and/or your own knowledge) tells you the new `status`, `started_at`, `completes_at`.
2. **Push events** — `EventPipeline` delivers a `UnifiedEvent` ("device X started mining", "travel complete"). Low latency, **lossy**, possibly out of order.
3. **Polling** — `getV1Devices/{code}`, `getV1Replicants/{code}`, etc. Authoritative, **expensive**, rate-limited, and increasingly paged.

The faithful-local-state problem *is* the problem of merging these three into one local snapshot per entity, deterministically. The good news: you already have the merge target — **the SQLite row.** What's missing is the merge *rule* (provenance + ordering) and the two upstream feeds (events, scheduled polls). See §3.3 "reconciliation."

### 4.2 The decisive observation: completion is time-bounded and self-describing

The API's working states carry `started_at` and `completes_at` (and a `progress` field; `status` strings like `"mining (iron)"`). The design spec confirms travel/tasks render "**live progress + time remaining + ETA**" (lines 100, 106).

That means **the progress bar is a local clock, not a network call.** Once you have fetched an entity in a working state *once*, you know its entire trajectory: `fraction = (now - started_at) / (completes_at - started_at)`. A `TimelineView` or a single timer interpolates it at 60fps with **zero** requests. You only need the network to learn things you cannot predict:

- The **result** of the action (what was mined, the new location, new inventory) — knowable only at/after `completes_at`.
- **Unexpected divergence** — the server cancelled/failed/extended the task, or another actor changed the entity.

So the polling budget for "watch one action to completion" collapses from *O(duration / interval)* to **~1–2 reads per action**: the dispatch confirmation, and one read at the deadline. Everything between is interpolated locally. This is the single largest lever you have, and the architecture should be built to exploit it rather than to poll efficiently.

**But not every action is self-describing — there are two dispatch classes, and they need different handling:**

| Class | Example | Dispatch response | Progress strategy |
|---|---|---|---|
| **Self-describing** | `POST /v1/devices/{code}/travel` returns the same body as `GET /v1/devices/{code}`, including `status`/`started_at`/`completes_at`. | You have the full trajectory immediately. | Interpolate locally from `completes_at`; **zero** reads until one deadline confirmation. The dispatch confirmation is free (it's in the POST response). |
| **Enqueued / opaque** | `POST /v1/replicants/{code}/print` returns only print-queue info and `status: "enqueued"` — **no `completes_at`.** | You know it was accepted, nothing about when it finishes. | You **cannot** interpolate. The cheap completion signal is the **relay event** (e.g. `print_complete`, which even carries the result — see §4.4); polling is the fallback, and without a known deadline that fallback is an open-ended "poll until done," which is exactly the expensive shape we want to avoid. |

The consequence is that **the relay is not an optimization for enqueued actions — it's the primary completion channel.** Self-describing actions degrade gracefully without the relay (deadline timer suffices); enqueued actions degrade *badly* without it (indeterminate polling). This raises the priority of wiring the relay (§6).

**The unifying move: one authoritative single-device read immediately after every successful command.** This is the right default, and it dissolves most of the per-class branching above. Whatever the dispatch response shape, a single `GET /v1/devices/{code}` right after a 2xx gives you the authoritative post-command snapshot — `status`, `started_at`, `completes_at` — and becomes the canonical reconciliation point (written as `source = .poll`, §5.3). Why it's the right spend:

- **It's one read, on a user-initiated, infrequent event**, against the 120/min *reads* bucket — trivially affordable, and the single most informative read you can make because you know *exactly* when state changed. It is *not* a polling loop; it's the "dispatch confirmation" of §4.3, made explicit.
- **It collapses the two classes at dispatch.** You no longer branch travel-vs-print to learn the new state: always read after. (Optimization: when the response is *already* the full device body — the self-describing case — use it directly and **skip** the redundant read. So the rule is "reconcile from the fullest authoritative payload you have; fetch one if the response wasn't it.")
- **It resolves fail-vs-cancel/replace for free (§5.2).** You don't infer the outcome from the response — you read the resulting device state: rejected → the old task is still there; replaced → the new one is. Truth, not inference.
- **The one thing it does *not* give you is enqueued *completion*.** A confirm-read right after `print` shows `enqueued`/`active`, not a finish time — printing hasn't completed yet. So this read handles *acceptance + immediate new state*; **completion of enqueued actions still comes from the relay event** (or the deadline poll once a `completes_at` is known). Don't let the post-command read lull you into thinking the relay is now optional for enqueued work — it isn't.

### 4.3 Reclassify polling into tiers

Not all reads are equal. Separating them lets you spend the rate budget where it matters:

| Tier | Trigger | Frequency | Example |
|---|---|---|---|
| **Deadline confirmation** | an entity's `completes_at` passes | once per action | travel/mine completion → read result + next state |
| **Event-driven invalidation** | a `UnifiedEvent` names an entity | once per event, coalesced | "device changed" → mark row stale → one read |
| **Foreground freshness** | a screen showing entity X is visible and its row is older than TTL | TTL-bounded, visible-only | the open device detail pane |
| **Cold/bulk survey** | first run / explicit user refresh | rare, paged walk | the 5757-star galaxy survey |

The expensive, paged tier (bulk survey) should be driven **only** by first-run and explicit user action — never by progress tracking. Progress tracking lives in the top two tiers, which are cheap and bounded.

### 4.4 Events are invalidation signals — but today's payloads are richer than "something changed"

The original stance was "treat events as *this entity is now stale*, not as truth." That still holds as the **safety default**, but the actual relay payloads shipping today are more useful than bare pings. Two real examples:

```json
{ "type":"event", "event_type":"device_cruise_arrived", "device_code":"965AC2C3",
  "device_type":"heaven_vessel", "category":"travel", "title":"Arrived at planet ATIANFU-1",
  "replicant_code":"99380EDF",
  "payload": { "location":"ATIANFU-1", "from_location":"ATIANFU-BELT-1", "recalling":false },
  "timestamp":"2026-06-25T10:41:22-05:00" }

{ "type":"event", "event_type":"print_complete", "device_code":"965AC2C3",
  "device_type":"heaven_vessel", "category":"printing", "title":"Completed printing ftl_beacon",
  "replicant_code":"99380EDF",
  "payload": { "device_type":"ftl_beacon", "new_device_code":"1F63E913", "location":"ATIANFU-BELT-1" },
  "timestamp":"2026-06-25T10:56:31-05:00" }
```

These are **transition/completion events** carrying actionable outcome data: the arrival event gives the new `location`; the print-completion event gives `new_device_code` — *the very result the print dispatch response withheld.* So in practice events are doing two jobs:

- **Completing enqueued actions** (the print case from §4.2): the `print_complete` event is the only cheap way to learn the action finished *and* what it produced. For this class, the event is closer to truth than to a hint.
- **Confirming/short-circuiting self-describing actions**: a `device_cruise_arrived` lets you flip the operation to `completed` and update `location` **without** the deadline confirmation read — the deadline timer becomes a backstop for when the event is lost, not the primary path.

Recommended policy, accounting for both:

- **When the payload is complete and self-consistent for the field it touches** (location, new device code, a status transition), apply it directly under the reconciliation guard (§5.3). This is the common case and it costs zero reads.
- **When the payload is thin or ambiguous** (and the design owner notes relay richness is still evolving — payload shapes may change with other breaking API work, so don't over-fit to today's keys), fall back to *invalidate + coalesced confirmation read.*
- A new event type you don't recognize → always the conservative path (invalidate, optionally confirm).

The `backfill` path remains the gap-repair backstop; the deadline timer is the backstop-of-the-backstop for self-describing actions. Three independent mechanisms converge on the same row, and because writes are idempotent upserts, convergence is safe as long as ordering is guarded (§5.3).

> **Forward-compat note.** Because the team is actively enriching relay payloads and warns of accompanying breaking changes, keep the event→row mapping in *one* place (the `GameSync` service, §5.1) and keyed by `event_type`, so adapting to a payload change is a localized edit, not a sweep across features. Don't let feature code parse raw event payloads.

### 4.5 One connection, three logical streams

The relay (`https://replicant.pennig.name/api/stream`, single account-wide SSE) carries **three different kinds of payload**, already distinguished by `UnifiedEvent.type`:

| `type` | Meaning | Destination today | Authoritative re-read source | Durability tier |
|---|---|---|---|---|
| `"event"` | Game-state events (device/replicant transitions, action completions) | entity rows + `Operation` table (§5.2) | `EventPipeline.backfill` (game log, per-replicant) | **Recoverable** — game log is authoritative & re-readable |
| `"message"` | Account messages | the existing `Message` SQLite table (Messages feature) | `getV1Messages(latest:)` (existing REST path) | **Recoverable** — REST inbox is authoritative |
| `"bobnet"` | Bobnet chat | a future Bobnet store (feature unimplemented; only a sidebar reference exists) | **none** — Bobnet exists *only* as relay webhooks in Redis; no API endpoint | **Best-effort, but generous in practice** — recoverable to the relay's standup (~weeks of history today, low-traffic channel) |

Four observations this forces into the design:

1. **`GameSync` is a router, not just a reconciler.** Its first job on each `UnifiedEvent` is to switch on `type` and dispatch to the correct sink. The three sinks have *different* write models (game events → reconciled entity/operation upserts; messages → message-table upsert that must coexist with the existing REST fetch; bobnet → append-only chat log), so don't try to force one write path.

2. **The relay makes Messages live "for free," which validates the whole design.** Messages today is REST-only, head-page, manual-refresh. Routing `type:"message"` events into the same `Message` table the feature already observes via `@FetchAll` means the inbox becomes real-time **with no change to the Messages feature** — the view just re-emits when `GameSync` inserts a row. This is the strongest possible evidence for the "ingestion service writes to feature tables; features stay pure observers" architecture (A1 + §5.3): the *same* mechanism that tracks a 1000-device fleet also delivers chat, with zero per-feature event plumbing. It also retires Messages polling.

3. **Gap-repair is two-tier, and the tiers differ per channel.** The relay is Redis-backed and the `RelayClient` already replays via `Last-Event-ID`, with the cursor persisted by `RelayCursorStore`. So:
   - **Tier 1 — relay cursor replay (common case, all three channels at once).** On a normal reconnect within Redis retention, replaying from the persisted cursor recovers *every* missed entry across events, messages, **and** bobnet in one stream. This is the primary recovery path and it's already built.
   - **Tier 2 — authoritative REST catch-up (cold start / outage beyond retention / cursor gap).** Only `event` and `message` have a tier 2 (`backfill` and `getV1Messages`). **Bobnet has no tier 2** — its sole source is the relay's Redis log. In practice that's not a real limitation today: retention reaches back to the relay's standup (weeks) and the channel is low-traffic, so tier-1 cursor replay recovers essentially all of it. The architectural caveat is just that this guarantee is *operational* (Redis retention policy), not *contractual* (no authoritative endpoint). So: persist received chat locally so it survives restarts, and treat a deep-enough gap as best-effort rather than guaranteed — but don't over-engineer for loss that the current retention makes unlikely.

4. **The relay is effectively single-tenant.** It's your own server holding webhooks for one account's data, read with a single static token (below). "Account-wide" really means "the one account whose webhooks land in this Redis." That's fine for a personal app, but it means the relay model — and the in-code token — would need rework before any multi-account/multi-user distribution.

Architecturally, model the three sinks as a small **registry of relay routes** — the same shape as the existing `SessionLifecycleHandler` registry — where each route declares the `type`(s) it consumes, how to apply a live event, and which (if any) tier-2 catch-up it owns. New real-time surfaces (a future "signals" channel, etc.) register a route instead of touching `GameSync`'s core. This keeps the router open for extension and closed for modification.

---

## 5. Candidate architectures for the core problem

Four building blocks, presented as options where there's a real choice. They compose; the recommended stack is A1 + B2 + C(scheduler) + D(provenance).

### 5.1 Block A — Where does ingestion live?

**A0 (status quo): each feature owns its refresh.** Every feature has its own `.task` that fetches and writes its table. *Rejected for the action era:* event fan-out, dedup, and rate coordination would be re-implemented per feature, and nothing coordinates the shared budget. Fine for cold reads; wrong for live state.

**A1 (recommended): a single app-level Sync/Ingestion + routing service, started at login.** One long-lived dependency (call it `GameSync`) owns the `EventPipeline`, consumes the single account-wide relay stream, **routes each `UnifiedEvent` to the right sink by `type`** (game events / messages / bobnet — §4.5), runs per-channel gap-repair on launch/wake/relay-error, and writes/invalidates the relevant SQLite rows. Features stay pure observers (`@FetchAll`) and never subscribe to the stream themselves. This solves single-consumer fan-out (the service is the one consumer; SQLite is the broadcast bus), centralizes reconciliation, and gives one place to honor the rate budget.

The relay/backfill topology fits this service cleanly given the confirmed answers:

- **The relay is account-wide and reachable today (`https://replicant.pennig.name/api/stream`) → exactly one SSE stream for the whole app.** This is the ideal shape for A1: a single `RelayClient.stream(...)` consumer covers every replicant, all ~hundreds-to-1000+ devices, **plus account messages and Bobnet chat**, fanned out via SQLite. No per-replicant stream multiplexing needed. The current `EventPipeline` single-consumer limitation is a non-issue once *the service* is that consumer.
- **The stream is multiplexed (§4.5) → `GameSync` switches on `UnifiedEvent.type` first**, then applies the channel-specific write. Model the channels as a small **relay-route registry** (mirroring the `SessionLifecycleHandler` pattern) so each sink owns its apply + gap-repair logic and new channels register rather than edit the core.
- **Game-event backfill is per-replicant → loop over the (<10) replicants on launch/wake/relay-error.** With fewer than 10 replicants this is cheap (≤10 cursor-walks, each newest-first with the 60s overlap already implemented). Persist a cursor per replicant. (Note: `/v1/accounts/events` is *not* a shortcut here — it's the game's "location events" surface, i.e. quests/location-bound occurrences, unrelated to device/replicant event logs. The per-replicant log remains the only tier-2 source for game state.)
- **Gap-repair is two-tier (§4.5).** Tier 1 = relay cursor replay (already built via `RelayCursorStore` + `Last-Event-ID`) recovers all three channels on a normal reconnect. Tier 2 = authoritative REST catch-up for cold start / long outage — `backfill` for events, `getV1Messages(latest:)` for messages, and **nothing for bobnet** (relay-only; loss beyond Redis retention is accepted). Persist bobnet chat locally so history survives restarts.
- Wire it through `SessionLifecycleHandler.onLogin`/`onLogout` exactly like the existing table-cleanup handlers, so it starts/stops with the session and the app composition root stays the orchestrator.
- Plumb the relay base URL (`https://replicant.pennig.name/api/stream`) + the **static relay Bearer token** into the `RelayClient` built inside this service. The token is *separate* from the game bearer token (which lives in Keychain) and can be a compile-time constant for now — but treat it as a known shrinkable risk (it's a shared secret extractable from the binary; move to Keychain/remote config before any wider distribution, and rotate-ability lives server-side). It's account-scoped by virtue of being your single-tenant relay (§4.5, obs. 4).
- It writes to the same tables features read — no new read path, no duplicated state. **This is what makes Messages real-time with no change to the Messages feature** (§4.5, observation 2).
- **It is the single place that maps `event_type` → row mutation** (per the forward-compat note in §4.4), so evolving relay payloads stay a localized change.

### 5.2 Block B — Modeling the long-running action

**B1: fold action state into the entity row.** Add `status`, `startedAt`, `completesAt`, `progress` columns to `Device`/`Replicant` tables; the UI reads them and interpolates. Simplest; good enough if an entity has at most one action at a time.

**The settled invariant: one device → at most one active operation, ever.** (Working assumption per the design owner: issuing a command to a busy device either *fails* or *cancels/replaces* the prior one — never runs two at once. To be revisited only if an exception surfaces.) This is a strong simplifier, and it changes the B1-vs-B2 decision: with concurrency bounded at one, **B1 (fold a single active-action onto the device row) is no longer wrong** — the earlier argument for B2 rested on concurrency *uncertainty*, which is now resolved. So choose deliberately on the remaining grounds.

**B2 (still recommended) — a first-class `Operation` table, chosen now for observability, not concurrency.** Even at one active op per device, a separate table earns its keep for: **history** (completed/failed ops persist as an audit trail; the device row only holds the *current* one), **relaunch survival** of in-flight actions, a **global "Operations" / activity view** across all devices, and a clean `enqueued`/`active` lifecycle. If you'd rather defer that, B1 is a legitimate v1 — a nullable `currentOperation` on the device row — and you can graft the table on later. The rest of this section assumes B2; everything maps onto B1 by reading "the device's one active op" wherever it says "the open operation." Model the in-flight action as its own record:

```
@Table struct Operation {
    let id: String              // client-local UUID — there is NO server correlation id (see correlation note)
    var entityCode: String      // device_code / replicant_code
    var kind: OperationKind      // travel / mine / scan / print / teleport / transfer
    var status: OperationStatus  // enqueued / active / completed / failed / rejected / superseded / unknown
                                  // at most ONE non-terminal (enqueued|active) row per entityCode — enforce with a partial unique index
    var startedAt: Date?
    var completesAt: Date?       // nil for enqueued/indeterminate actions; drives the scheduler + progress bar when known
    var lastConfirmedAt: Date?   // freshness/provenance
    var source: Provenance       // optimistic / event / poll
    var detail: JSON?            // params + result (e.g. print's new_device_code from print_complete)
}
```

Three refinements forced by the answers above:

- **`completesAt` must be nullable, and `status` must distinguish `enqueued` (accepted, no known deadline) from `active` (running, deadline known).** This is the §4.2 two-class split made concrete: a `travel` insert lands as `active` with a `completesAt`; a `print` insert lands as `enqueued` with `completesAt = nil`, later promoted to `completed` by the `print_complete` event (which also fills `detail.new_device_code`). The scheduler (§5.4) treats the two classes differently.
- **Dispatching onto a busy device has two outcomes, both clean transitions under the invariant.** Because a device runs at most one action, issuing a new command when one is already open resolves one of two ways:
  - **Rejected** → the existing op is untouched; the optimistic insert for the *new* command rolls back / lands as `rejected` (the optimistic-with-rollback shape proven by the login flow: Keychain save → verify → delete-on-failure).
  - **Cancel/replace** → the prior op is terminated as `superseded` and the new one becomes the single open op. One transition, no ambiguity about which is current.
  Decide client-side which you expect per command (the design spec already wants destructive/parameterized commands gated behind confirm — a natural place to ask "replace the current task?").
- **Correlation is now deterministic, because the invariant gives you a key.** Dispatch responses still contain no server operation/job id, so you can't correlate by id — but with **at most one open operation per `entityCode`**, you don't need one: any event or poll for device X maps unambiguously to *the* open op on X. The earlier `(entityCode, kind)` + temporal-proximity heuristic collapses to a plain lookup by `entityCode`; `kind` becomes a sanity check, not a disambiguator. `Operation.id` stays a client-local UUID for joins/history only. Two consequences remain:
  - **No automatic retry of action POSTs.** Without server-side idempotency, a blind retry risks firing the real game action twice (or needlessly cancel-replacing). Let the rate middleware's existing 429 handling (which retries *within* a single logical call) be the only retry; never re-issue an action POST at the feature level on an ambiguous failure — surface it instead.
  - A late or duplicate event simply re-promotes an already-terminal operation, which the reconciliation guard (§5.3) makes a no-op.

Why B2 is worth the extra table:

- **It separates "what's happening" from "the entity snapshot."** A device row says what the device *is*; an `Operation` says what it's *doing* and *until when*. The Active-Replicant picker, the device detail "active-task card," the Event Log, and a future global "Operations" view all observe the same rows — multi-screen faithfulness falls out of `@FetchAll(Operation.where(...))` for free.
- **It's the natural home for optimistic dispatch + confirm.** Insert optimistically on POST; the **immediate post-command device read** (§4.2) reconciles it to authoritative truth one round-trip later (→ `active`/`enqueued`, or `rejected`/`superseded`); events and deadline polls later flip it to `completed`/`failed`. The login flow (Keychain save → verify → delete-on-failure) is your existing proof that optimistic-with-rollback works here; B2 generalizes it, with the confirm-read standing in for the verify step.
- **It's the queue the deadline scheduler watches.** "Give me all operations whose `completesAt < now` and `status == confirmed`" is one query and becomes the entire poll-scheduling input (§5.4).
- **It survives relaunch.** Because it's persisted, an in-flight action observed before quit is still tracked (and still drawn, since `completesAt` is absolute) after relaunch — the timer just resumes.

### 5.3 Block C — The reconciliation rule (the correctness core)

With three writers, define a deterministic merge so a slow poll can't clobber a newer event:

- **Tag every write with a logical timestamp and a provenance.** Prefer the server's own `started_at`/`updated_at`/event timestamp over wall-clock receipt time. Last-writer-wins **by event time, not arrival time.**
- **Guard the upsert:** only overwrite a field if the incoming record's authoritative timestamp is `>=` the stored one (mirror the survey's existing "preserve local-only columns" discipline, extended to "don't regress on staler data"). The governor already does this for the rate budget with `min()`; do the analogous thing for entity state.
- **Optimistic writes are provisional:** mark `source = .optimistic` and let any `.event`/`.poll` write supersede them, but never let an older `.poll` supersede a newer `.event`. If a deadline poll and a completion event race, the one with the later authoritative timestamp wins.
- **Correlation by entity, not idempotency keys (§5.2):** there's no server id to dedupe on, but the one-active-op-per-device invariant means any event/poll for device X maps to *the* open op on X. Converge by that lookup and guard against double-dispatch client-side. The reconciliation guard makes a late/duplicate event re-promoting a terminal operation a no-op.

This block is small in code and large in consequence; it's the thing most likely to bite if left implicit.

### 5.4 Block D — The poll coordinator / budget-aware scheduler

The governor throttles but does not **prioritize, coalesce, or expose budget.** Add a thin coordinator (inside the `GameSync` service) that turns "things that might be stale" into "the minimum set of reads, ordered by value":

- **Coalesce**: collapse N pending reads for the same resource into one in-flight request (dedupe by URL/key). Critical when a burst of events all name the same device.
- **TTL per resource type**: don't re-read a row fresher than its TTL even if asked. Foreground-visible entities get a short TTL; everything else effectively ∞ until an event or deadline invalidates it.
- **Deadline queue**: a single timer set to the nearest `Operation.completesAt`; on fire, confirm just those operations. One timer, not one-per-action. **Operations with `completesAt == nil` (enqueued/indeterminate) are *not* in this queue** — they have no deadline to wait for. Their completion comes from the relay event; their only polling fallback is a *bounded, backoff* confirmation (e.g. a few attempts at widening intervals, then give up and mark `unknown` rather than poll forever). Make "enqueued with relay down" a deliberately degraded mode, not an infinite poll loop.
- **Priority + budget awareness**: surface `RateLimitGovernor.snapshot` through `GameClient` (today it's vended nowhere) so the coordinator can defer low-value reads when `remaining` is near the `reserve` floor, and so the UI can show a budget HUD (the `Snapshot` type was literally built for this). Spend the budget on visible + just-completed entities first.
- **Visibility gating**: only the foreground-freshness tier runs for panes that are actually on screen — pairs naturally with making feature activation visibility-aware (§3.3). **At hundreds-to-1000+ devices this is load-bearing, not a nicety** (see §5.5).

Net effect: progress is interpolated locally (zero reads), events trigger coalesced single-resource reads, deadlines trigger one confirmation read each, the **post-command read** (§4.2) spends exactly one read per user action at the moment of maximum information, and the paged bulk survey is never on the hot path. That is the polling reduction, and it's driven by structure rather than by tuning an interval.

### 5.5 What about the paged-growth concern specifically?

This is now the sharpest constraint, because a heavy account has **hundreds-to-1000+ devices** (and <10 replicants). The device fleet is a large, paged collection that changes constantly as actions complete. The naive approach — periodically re-walking `/v1/devices` to keep the fleet fresh — is precisely the rate-limit catastrophe to avoid: one full fleet refresh could be 10–20+ paged reads, and doing it on a timer would dominate the entire budget.

Three defenses, all enabled by the above:

1. **The account-wide relay is the fleet's freshness mechanism — not polling.** With 1000+ devices, you fundamentally *cannot* poll your way to a fresh fleet. The relay's whole value here is that it tells you **which** of the 1000 devices changed, so you touch only those rows. This is the strongest argument for wiring the relay early (§6): at this scale it's not an optimization, it's the only viable design. A device with no recent event is assumed unchanged.
2. **Never re-walk the list to learn about a change to one item.** Events + single-resource reads (`GET /v1/devices/{code}`) keep individual rows fresh; the full paged walk runs only on first-run/explicit-refresh. Both the 5757-star survey and the device-fleet walk should be rare, user-initiated cold loads — never a refresh strategy.
3. **If/when list endpoints support it, prefer delta/`since`-cursor reads** (the messages endpoint already has `latest`/`cursor`; `backfill` already uses newest-first + cursor). Treat full pagination as a cold-start cost amortized into SQLite (which handles 1000+ rows trivially), and keep it warm with relay-driven single-row updates.

The relevant scale check the other direction: in-flight `Operation`s are few (bounded by ~replicants × concurrent-actions, realistically a handful), so the deadline scheduler and progress interpolation stay cheap regardless of fleet size. The cost pressure is entirely in *fleet freshness*, and §defense-1 is the answer to it.

---

## 6. Prioritized recommendations

Ordered by leverage-to-effort. Each is additive and preserves the current strengths. The answers shifted two things up: **wiring the relay is now co-critical** (it's the only scalable fleet-freshness mechanism at 1000+ devices *and* the sole completion channel for enqueued actions), and **visibility gating is load-bearing**, not a "someday."

1. **Adopt the reconciliation rule (Block C) before building any live feature.** Decide provenance + timestamp-guarded upserts now; retrofitting ordering guarantees after three writers exist is painful. Small code, central correctness. With rich-ish relay payloads applied directly to rows (§4.4), this guard is what stops a late poll from regressing an event.
2. **Stand up the `GameSync` ingestion + routing service (A1) and wire `EventPipeline`.** Point the `RelayClient` at `https://replicant.pennig.name/api/stream` (confirmed reachable), make the service the single account-wide stream consumer, **route by `UnifiedEvent.type` into three sinks** (game events → entity/operation rows; messages → the existing `Message` table; bobnet → future store) via a relay-route registry (§4.5), run per-channel gap-repair on launch/wake/relay-error, and centralize `event_type` → row mapping. *Promoted from #4 to #2:* at 1000+ devices this is the only viable freshness design (§5.5) and the only cheap completion path for enqueued actions like print (§4.2). **Quick win inside this work:** routing `type:"message"` events into the `Message` table makes the inbox real-time and retires Messages polling with *zero* change to the Messages feature — a cheap, visible proof the architecture works before tackling the device fleet.
3. **Surface the rate-limit budget through `GameClient`.** Add a `snapshot()`/budget accessor (or vend the governor). Cheap, unblocks proactive backoff, the budget HUD, and informed scheduling. Without this, "reduce polling intelligently" is flying blind.
4. **Introduce the `Operation` table (B2) and an action-dispatch client template.** This is the missing extensibility recipe (§3.2). Build it once — start with `travel` (self-describing: dispatch returns full state, easiest end-to-end), then do `print` second to exercise the enqueued/event-completed path and the `rejected`-on-400 rollback. Every later command follows one of those two shapes. The template's spine is **POST → (use full response, or one post-command device read) → reconcile** (§4.2): optimistic insert, single confirm-read, correlate by `entityCode` (§5.2 — there's no server id, but the one-op-per-device invariant makes it deterministic), no-auto-retry. This read is also what makes the `enqueued`-vs-`active` and fail-vs-replace outcomes self-evident rather than inferred.
5. **Build the deadline scheduler + poll coordinator (Block D)** on top of `Operation.completesAt` (skipping nil-deadline enqueued ops), the budget snapshot, and request coalescing. This is where the polling reduction actually lands.
6. **Drive progress UI from `completes_at` via `TimelineView`/timer**, not from polling — for self-describing actions. For enqueued actions, show an indeterminate/"working" affordance until the completion event arrives. Make this the house pattern so no feature is tempted to poll for animation.
7. **Make feature/entity activation visibility-aware.** *Promoted from #8:* with hundreds-to-1000+ devices, off-screen panes holding live subscriptions or foreground-tier polls is a real budget drain. Only the visible device/detail panes should run the foreground-freshness tier; everything else relies on the relay. Pairs with revisiting eager `MainFeature.State` instantiation.
8. **Consume the active replicant from `@Shared(.appStorage)`** and delete the hardcoded `defaultReplicantCode`. Required before multi-replicant (you have <10, so this matters in practice).

Lower priority / watch items: scalar-selection navigation will eventually want route modeling for deep-linking (e.g. deep-link to a device's active task).

---

## 7. Resolved constraints (answers folded in)

The open questions from the first draft have been answered. Recording them here with their architectural consequences, since they're the load-bearing assumptions behind §4–6.

| Question | Answer | Consequence |
|---|---|---|
| **Relay payload richness?** | Thin-ish today but already carry actionable outcome data (`device_cruise_arrived` → new location; `print_complete` → `new_device_code`). Enrichment is in progress, with likely breaking API changes alongside. | Events can update rows directly under the reconciliation guard, not just invalidate (§4.4). But keep `event_type`→row mapping centralized in `GameSync` and don't over-fit to today's payload keys — breaking changes are expected. |
| **Concurrent operations per entity?** | Technically possible, practically rare; server enforces *some* mutual exclusion (`travel` while printing → 400), generality unknown. | Use the `Operation` table (B2), which assumes nothing about concurrency, over folding state into the entity row. Add a `rejected` terminal state for synchronous 400s with optimistic rollback (§5.2). |
| **Does dispatch return entity state with `started_at`/`completes_at`?** | **Depends on the action.** `travel` returns the full device body (with timestamps); `print` returns only queue info + `status:"enqueued"` (no deadline). | Two action classes (§4.2). Self-describing → interpolate locally + one deadline confirm. Enqueued → no interpolation; completion comes from the relay event, polling fallback must be bounded (§5.4). |
| **Action duration distribution?** | Not pinned down numerically. | The two-class design already spans both ends: sub-second/opaque actions get a single confirmation or an event; multi-minute self-describing actions get full local interpolation. TTLs (Block D) stay adaptive rather than tuned to one duration. |
| **Devices/replicants per heavy account?** | **<10 replicants, hundreds-to-1000+ devices.** | Fleet freshness *cannot* be polled — the account-wide relay is the mechanism (§5.5). Visibility gating + coalescing become load-bearing (rec #7). Per-replicant backfill stays cheap (≤10 walks). SQLite handles 1000+ rows fine. |
| **Relay per-replicant or account-wide?** | **Relay is account-wide; backfill is per-replicant.** | One SSE stream for the whole app (ideal for the single-consumer `GameSync`, §5.1). Backfill loops the <10 replicants on launch/wake; consider `/v1/accounts/events` as a single account-level backfill to collapse that loop. |
| **Is the relay reachable, and what does it carry?** | **Reachable now at `https://replicant.pennig.name/api/stream`. Multiplexes three streams: game events, account messages, Bobnet chat** (distinguished by `UnifiedEvent.type`). | `GameSync` is a router with three sinks + two-tier gap-repair (§4.5). Routing `message` events makes the inbox live and retires Messages polling for free; `bobnet` events feed the (unimplemented) Bobnet feature. rec #2 is unblocked. |
| **Relay authentication?** | **Separate static Bearer token** (distinct from the game token in Keychain); acceptable in-code for now. | `GameSync` plumbs a compile-time relay token into `RelayClient`. Known shrinkable risk: shared secret in the binary — move to Keychain/remote config before wider distribution (§5.1). |
| **Bobnet history/catch-up source?** | **None exists** (no API endpoint), **but retention is generous**: the relay's Redis log reaches back to standup (~weeks) and the channel is low-traffic, so tier-1 cursor replay recovers essentially all of it. | Bobnet is *contractually* best-effort but *operationally* robust today. Persist locally; treat deep gaps as best-effort; don't over-engineer for loss the current retention makes unlikely (§4.5, tier 2). |
| **Dispatch idempotency / correlation id?** | **No unified identifier** in dispatch responses (body or headers) to correlate an action across its lifecycle. | Doesn't matter, given the invariant below: correlate by `entityCode` (the one open op), not by id; no auto-retry of action POSTs (§5.2). |
| **Concurrent actions per device?** | **None** (working assumption): a device runs ≤1 action; a new command on a busy device either fails or cancels/replaces the prior. | Correlation becomes a deterministic lookup by `entityCode`; enforce one non-terminal op per device with a partial unique index; add a `superseded` transition for cancel/replace (§5.2). Revisit only if an exception surfaces. |
| **`/v1/accounts/events` as a backfill shortcut?** | **No** — it's the game's *location events* (quests / location-bound occurrences), unrelated to device/replicant logs. | Per-replicant log stays the only tier-2 game-state source; the (<10)-replicant backfill loop stands. (Location events may later warrant their *own* feature, but not as a sync source.) |

### Remaining things worth confirming before/while building

- **Exact dispatch-response shape per action kind.** We've confirmed `travel` returns full device state and `print` returns `enqueued`-only; before building each command, check which of the two classes (§4.2) it falls into, since that decides interpolate-vs-event-completion. This is per-endpoint homework, not an architectural unknown.
- **Per-command: does a busy-device dispatch fail or cancel/replace?** No longer a *correctness* question — the post-command read (§4.2) reports the truth either way. It's now purely a **UX** question: confirm-before-replace vs. block-while-busy, decided per command as you build it.
- _(Previously-open items on relay reachability, auth, Bobnet history, `/v1/accounts/events`, and cross-entity concurrency are now resolved above.)_

---

### Appendix: one-paragraph summary to carry forward

Keep SQLite-as-truth and thin reducers — they already solve cross-screen consistency. Add one app-level `GameSync` service that owns the (already-built) `EventPipeline` and is the single consumer of the **account-wide** relay, writing to those tables and centralizing `event_type`→row mapping. Model long actions as first-class persisted `Operation` rows (one active per device, enforced); after every successful command do **one authoritative single-device read** to reconcile state (skip it only when the dispatch response is already the full device body). For **self-describing** actions (e.g. `travel`, whose dispatch returns `completes_at`) **interpolate progress locally instead of polling** — the main rate-limit win — and confirm once at the deadline. For **enqueued** actions (e.g. `print`, which returns only `enqueued`) the post-command read confirms acceptance but the relay completion event *is* the finish channel; bound any polling fallback. Reconcile all three writers (optimistic / event / poll) with timestamp-guarded, provenance-tagged upserts so a late poll can't regress an event. At hundreds-to-1000+ devices, **the relay — not polling — is how the fleet stays fresh**; make visibility gating load-bearing and reserve the expensive paged walks (stars, device fleet) for first-run and explicit refresh only. Surface the rate-limit budget (computed today, exposed nowhere) so scheduling can be budget-aware.
