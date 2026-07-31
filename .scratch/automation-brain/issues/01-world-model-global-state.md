# World model & global state

Type: grilling
Status: resolved
Blocked by:
Labels: wayfinder:ticket

## Question

What does the brain observe, and how does that global world model stay trustworthy?

Under a B-style orchestrator the brain decides from a *global* picture, not one
directive's `WorldSnapshot`. This ticket stress-tests the operator's confidence that
"between device + location refreshes and the SSE feed, maintaining global state won't be
too fraught."

Resolve:
- **Source of truth.** Is the world model the existing local SQLite (devices, locations,
  operations, siteAssays, FTL mesh), read the way the engine already reads it — or a new
  derived aggregate on top? What columns/tables does the brain actually need?
- **Freshness & authority.** How current must each fact be for a *dispatch* decision vs a
  *display* decision? Which facts are event-silent and can only change on an explicit read
  (see [[ami-drones-are-event-silent]], [[location-scope-cannot-see-stowed]],
  [[staging-freshness-vs-read-budget]])? How does the brain avoid deciding on stale rows —
  the exact failure mode that lost a drone complement and hung a run for ten hours?
- **Reconciliation.** How do device+location refreshes and SSE frames fold into one
  coherent picture without drift? Who triggers the refreshes the brain depends on, and how
  is that reconciled against the 120/min reads budget (`PollCoordinator`) and 60/min
  actions budget (`CommandGovernor`)?
- **Staleness handling.** When the model is uncertain, does the brain idle rather than act
  on a guess? (Ties to the robustness bar, ticket 02.)

Consult `/grilling`, `/domain-modeling`, and `probe-api` (GET-only) to confirm which reads
answer which questions. Feeds tickets 03, 04, 06 and the location-event build.

## Answer

**Thesis (the reframe the whole ticket turns on).** The brain never maintains a
fresh-*everything* global picture — that framing is what made the operator fear it would
be "too fraught." Instead: a **best-effort global picture for ranking/planning** +
**narrow, just-in-time confirmation at the moment of any action.** That is exactly the
already-shipped `preflight` / `.deferred` pattern (Survey Run), lifted from one directive's
`WorldSnapshot` to global scope. "Global state maintenance" stops being a fresh-everything
problem and becomes defer-and-confirm-at-point-of-action — which is proven live.

Six locked decisions:

### 1. Source of truth — derived `WorldView`, nothing new persisted
The brain reads a global **`WorldView`**, an in-memory value recomputed each 5s tick from
the *same* local SQLite tables the engine already reads — a scaled-up sibling of
`WorldSnapshot`. **No new persisted aggregate table.** This mirrors the shipped invariant
"built-in rows are derived, never persisted — a derived row cannot drift"
([[directives-feature]]); a materialised global-state table would re-introduce the
reconcile-diff drift the Directives feature deliberately refused.

### 2. Two-tier freshness — plan cheap, confirm at commit
- **Planning / ranking** runs on best-effort local rows kept current by the existing
  SSE → `StalenessTracker` → `.low` drain. A slightly stale rank just picks a slightly
  worse target and self-corrects next tick, so staleness here is harmless.
- **Dispatch preconditions** (staged? aboard? `in_control_range`? already claimed?) must be
  **confirm-read fresh** (`.high` / `MissionAction.refreshDevices`) at the moment of commit,
  exactly like Survey Run `preflight`. The brain **never commits an action on an
  unconfirmed positive claim** — the generalisation of `isFullyScanned(nil) == false` and
  "never trust a positive containment claim from an unread row."

