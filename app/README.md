# Replicould — how it fits together

A native macOS client for [Replicant Space](https://replicant.space) (an
API-only Von Neumann–probe game). One sentence of architecture: **SQLite is
the source of truth, the server keeps it warm** — a real-time event stream and
a disciplined command engine write to local tables, and every screen is a thin
TCA feature observing those tables via `@FetchAll`.

This page is the map. The *why* lives in `ARCHITECTURE_REVIEW.md`, the
engine's original design rationale in `IMPLEMENTATION_PLAN.md` (historical,
with an SSE errata header), agent/workflow rules in `CLAUDE.md`, and the UI
contract in `Modules/UI/DESIGN_SPEC.md`.

## Module map

Everything lives in one SPM package, `Modules/`, layered bottom-up (arrows
show the load-bearing "depends on" edges, not every declared dep — the full
truth is `Modules/Package.swift`):

```
app target (composition root: ReplicantApp, AppFeature, MainFeature)
 │
 ├─ Feature modules (TCA lives ONLY here, by manifest)
 │    DevicesFeature · MessagesFeature · BlueprintsFeature · LocationsFeature
 │    LocationEventsFeature · ReplicantsFeature · SidebarFeature · AccountFeature
 │    LoginFeature · PrintQueueFeature · NewStarMapFeature · EventLogFeature
 │    RawAPIFeature      (+ TravelUI, PrintingUI: store-free shared UI)
 │
 ├─ GameSync ──────────► GameServices, GameSession        (the ingestion engine)
 │    GameSyncEngine (single stream consumer) · EventRouter · DeadlineScheduler
 │
 ├─ AccountManager ────► GameSession, GameModels          (session lifecycle)
 │    login/logout + the ordered SessionLifecycleHandler registry
 │
 ├─ GameServices ──────► GameSession, GameModels, UniverseModels, API
 │    the engine + every shared domain client:
 │    CommandClient (+ one file per command family) · Reconciler ·
 │    PollCoordinator/DeviceRefreshClient · StalenessTracker · DomainFreshness ·
 │    Devices/Replicants/Stars/Locations/LocationEvents/EventLog clients ·
 │    EventRoute + the ingestion bundles (LocationsIngestion, …) · LocationEventPolicy
 │
 ├─ GameDatabase ──────► GameModels, UniverseModels       (schema composition)
 │    the ONE migrator; previews/tests call GameDatabase.bootstrap()
 │
 ├─ GameSession ───────► API                              (session tier)
 │    GameClient (authed transport + rate governor) · KeychainClient
 │
 ├─ GameModels ─────────► API      (pure models: every core @Table row, its
 │                                  display types, and the tolerant wire→model
 │                                  init(schema:) mappings. No TCA, no SwiftUI.)
 ├─ UniverseModels ─────► GameModels   (the locations/census domain; wire DTOs
 │                                      internal behind the LocationDecoding facade)
 │
 ├─ API ───────────────► Utils     (generated OpenAPI client + middleware +
 │                                  EventStream: SSE client, pipeline, cursor)
 └─ UI · Utils                     (design system + leaf helpers)
```

Invariants the graph enforces: acyclic; **zero feature→feature edges** (shared
data goes down into GameModels, shared UI into UI/TravelUI/PrintingUI); TCA is
declared only by feature manifests; a new domain client imports `GameSession`
for `\.gameClient` and adds `GameServices` only when it needs the engine.

## The event lifecycle (server → screen)

```
GET /v1/events/stream (SSE, session token)
  → EventStreamClient      reconnects w/ jittered backoff; hands off .staleGap
  → EventPipeline          cursor persistence (monotonic), dedup, and — when the
  │                        cursor is stale — the SEQUENTIAL catch-up pull
  │                        (GET /v1/events, 15-min window) BEFORE connecting
  → GameSyncEngine         the single consumer (start/stop on login/logout)
  → EventRouter.dispatch   logs every event, persists the EventLog ledger,
  │                        fans out to matching EventRoutes serially
  → routes                 device events → Reconciler (event-time-guarded
                           upserts, op completion by family, payload
                           application) + StalenessTracker marks;
                           domain events → DomainFreshness.invalidate
                           (debounced authoritative re-read; NOTHING slow runs
                           on the dispatch path)
  → SQLite tables → @FetchAll in feature state → SwiftUI
```

Ingestion policies are declared in the modules that own the tables
(`MessagesIngestion`, `LocationEventsIngestion`, `LocationsIngestion`,
`FTLMeshRefresher.domainRegistration`); the composition root only registers
them. Provenance matters: `.stream` events are "now" (they may move the
roster), `.catchUp` replay is history (marks staleness, never walks state
through stale waypoints).

## The command lifecycle (click → confirmed truth)

```
feature → CommandClient.dispatch(kind, device, params)
  1. build the typed body (per-family file; fails fast pre-optimism)
  2. optimistic Operation row  → instant UI via @FetchAll
  3. POST /v1/devices/{code}   → 4xx: op rejected (no retry, prior op untouched)
  4. confirm: deadline (travel/recall/search…) · continuous (mine) ·
     enqueued (print) · immediate (scan/lifecycle; no op row)
     — supersede any other open op (one-open-op-per-device index)
  5. ONE confirm-read via deviceRefresher (.high) — coalesced + TTL'd so the
     SSE echo seconds later is suppressed, reconciled by Reconciler
  6. DeadlineScheduler arms the nearest completesAt; a completion event (or
     the deadline poll) closes the op — event time, not arrival time, wins
```

Budget discipline (120 reads / 60 actions per minute): all reads funnel
through `PollCoordinator` (coalescing, TTL, budget floor); events mostly
**mark stale** instead of reading (`StalenessTracker` drains visible-first);
appear-paths call `refreshIfStale`, never unconditional refetches; the four
paged walks are cold-only behind empty-table gates.

## Read these first

1. `Modules/GameSync/Sources/GameSync.swift` — the engine's lifecycle and the
   device route (the header narrates the whole ingestion story).
2. `Modules/API/Sources/EventStream/EventPipeline.swift` — cursoring, dedup,
   catch-up ordering (the replay-correctness core).
3. `Modules/GameServices/Sources/Reconciler.swift` — the reconciliation rule
   (`IMPLEMENTATION_PLAN.md` §6) that keeps concurrent writers honest.
4. `Modules/GameServices/Sources/CommandClient.swift` — the dispatch spine
   (§5.1); one `CommandClient+<Family>.swift` per command family.
5. `macOS/ReplicantApp.swift` — the composition root: what gets registered,
   in what order, and why the order is load-bearing at logout.

Then skim `Modules/GameSync/Sources/DeadlineScheduler.swift` and
`Modules/GameServices/Sources/DomainFreshness.swift` for the two timing
mechanisms, and `.claude/memory/MEMORY.md` for the accumulated gotchas.
