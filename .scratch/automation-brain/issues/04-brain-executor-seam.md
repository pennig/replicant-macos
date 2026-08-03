# Brain ↔ executor seam

Type: grilling
Status: resolved
Blocked by: 01, 03
Labels: wayfinder:ticket

## Question

How does the brain start, stop, and own executors without double-committing a device?

The brain is additive: it launches/retires the existing bespoke runs (Survey roam,
Salvage Run) as opaque executors and, later, the new primitive-based behaviours. This
ticket defines the seam between the *policy* (tickets 01/03) and the *machinery* (the
existing `DirectiveEngine` + `MissionStepMachine`s).

Resolve:
- **Launch/retire contract.** How does the brain create a directive (today the launcher
  sheets do this) and how does it retire one? A directive is created with
  `controllerCode: nil` and claims its controller at preflight — does the brain reserve
  devices earlier, and if so how does that interact with `assignController`?
- **Ownership.** A device must serve at most one executor at a time. Who records the claim
  — the brain, the `CommandGovernor` (per-device in-flight claim, but that's per-command
  not per-mission), or a new mission-level lease? How is a lease released on
  completion/stall/cancel without wedging the device (the governor's release-on-every-path
  precedent)?
- **Feedback.** How does the brain learn an executor finished, stalled, or needs the one
  HITL decision (a location-event approach choice)? Does it read `Directive.status` +
  `DirectiveAttentionReason`, or a richer channel?
- **Existing stalls.** Today a stall halts and waits for the operator. Under the brain,
  which stalls become the brain's problem to route around vs still the operator's? (The
  stall matrix was deliberately kept as "everything halts" — does B change that, and does
  that reopen the auto-skip decision that was rejected twice?)

Consult `/grilling`. Must cite 02. Feeds 05 and every capability build.

## Answer

**Thesis.** The brain is an **allocation layer** that sits *above* the existing `DirectiveEngine`
machinery and touches it through a deliberately tiny vocabulary: **create a directive**, **cancel a
directive**, and **drive the sanctioned resolution verbs** (`retry`/`cancel`). It never enacts, never
composes, never hand-edits an executor's internals. Design record:
`app/.claude/memory/brain-executor-seam.md`.

### 1. Placement — an off-main plan loop on the existing actor
`DirectiveEngineCore` is already a plain `actor` (not `@MainActor`): supervisor + per-directive
executor `Task`s on the cooperative pool, all DB access async GRDB, zero UI. The brain is a **new plan
loop on that same actor**, sibling to the supervisor's `reconcileExecutors` loop, ticking every 5s
**off the main thread**:
- **Race-free** two ways — actor-isolated in-memory coordination + GRDB-serialized `database.write`.
  Its output is a manual launch's: write a `.running` row, the supervisor spawns its executor next
  `reconcileExecutors`.