### 3. Event-silent facts — static class + confirm-at-dispatch, no tracker
AMI-adopted drone stow/location columns are **event-silent**: they don't lag, they lie
indefinitely until read ([[ami-drones-are-event-silent]] — the ten-hour-hang root cause).
The brain holds a **static list** of which fact-classes are event-silent and always
confirm-reads them before acting (generalising `preflight`'s `stagingFreshness` horizon).
It may **rank freely on a stale event-silent row**, because the dispatch confirm-read does
two jobs at once — it gates the action **and repairs the very row it reads**
([[location-scope-cannot-see-stowed]]: `refreshDevices` writes the named rows). So a lie
costs exactly **one** wasted confirm-read and planning self-heals next tick. **No global
`StalenessTracker`-style annotation of event-silent rows** — that path is the one that
structurally cannot cover them anyway.

### 4. Triggers & budget — no new poller, shared budget, no carve-out
There is one process-shared `PollCoordinator` (120/min reads, floor 12) and one
`CommandGovernor` (60/min actions, floor 6). The brain:
- **Plans off the SSE drain** (triggers nothing itself — free).
- **Confirms its own new dispatches** (print/deliver/shuttle primitives; launch/retire
  decisions) with point-of-action `.high` reads against the **shared** `PollCoordinator`,
  just like `preflight`.
- **Launched executors keep owning their own freshness** (Survey's preflight/recover,
  Salvage's reads) — additive, unchanged.
It **never runs a global-scan poll loop** (the read-storm anti-pattern the roam-recall
recovery was built to avoid), takes **no budget carve-out** (existing floors already
protect interactive UI reads), and answers **saturation by reining in its own concurrency**,
not by demanding more budget (that pressure graduates to the robustness bar 02 + hub
model 06).

### 5. Reconciliation is exception-free — everything rides SSE + gap-repair
Verified by reading the code, not assumed:
- **Location events arrive over SSE.** `event.discovered` (category `event`) nudges the
  `.locationEvents` domain to re-read `accounts/events` authoritatively into the
  `LocationEvent` table the brain observes; reconnect fires the same via `gapRepair`
  (`LocationEventsIngestion.eventRoute`). No poller needed — the HITL seam's *detection* is
  event-live.
- **Spend is self-metered.** The brain authors every command, so it meters spend against the
  ceiling from its own action ledger locally, reconciling opportunistically off the account
  events that already flow (`AccountIngestion` on `experience.gained`). No read needed.
- **SSE dropout** is covered by the **existing tier-2 gap-repair** the brain simply inherits.
No global fact was found that falls through the net (event-live → SSE+gap-repair;
event-silent → confirm-at-dispatch; location events → SSE-nudged; spend → self-metered), so
the no-new-poller rule is **exception-free** — no periodic safety sweep.

### 6. Uncertainty — defer, escalate if persistent; never guess, never silently hang
When the brain can't confirm a precondition (budget exhausted, read failed, event-silent row
unread): **transient uncertainty → silently defer** to a later tick (the shipped `.deferred`
philosophy: "writes nothing, is not a failure; late, never lost"). **Persistent uncertainty
past a deadline → surface a stall/attention** to the operator, because the *other* half of
the ten-hour-hang lesson is that silent infinite idle is itself a failure — a stuck brain
must not look identical to a quiet one. Ticket 01 locks the **principle**; the exact
deadlines and the escalation surface **graduate to the robustness bar (02)**.

### The observation set (all from existing tables, read the engine's way)
1. **Devices, fleet-wide** — status, location, stow (`stowedInDeviceCode`), `controllerCode`,
   **`in_control_range`** (the authority truth — *read it, never recompute the mesh*, per
   ticket 09 / [[device-tags-and-control-range]]), tags (fleet-wide addressing), capabilities
   (`available_directives`/`commands`), travel block (`arrives_at`/`route`),
   `operational_capacity`.
2. **Operations** — the shipped open-vs-recently-closed split (`openOperations` /
   `dispatchedOperations`).
3. **Directives (runs)** — status, kind, claimed `controllerCode`/devices, `targets`/
   `roamCentre` (feeds the seam, ticket 04).
4. **Systems / locations** — census (`Star`/`Position`), scan completeness
   (`isFullyScanned` / `fullyScannedAt`), FTL mesh closure (`ftlLinks`).
5. **SiteAssays** — salvage/belt sites + remaining units.
6. **LocationEvents** — the quest-log table (SSE-nudged; the HITL seam).
7. **Spend** — self-metered from the brain's own action ledger; reconciled off account events.

**Downstream.** Unblocks tickets 03 (goal/decision policy) and 06 (resource-hub model) —
both listed 01 as their only blocker. Feeds 04 (seam) and the location-event build. No fog
graduated to fresh tickets by 01 alone (the remaining Not-yet-specified items each still
wait on more of the spine); nothing ruled out of scope; no other ticket invalidated.
