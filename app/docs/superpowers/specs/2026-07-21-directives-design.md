# Directives — automations groundwork + v1 feature design

> **SUPERSEDED 2026-07-24 by `2026-07-24-directives-design.md`.** The vision, engine architecture,
> and V3.9 groundwork below carry over intact. Revised there: the surface now unifies built-in AMI
> directives with custom missions (and moves to the Operations sidebar group), both mission step
> sequences are corrected against verified API facts, completion detection is specified, and
> print-if-missing is dropped as unimplementable. Read the newer doc for implementation.

**Date:** 2026-07-21
**Status:** Superseded (was: approved design, pre-implementation)
**Prereq reading:** `ARCHITECTURE_REVIEW.md` §V3.9 (automations readiness), `app/README.md` (event/command lifecycles)

## Vision

The player's expansion loop — explore unexplored systems, find salvage sites and asteroid belts,
mine them, haul resources to hubs, print more devices, repeat — is chore-heavy. Directives are
built-in mission types the app knows how to execute; the player supplies the strategy (which
target, which device, when) and the app runs the procedure. Play shifts from doing chores to
launching missions and watching them work.

**Operator context (design-load-bearing):** this is a single-operator app — part game interface,
part personal mission control. Success criterion is "sit back and watch it work." The known
failure mode (the player's Satisfactory arc) is *authoring friction*: when configuring the
machine becomes the chore, the game ends. Therefore:

- Launching a directive takes ~three clicks with aggressive defaults.
- The live watching experience (step timeline) is a first-class deliverable, not debug UI.
- Strategy stays manual; procedures are baked in. The app never decides *where* to expand.
- Exceptions pause and surface — exception-handling is gameplay, and the safety rail on API spend.
- The model stays **policy-ready**: a `Directive` row does not care whether a click or a future
  "keep the frontier expanding" policy created it. The standing-policy layer is explicitly
  out of scope for v1 but must not be precluded.

## V1 scope

Two mission kinds (the frontier slice; the economy — mining chains, haul loops — comes later):

1. **Survey Run** — vessel visits a queue of target systems: travel → system scan → record
   findings → next. Done when the queue empties.
2. **Relay Run** — the mesh extender: ensure an FTL relay is aboard (print-if-missing as an
   optional first step) → stow → travel to target → scan → deploy relay → verify the mesh link
   is up → next target or done.

Runtime expectation: **app-open only.** The server finishes whatever command is in flight
regardless; a closed app pauses only the *next* step. On relaunch, catch-up reconciles the
`Operation`/`Device` tables before the engine reads them, and the directive row is the checkpoint.

## Data model

Two new tables in `GameDatabase` (logout decision, per the documented rule: both account-scoped,
**both wiped on logout**):

- **`Directive`** — one row per mission instance: `kind` (surveyRun/relayRun), `status`
  (running / needsAttention / paused / completed / cancelled), assigned `deviceCode`, ordered
  target queue of system designations, current step (enum + per-step context), `attentionReason?`,
  timestamps.
- **`DirectiveLogEntry`** — the audit trail (V3.9 blocker 5, generalized from `RuleFiring`):
  step started, command dispatched (→ op id), op completed (→ event id), stall reason, player
  resolution. Feeds both debuggability and the watch-it-work timeline.

## Mission definitions

Missions are **pure, tested step machines**:
`(directive state, world snapshot) → dispatchCommand | wait | stall(reason) | advance | done`.
The engine owns all I/O; mission logic owns none.

- Reachability (same system or shared FTL mesh) is a **precondition on every dispatch**;
  mid-travel unreachability is an expected `wait` state, not a stall.
- Every step definition must be **validated against the live API via the probe-api skill before
  implementation planning** (mutating probes announced first). Known unknowns to verify: the
  relay stow/deploy command sequence and whether scan must precede deploy; relay-mesh
  confirmation event names (`relay.*`) and the /network link refresh; print-if-missing
  feasibility at arbitrary locations; exact travel/scan payloads for unexplored targets.
  The docs site is the authority over `openapi.json` on business rules.

## Engine

New **non-feature SPM module `DirectiveEngine`** (manifest rule: `Dependencies`, no TCA).

- One serial executor per directive, **off the event-dispatch hot path** (V3.9 blocker 2 pattern).
- **Observes reconciled state** (`Operation`/`Device` tables via SQLiteData), not raw events:
  it waits for *the specific op it created* to complete, keyed by op identity. Consequences:
  replay immunity is inherited from the P0 fixes, and loop protection (blocker 4) is inherent —
  the engine cannot be spooked by its own command echo. Any unavoidable raw-event route must
  carry an event-time freshness guard.
- Lifecycle: started/stopped with the sync engine; on logout, executors are cancelled **before**
  table wipes (same ordering rule as ingestion teardown).
- Composition root registers it like other ingestion services.

## Groundwork woven in (V3.9 blockers 3–5)

Shipped as part of this feature, not before it:

- **Blocker 3 — `CommandGovernor`** in `GameServices`, modeled on `PollCoordinator`: every engine
  dispatch consults the actions-bucket budget and a per-device pending-command guard before
  POSTing. Built as shared infrastructure so manual UI commands can adopt it later.
- **Blocker 4 — loop protection**: absorbed by the engine's op-identity design (above).
- **Blocker 5 — audit trail**: absorbed by `DirectiveLogEntry` (above); the detail-view timeline
  is the browsing UI.

## UI — `DirectivesFeature`

New TCA feature module; sidebar category **"Directives"** (name avoids the Missions/Operations
naming knot) with a needs-attention count badge. Standard list → detail layout.

- **List rows:** auto-generated name ("Relay Run → TAU-4"; designations in mono tokens), status
  badge via the tone taxonomy, step progress (m/n), assigned device with host icon.
- **Detail:** target queue, **live step timeline** fed by `DirectiveLogEntry` (the
  sit-back-and-watch view), `RCErrorBanner` with Retry / Skip target / Cancel when
  `needsAttention`, pause/resume controls.
- **New-directive flow:** feature sheet (`@Presents` enum destination per the presentation
  dialect): kind → targets → device → launch. Defaults preselected (e.g. nearest idle eligible
  vessel); happy path is ~three clicks.
- List query lives in `@ObservableState` per the house standard (`@FetchAll` in state, view is a
  pure renderer).

## Device tagging (in scope)

Any device assigned to an active directive is visibly tagged:

- **Device detail/inspector:** a directive chip (mission kind + link/affordance to the directive).
- **Device list rows:** a compact "on directive" indicator, plus a minimal filter to show only
  directive-engaged (or only free) devices.

This is the down-payment on a larger need recorded below.

## Error handling

**Pause and surface.** A stalled directive enters `needsAttention` with a typed
`attentionReason`; no improvisation, no auto-retry at the mission layer (transport-level
rate-limit retries stay where they live today, in the API middleware). Resolution verbs:
Retry step / Skip target / Cancel directive.

## Testing

- Mission step machines: unit tests as pure functions over fixture snapshots — the **stall
  matrix** (no relay aboard, no resources to print, unreachable device, scan finds nothing,
  command rejected) is the priority suite.
- `CommandGovernor`: tested in the style of the existing `PollCoordinator` tests.
- Engine: integration tests over in-memory `GameDatabase.bootstrap()`; loud `unimplemented`
  testValues per house rules.

## Out of scope (recorded follow-ups)

1. **Device-list organization at scale** — fleets in the hundreds outgrow a flat 3-pane list;
   needs its own design pass (grouping by system/role/status, saved filters, maybe search-first).
   The tagging + filter above is deliberately minimal.
2. **Economy missions** — mining chain, haul loop.
3. **Standing-policy layer** — "keep the frontier expanding"; spawns directives programmatically.
4. **Background/headless runner** — menu-bar agent or server-side executor; v1 is app-open only.
5. **Scheduled (cron-style) tasks** — explicitly declined for v1.
