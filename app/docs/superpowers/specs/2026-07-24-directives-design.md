# Directives — unified built-in + custom automations (v2 design)

**Date:** 2026-07-24
**Status:** Approved design, pre-implementation
**Supersedes:** `2026-07-21-directives-design.md` (v1 — vision and engine architecture carry over;
mission sequences, surface, and data model are revised here)
**Prereq reading:** `ARCHITECTURE_REVIEW.md` §V3.9 (automations readiness), `app/README.md`
(event/command lifecycles)

## What changed from v1, and why

1. **The naming knot is resolved by unification, not avoidance.** The backend already has a thing
   called a directive — the AMI `set_directive` standing behaviour on a single device. v1 sidestepped
   the collision by picking a free word. v2 embraces it: **one surface shows both**, labelled
   *built-in* (AMI, server-executed) and *custom* (multi-step missions, app-executed). This is
   conceptually earned rather than cosmetic — Survey Run's step 4 *is* a `set_directive` call, so a
   custom mission literally composes a built-in one.
2. **Sidebar placement:** Directives lands in the **Operations** group.
3. **Mission sequences corrected** against API facts (§4). The Relay Run no longer scans and gains an
   explicit `activate`; the Survey Run is rebuilt around the AMI Survey Controller.
4. **Print-if-missing is dropped permanently, not deferred.** Inventory is bound to a location and
   cannot be carried by a vessel (only devices with the `transport` feature carry cargo), so
   "print a relay if one isn't aboard" is not implementable at an arbitrary target.
5. **Completion detection is server-authoritative** — `directive.completed`, with a
   `locations/{star}` scan-count backstop — replacing v1's unspecified wait.

## Vision (carried over from v1, unchanged)

The player's expansion loop — explore, find sites, mine, haul, print, repeat — is chore-heavy.
Directives are missions the app knows how to execute; the player supplies strategy (which target,
which device, when) and the app runs the procedure.

**Operator context (design-load-bearing):** single-operator app, part game interface, part personal
mission control. Success criterion is "sit back and watch it work." The known failure mode is
*authoring friction* — when configuring the machine becomes the chore, the game ends. Therefore:

- Launching a directive takes ~three clicks with aggressive defaults.
- The live step timeline is a first-class deliverable, not debug UI.
- Strategy stays manual; procedures are baked in. The app never decides *where* to expand.
- Exceptions pause and surface — exception-handling is gameplay, and the safety rail on API spend.
- The model stays **policy-ready**: a `Directive` row does not care whether a click or a future
  standing policy created it. The policy layer is out of scope for v1 but must not be precluded.

## 1. Surface

**Sidebar:** `Directives` joins the **Operations** group (with Missions / Print Queue / Operations
Log). Needs-attention count badge on the row.

**One list, two row kinds:**

| | Built-in | Custom |
|---|---|---|
| What it is | an AMI directive set on a device | an app-run multi-step mission |
| Examples | `survey_system`, `gather_salvage`, `belt_search`, `patrol` | Survey Run, Relay Run |
| Executed by | the server | `DirectiveEngine` |
| Backed by | `Device` rows (no new persistence) | the `Directive` table |

**Built-in rows are fully manageable in place.** The detail pane offers **Reconfigure** and **Clear**,
presenting the existing composer. Rationale: in a three-pane layout the detail pane *is* the device
context, so a read-only pane that says "go edit this elsewhere" is worse UX — and making one kind
read-only would re-introduce exactly the asymmetry the unification exists to remove.

