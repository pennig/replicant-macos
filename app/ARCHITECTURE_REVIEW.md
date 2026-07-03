# Replicould macOS — Architecture Review

_Reviewer: Claude (Opus 4.8). Date: 2026-06-25. Scope: modularity, extensibility, and fitness for the core requirement — driving long-running server actions and giving best-effort real-time progress feedback while minimizing polling against a rate-limited, increasingly-paged API._

_Revised 2026-06-25 with answers to §7's open questions folded in. The most consequential answers: dispatch responses come in two shapes (some return full entity state, some only "enqueued"); the relay is **account-wide** while backfill is per-replicant; and a heavy account has **fewer than 10 replicants but hundreds-to-1000+ devices.** These reshaped §4.2, §5, §6, and §7._

_Revised again 2026-06-25: the relay is confirmed reachable (`https://replicant.pennig.name/api/stream`) and is a **single SSE connection multiplexing three logical streams** — game events, account messages, and Bobnet chat. `GameSync` must therefore be a router/demultiplexer, not just an event→row mapper. See §5.1 (now §5.1's "router" framing) and the new §4.5._

_**V2 — 2026-07-03.** Most of the architecture prescribed below is now built, and built faithfully. This revision records conformance, the three points where the implementation drifted from the spec (one of them defeats the §5.3 correctness guarantee), and a concrete **shared-layer / module split** proposal for the `DependencyClients` god-module concern raised in §3.3. It is written as a self-contained update: the sections below (§1–§7) are preserved verbatim as the original design record. **Read the "V2 Update" section immediately below first.**_

This is a reference document, not a change request. It is organized as: (1) verdict, (2) what the codebase gets right, (3) modularity/extensibility critique, (4) the core problem reframed, (5) candidate architectures for the core problem with trade-offs, (6) prioritized recommendations, (7) open questions for you to resolve with your product context.

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
6. Watch items: ~~`RelayClient` bad-token infinite retry~~ (**done** — stops on 401/403); ~~extract `PrintPlanSheet`~~ (**done** — `PrintingUI` module, last feature→feature edge erased); ~~gate backfill on cursor freshness~~ (**done**); defer the `GameSession` split; document the secondary-query convention; **rename `DependencyClients` → `GameServices`** (the residual after the GameModels split — still pending; app links it by name so needs a pbxproj product-rename).

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