- **Pure ranking runs *nonisolated*** (clause 3): read snapshot (actor/DB) → rank (pure, off-actor,
  doesn't hold the actor even for a large fleet) → apply writes (actor/DB). The "compute off-main,
  apply on-actor" pattern the star map used for `LabelSelection`.
- **Structured concurrency, not a `DispatchQueue`** — keeps `TestClock` determinism (clause 5).
- **Same actor** (not a separate one): the brain and executors coordinate through the directives
  table, not shared memory, so one actor = one lifecycle owner, no cross-actor handshake.

### 2. Launch / retire / ownership — the directive rows ARE the lease ledger
**Launch** = create a row exactly like a launcher sheet: `deviceCode` = vessel (NOT-NULL at creation),
`controllerCode` = **nil** (claimed at preflight via `assignController` — eager-writing goes stale),
`fleetTag` for tag-driven kinds, `kind`/`roamCentre`/`targets`/`step`/`stepStartedAt`/`.running`. The
supervisor picks it up on its next `reconcileExecutors`. **No eager persistent reservation**; the
controller claim stays at preflight, so the brain never writes `controllerCode` and never conflicts
with `assignController`.

**Reservation — no new lease, no new table.** The plan pass excludes every device committed by a
directive in an owning status (`running`/`paused`/`needsAttention`):
- **`deviceCode` (vessel) + everything stowed transitively aboard it** — this closes the
  `controllerCode`-nil window, since the survey controller + drones are stowed aboard the vessel
  (Stage-4: STOWED not co-located), so reserving the vessel reserves them before preflight claims the
  controller;
- the claimed **`controllerCode`**;
- the **`fleetTag`** (Salvage/Haul fleets are a tag, not a device list).
Plus **in-tick in-memory reservation** within one pass (the 03 greedy pass). Statelessness holds:
nothing persists between ticks but the directive rows.

**Two claim layers already exist; the brain uses the coarser one.** `CommandGovernor`'s per-command
in-flight claim (released every path) stays as-is; the **per-mission device lease** is the row's
committed set held across `owningStatuses`.

**Release / retire.** `.completed`/`.cancelled` free the lease; `.paused`/`.needsAttention` keep it
(persistent stall → §4). **Retire = write `.cancelled`, status-guarded (compare-and-swap: only advance
a row still `.running`)** so a retire can't be clobbered by an executor's in-flight `evaluateOnce`
write — a lost-update window the operator-cancel path technically shares today, hardened here (clause
7). Retire **leaves the server-side AMI directive in force** (matching operator-`cancel`; clearing it
is enactment); a reallocated controller gets a fresh `set_directive` at the next mission's preflight,
an un-reallocated one idles under its last harmless config, surfaced in the why-view.

**Contract handed to 05:** every executor must make its committed device set **discoverable from its
row**. Vessel-shaped kinds satisfy this via `deviceCode` + transitive stow; tag-shaped via `fleetTag`;
a future multi-device print/deliver executor (fixed printer + mobile transport, neither aboard the
other) may need 05 to add a committed-devices field. *If the brain can't see a device is committed by
reading the row, it double-commits it.*

### 3. Feedback — status + attentionReason, re-read each tick
The brain's entire picture of "which executors are running and how" is the directive rows re-read each
tick — **`Directive.status` + `attentionReason`** (this *is* the stateless memory of clause 2). The
`DirectiveLogEntry` timeline feeds the why-view's *detail* (clause 8), but the brain's *decisions* key
only off status + reason. `.paused` is the operator's; the brain leaves it. A roam run idling with
nothing-reachable-yet reads `.running` and rightly keeps its lease (the brain needn't distinguish
working-from-idle for reservation; "idle" is derived).

**The HITL location-event choice rides the same `.needsAttention` channel** as a distinguished
**decision-request** (not a fault) — reusing the lease-holding, not-auto-resumed, surfaces-in-pane
machinery rather than a new `DirectiveStatus`. The fault-vs-decision distinction lives on the reason
(see §4). How the operator's pick is recorded and consumed is 05's (the composing executor's contract).

### 4. Stall disposition — the mission-layer matrix is UNCHANGED; the brain adds a response layer
Executors still halt-and-surface on every reason (the engine "never improvises or auto-retries at the
mission layer" — the existing invariant, untouched). The brain, seeing a halt via §3, **responds
through the existing operator-facing resolution surface** — as an **automated operator over the
sanctioned verbs `{retry, cancel}` only**, never `{skipTarget, pause, resume}`, never hand-editing
step/target/status.

- **Auto-skip stays rejected** (twice-rejected). **Auto-retry ≠ auto-skip:** retry re-attempts the
  *same* target, bounded, and a persistent problem re-stalls → **escalates**; nothing abandoned or
  hidden. `pause`/`resume` stay operator-only (the brain never resumes behind the operator's back; it
  stops a mission by `cancel`, not `pause`).

**Disposition is one classification on the reason — `DirectiveAttentionReason.brainDisposition`** (a
computed property beside `displayName`/`guidance`, first-class + testable):

| Disposition | Rule | Brain response | Example reasons |
|---|---|---|---|
| **retry** | self-corrects on re-read/re-attempt | bounded auto-`retry`, then escalate | `surveyIncomplete`, `unreachableDevice`, `vesselPositionUnconfirmed`, `salvageSystemUnresolved`, `salvageBodyNotDepleted`, `commandRejected`, `relayActivationFailed` |
| **escalate** | needs a power the brain lacks (staging/adoption/replacement/tagging), or an executor exhausted something it can't self-compose | surface + escalate to operator | `noSurveyControllerAboard`, `noSurveyDroneAboard`, `noMiningControllerAboard`, `noMiningDroneAboard`, `noRelayCoLocated`, `dronesNotRecovered`, `launchDeployedNothing`, `noHaulControllerTagged`, shipped-run `awaitingRelayRestock` |
| **decisionRequest** | expected operator choice, not a fault (§3) | route to operator (HITL seam) | future `needsFulfilmentChoice` |

**Retry budget is timeline-derived (stateless, clause 2):** the brain counts prior `retry`→re-stall
cycles for this stall from the `DirectiveLogEntry` timeline (`.resolved`/`.stalled`), not an in-memory
counter; over budget → escalate. Exact budget/deadline graduates to 02's deadline policy.

**Supply is executor self-composition, NOT brain orchestration.** The brain does allocation, never
supply between executors. An executor needing a consumable **composes the engines itself**
(`print`/`deliver`/`shuttle`). Cross-goal supply dependency (tendMesh needing mined resources) is
handled by **derivability** (tendMesh isn't feasible until resources exist; it idles) — the 03 rule.
So **capability #4 closes because `tendMesh` is a new self-supplying composing executor** that never
emits `awaitingRelayRestock`; the shipped Salvage Run's version `escalate`s (additive, unchanged) and
is superseded when tendMesh takes over relay-planting (05/fog).

### Robustness bar (02) — the clause-1 amendment this ticket makes
Clause 1 widens from "Brain's only writes are launch/retire … never a running directive's
step/target/status" to add: **the brain may also drive the sanctioned `DirectiveResolutionClient`
verbs (`retry`/`cancel`) as an automated operator — never hand-editing step/target/status directly.**
Faithful to the spirit (no new enactment path; the brain drives the same safe, single-transaction,
logged-no-op-guarded verbs a human does, growing no new powers). Applied to both
`issues/02-robustness-bar.md` and `app/.claude/memory/brain-robustness-bar.md`.

Clause coverage: **1** selector-not-enactor (create/cancel + sanctioned verbs, no hand-edit); **2**
stateless (status+reason re-read; retry budget timeline-derived; in-tick reservation only); **3** pure
selection (nonisolated ranking; the confirm-read/status-guard only vetoes); **5** testable end-to-end
through the seam under `TestClock`; **6** safe degradation (retry / escalate / decisionRequest; idle vs
stall distinct); **7** bounded blast radius (row-lease prevents double-commit; status-guarded retire;
worst case = a wasted trip or operator-resolvable stall); **8** why-view over ranked goals + the gate
+ limits.

### Downstream
- **Unblocks 05** (primitive contracts) — inherits: the committed-devices-on-the-row contract, the
  composing-executor **self-supply** pattern, and the `awaitingRelayRestock` / Salvage-Run disposition.
- **Location-event fulfilment** fog moves from "blocked on the seam (04)" → "blocked on 05."
- **Amends 02 clause 1** (both files). Frontier becomes **{05, 06}**. Nothing ruled newly out of scope.