**Deferred to a later slice:** creating a *brand-new* built-in assignment from this view (it needs a
directive-capable-device picker that doesn't exist yet). In v1, `+ New Directive` creates custom
missions only; a fresh AMI directive is still set from the device inspector.

### Module change: extract the composer

`DirectiveComposer` + `DirectiveComposerSheet` + `DirectiveComposerTests` move out of `DevicesFeature`
into their own small feature module, so `DevicesFeature` and `DirectivesFeature` can both present it
without feature→feature coupling (which would drag the whole device inspector into the graph).

It cannot live in `PrintingUI`/`TravelUI` — those are TCA-free by manifest (`GameModels` + `UI` only)
and the composer owns a `@Reducer`. A feature-tier shared leaf with two parents is the correct shape;
the composer is already self-contained behind a delegate interface, so the move is mechanical.

## 2. Data model

**`Directive`** — custom missions only. One row per mission instance:
`kind` (surveyRun / relayRun), `status` (running / needsAttention / paused / completed / cancelled),
assigned `deviceCode` (the vessel), ordered target queue of system designations, current step
(enum + per-step context), `returnToOrigin` flag + the origin designation, `attentionReason?`,
timestamps.

**`DirectiveLogEntry`** — the audit trail (V3.9 blocker 5) *and* the landing spot for
`directive.completed`. Carries an optional `directiveID` **and** an optional `deviceCode`, so one
table serves both row kinds: a custom mission's step timeline, and a built-in row's completion
history. Entry kinds: step started, command dispatched (→ op id), op completed (→ event id),
directive completed, stall reason, player resolution.

That second half is what makes the unified surface pay off — a built-in row gets a real timeline
instead of being a static config readout.

**Built-in rows get no table.** They are `Device` state, queried with `@FetchAll` filtered to
`currentDirective != nil`. The model already exposes everything needed: `availableDirectives`,
`currentDirective`, `currentDirectiveConfig`, `controlledDevices` (each with type/status/location).

**Why not mirror built-ins into the `Directive` table:** the server owns AMI directive state.
Mirroring it locally creates a drift bug and turns every device refresh into a reconcile-and-diff.
Deriving means built-in rows are structurally incapable of lying.

Both tables are account-scoped and **both wiped on logout**, with executors cancelled *before* the
wipes (the same ordering rule as ingestion teardown).

## 3. Verified API facts

Supplied by the operator and **confirmed by live probe** (2026-07-24). Load-bearing for §4 — if any
of these turn out to have drifted, the affected step sequence changes:

- **`stow`** requires the target device to be **co-located** with the stowing vessel. It can be
  issued on the target device with no arguments, *or* on the stowing device with target(s).
- **Scanning is not part of the FTL relay workflow.**
- **`deploy` does not activate a device on its own** — `activate` is a separate command.
- **`relay.activated`** is the SSE event when an FTL relay comes up. Existing code already refreshes
  the network on it.
- **`launch`** on an AMI controller **automatically deploys its adopted stowed devices**, provided
  they are co-located or otherwise reachable via the FTL relay mesh. (So the reachability
  precondition applies to `launch`, not only to travel.)
- **`directive.completed`** is issued with payload `{"directive": "survey_system"}`, associated with
  the AMI controller's `device_code` and the star system being surveyed.
- **`locations/{STARNAME}`** carries `planets_total` / `planets_scanned` and `moons_total` /
  `moons_scanned`. Both pairs matching ⇒ the system is fully scanned.
- **Inventory is bound to a location** and cannot be carried by a vessel; only devices with the
  `transport` feature carry cargo. (This is what kills print-if-missing.)
- **Replicant scan on arrival is already automatic** in the existing codebase — not a step the
  engine issues.

## 4. Mission step machines

Missions are **pure, tested step machines**:
`(directive state, world snapshot) → dispatchCommand | wait | stall(reason) | advance | done`.
The engine owns all I/O; mission logic owns none.

Reachability (same system or shared FTL mesh) is a **precondition on every dispatch**; mid-travel
unreachability is an expected `wait`, not a stall.

### Survey Run — per target

1. **Stow** the AMI Survey Controller and **≥1 Survey Drone** aboard the vessel (co-location
   required; more drones = faster scanning).
2. **Travel** to the target system.
3. *(Replicant scan happens automatically — no engine step.)*
4. **`set_directive survey_system`** on the controller with config
   `{planets: "all", moons: "all", recall: true}` — a full survey, drones recalled when done so the
   vessel can move on. **Skipped only if `currentDirective == "survey_system"` *and* the in-force
   config already equals that**; any mismatch (e.g. `moons: "none"` left from manual use) re-issues.
5. **`launch`** on the controller. This deploys its adopted stowed drones.
6. **Wait for completion** (§5).
7. **Next target.** When the queue empties, the vessel **stays at the last target** unless the
   directive was created with its optional `returnToOrigin` flag, which appends a final travel leg
   back to the system the run started from. Default **off** — the common case is chaining onward,
   and an unwanted return leg costs fuel and time.

### Relay Run — per target

1. **Ensure a relay is aboard.** Stow one if co-located; **stall `noRelayCoLocated`** if not.
   (No print-if-missing — see §3.)
2. **Travel** to the target system.
3. **`deploy`** the relay. *(No scan step.)*
4. **`activate`** the relay.
5. **Wait for `relay.activated`.**
6. **Next target**, or done.

## 5. Completion detection

The riskiest wait in the design: the AMI controller drives its drones server-side, so there is no op
the app created to key off.

**Fast path — `directive.completed`.** Matched on controller `device_code` + `directive ==
"survey_system"` + the target system, guarded by `eventTime >= stepStartedAt - 5s`. This reuses the
exact guard shape `Reconciler.completeOpenOperation` already implements: it is *issue-time relative*,
not wall-clock relative, so it rejects replayed pre-step events while still accepting a genuine
completion delivered by catch-up after the app was closed.

**Backstop — `locations/{star}`.** One read comparing `planets_scanned`/`planets_total` and
`moons_scanned`/`moons_total`. Chosen over inferring from drone state because drones or the
controller may have moved on to another system and would report unreliable data.

The same read serves two more purposes:

- **Precondition:** a target already fully scanned is *skipped*, not surveyed.
- **Confirmation:** if a completion event arrives but the counts disagree, the directive stalls
  `surveyIncomplete` rather than silently advancing.

## 6. Engine

New **non-feature SPM module `DirectiveEngine`** (manifest rule: `Dependencies`, no TCA).

- One serial executor per **custom** directive, **off the event-dispatch hot path** (V3.9 blocker 2
  pattern). Built-in rows have no executor — the server runs them.
- **Observes reconciled state** (`Operation` / `Device` / `DirectiveLogEntry` via SQLiteData), not raw
  events. Replay immunity is inherited from the P0 fixes, and loop protection (blocker 4) is inherent —
  the engine cannot be spooked by its own command echo.
- **New `EventRoute` matching `.category("directive")`** — nothing routes `directive.*` today. Its
  only job is to write a `DirectiveLogEntry` under the event-time guard; the engine then observes the
  row. This keeps the observe-reconciled-state invariant intact and yields the timeline entry for free.
- Lifecycle: started/stopped with the sync engine; on logout, executors cancelled **before** table
  wipes. Composition root registers it like other ingestion services.

### Groundwork woven in (V3.9 blockers 3–5)

- **Blocker 3 — `CommandGovernor`** in `GameServices`, modeled on `PollCoordinator`: every engine
  dispatch consults the actions-bucket budget and a per-device pending-command guard before POSTing.
  Built as shared infrastructure so manual UI commands can adopt it later.
- **Blocker 4 — loop protection**: absorbed by the engine's op-identity design.
- **Blocker 5 — audit trail**: absorbed by `DirectiveLogEntry`; the detail-view timeline is the
  browsing UI.

### FTL mesh incremental add (in scope)

`FTLMeshRefresher` currently rebuilds the **entire** mesh — O(relays) serial network reads — on every
`relay.*` event. Relay Run turns that from rare into routine: an N-target run triggers N full
rebuilds, each more expensive than the last.

**Change:** on `relay.activated`, read only the newly activated relay's network view and union its
edges into the stored mesh. The full rebuild stays on the roster-change trigger and manual refresh.
This feature is what makes the cost routine, so it pays for it; the change is contained to one file
that already has tests.

## 7. UI — `DirectivesFeature`

New TCA feature module. Standard list → detail. Both queries live in `@ObservableState` per the house
standard (`@FetchAll` in state, view is a pure renderer); the list is a merge of the two typed
collections into a common row enum.

**List rows:** kind badge (built-in / custom), auto-generated name ("Relay Run → TAU-4"; designations
in mono tokens), status badge via the tone taxonomy, step progress (m/n) for custom rows, assigned
device with host icon.

**Detail pane branches on row kind** — the two genuinely differ in content:

- **Custom:** target queue, live step timeline fed by `DirectiveLogEntry` (the sit-back-and-watch
  view), `RCErrorBanner` with Retry / Skip target / Cancel when `needsAttention`, pause/resume.
- **Built-in:** directive name + config summary, controlled devices with status, completion history
  from `DirectiveLogEntry`, and **Reconfigure / Clear** presenting the extracted composer.

**New-directive flow:** feature sheet (`@Presents` enum destination per the presentation dialect):
kind → targets → device → launch. Defaults preselected (e.g. nearest idle eligible vessel); happy
path is ~three clicks. Custom missions only in v1.

### Device tagging (in scope)

- **Device detail/inspector:** a directive chip (mission kind + link to the directive).
- **Device list rows:** a compact "on directive" indicator, plus a minimal filter for
  directive-engaged (or free) devices.

This is the down-payment on the device-list-at-scale need recorded in §9.

## 8. Error handling & testing

**Pause and surface.** A stalled directive enters `needsAttention` with a typed `attentionReason`; no
improvisation, no auto-retry at the mission layer (transport-level rate-limit retries stay in the API
middleware). Resolution verbs: **Retry step / Skip target / Cancel directive**.

Stall reasons include: `noRelayCoLocated`, `noSurveyDroneAboard`, `unreachableDevice`,
`surveyIncomplete` (backstop read disagrees with the completion event), `commandRejected`.

**Testing:**

- Mission step machines: unit tests as pure functions over fixture snapshots — the **stall matrix** is
  the priority suite (no relay co-located, no drone aboard, unreachable device, backstop disagrees,
  command rejected).
- Completion detection: the event-time guard (replayed pre-step event rejected; post-close catch-up
  accepted) and the backstop/precondition/confirmation branches.
- `CommandGovernor`: tested in the style of the existing `PollCoordinator` tests.
- FTL mesh incremental add: union-vs-rebuild equivalence.
- Engine: integration tests over in-memory `GameDatabase.bootstrap()`; loud `unimplemented`
  testValues per house rules.

## 9. Out of scope (recorded follow-ups)

1. **Built-in directive *creation* from the Directives view** — needs a directive-capable-device
   picker; deferred to a slice after the engine is proven. Reconfigure/Clear ship in v1.
2. **Device-list organization at scale** — fleets in the hundreds outgrow a flat three-pane list;
   needs its own design pass (grouping by system/role/status, saved filters, search-first). The
   tagging + filter in §7 is deliberately minimal.
3. **Economy missions** — mining chain, haul loop.
4. **Standing-policy layer** — "keep the frontier expanding"; spawns directives programmatically.
5. **Background/headless runner** — menu-bar agent or server-side executor; v1 is app-open only.
6. **Scheduled (cron-style) tasks** — explicitly declined for v1.

**Not deferred — permanently out:** print-if-missing, which is not implementable given
location-bound inventory (§3).

## 10. Implementation staging

This spec is larger than one sitting. The natural cut lines, each independently shippable and
reviewable (the device-commands work staged the same way):

1. **Composer extraction** — move `DirectiveComposer` into its own feature module. Pure refactor, no
   behaviour change, existing tests must stay green. Unblocks everything UI-side.
2. **Schema + read-only unified list** — `Directive`/`DirectiveLogEntry` tables, `DirectivesFeature`
   with both row kinds, built-in detail pane with Reconfigure/Clear. No engine yet; the custom half of
   the list is simply empty. Ships a visibly useful screen on its own.
3. **`CommandGovernor` + `DirectiveEngine` skeleton** — governor with its `PollCoordinator`-style
   tests, engine lifecycle, `directive.*` event route writing log entries.
4. **Survey Run** — step machine + stall matrix + completion detection (§5), end to end.
5. **Relay Run** — step machine + the FTL-mesh incremental add.

Stages 4 and 5 are independent of each other once 3 lands.

## 11. Runtime expectation

**App-open only.** The server finishes whatever command is in flight regardless; a closed app pauses
only the *next* step. On relaunch, catch-up reconciles the `Operation`/`Device` tables before the
engine reads them, and the directive row is the checkpoint. The issue-time-relative completion guard
(§5) is what makes a post-close catch-up completion land correctly rather than being discarded as
stale.
