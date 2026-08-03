---
name: brain-executor-seam
description: "The seam between the automation brain (allocation layer) and the existing DirectiveEngine (wayfinder ticket 04). The brain is a nonisolated-ranking plan loop on the existing DirectiveEngineCore actor (off-main); it touches the engine through create-directive / cancel-directive / driving the sanctioned retry-cancel resolution verbs, never enacting or composing. Ownership: the running directive rows ARE the lease ledger (no new lease) — reserve by deviceCode+transitive-stow / controllerCode / fleetTag; retire = status-guarded .cancelled. Feedback = status+attentionReason re-read each tick. Stalls: mission-layer halt matrix unchanged; brain adds a response layer classified by DirectiveAttentionReason.brainDisposition (retry/escalate/decisionRequest); auto-skip stays rejected; supply is executor self-composition. Amends robustness-bar clause 1."
metadata:
  type: project
---

The seam between the automation brain (the standing global orchestrator, an **allocation layer**) and
the existing `DirectiveEngine` machinery. Resolved in
`.scratch/automation-brain/issues/04-brain-executor-seam.md` (full detail there; map
`.scratch/automation-brain/map.md`). Sits on [[brain-goal-decision-policy]] + [[brain-robustness-bar]]
+ [[directives-feature]].

## The brain's whole vocabulary against the engine
**Create a directive · cancel a directive · drive the sanctioned `DirectiveResolutionClient` verbs
(`retry`/`cancel`) as an automated operator.** It never enacts, never composes, never hand-edits an
executor's step/target/status. Composition (incl. all *supply* — `print`/`deliver`/`shuttle`) lives in
executors; the brain does allocation only.

## Placement — off-main, on the existing actor
`DirectiveEngineCore` is already a plain `actor` (not `@MainActor`): supervisor + per-directive executor
`Task`s on the cooperative pool, async GRDB, no UI. The brain is a **new plan loop on that same actor**,
sibling to the supervisor's `reconcileExecutors` loop, ticking every 5s off-main. **Pure ranking runs
nonisolated** (read snapshot on-actor → rank off-actor → apply writes on-actor — the star map's
`LabelSelection` pattern). Race-free via actor isolation + GRDB-serialized `database.write`; its output
is a manual launch's (write a `.running` row, supervisor spawns the executor). Same actor = one lifecycle
owner; coordination is through the directives table, not shared memory. Structured concurrency, not a
`DispatchQueue` (keeps `TestClock` determinism).

## Ownership — the directive rows ARE the lease ledger (no new lease/table)
**Launch** = create a row like a launcher sheet: `deviceCode` = vessel (NOT-NULL), `controllerCode` =
nil (claimed at preflight via `assignController` — eager-writing goes stale), `fleetTag` for tag-driven
kinds. **Reserve** by excluding each owning-status directive's committed set:
`deviceCode` + **everything stowed transitively aboard the vessel** (this closes the controllerCode-nil
window — the controller/drones are stowed aboard), `controllerCode`, `fleetTag` — plus in-tick in-memory
reservation within a pass. Two existing claim layers stay: `CommandGovernor` per-command in-flight
(released every path) + the per-mission row lease. **Retire = write `.cancelled`, status-guarded (CAS:
only advance a row still `.running`)** so an executor's in-flight `evaluateOnce` write can't clobber the
retire (a lost-update window operator-cancel technically shares; hardened here). Retire **leaves the AMI
directive in force** (clearing is enactment); reallocation re-issues `set_directive`. **Contract to 05:**
every executor must make its committed devices discoverable from its row (a multi-device print/deliver
executor may need a new field — else the brain double-commits).

## Feedback — status + attentionReason, re-read each tick (the stateless memory)
The brain's whole picture is the directive rows: `status` + `attentionReason` (clause 2). The
`DirectiveLogEntry` timeline feeds the why-view detail; decisions key only off status+reason. `.paused`
is the operator's. The **HITL location-event choice rides `.needsAttention` as a distinguished
*decision-request*** (not a fault, not a new `DirectiveStatus`) — reusing the lease-holding,
not-auto-resumed, surfaces-in-pane machinery.

## Stalls — mission-layer matrix UNCHANGED; the brain adds a response layer
The engine still halts-and-surfaces on every reason ("never auto-retries at the mission layer" — intact).
The brain responds as an **automated operator over `{retry, cancel}` only** — never `{skipTarget, pause,
resume}`, never hand-editing. **Auto-skip stays rejected**; **auto-retry ≠ auto-skip** (same target,
bounded, self-escalating). Disposition is one classification on the reason,
**`DirectiveAttentionReason.brainDisposition`** (beside `displayName`/`guidance`):
- **retry** — self-corrects on re-read (`surveyIncomplete`, `unreachableDevice`,
  `vesselPositionUnconfirmed`, `salvageSystemUnresolved`, `salvageBodyNotDepleted`, `commandRejected`,
  `relayActivationFailed`) → bounded auto-`retry`, budget **timeline-derived** (count prior
  retry→re-stall cycles from the log — stateless), then escalate.
- **escalate** — needs a power the brain lacks (staging/adoption/replacement/tagging) or an executor
  exhausted something it can't self-compose (`noSurveyControllerAboard`, `no*Aboard`,
  `dronesNotRecovered`, `launchDeployedNothing`, `noHaulControllerTagged`, shipped-run
  `awaitingRelayRestock`).
- **decisionRequest** — expected operator choice (future `needsFulfilmentChoice`) → HITL seam.

**Supply is executor self-composition, never brain-orchestrated** — an executor needing a consumable
composes the engines itself; cross-goal supply is handled by derivability (tendMesh idles until
resources exist). **Capability #4 closes because `tendMesh` is a new self-supplying composing executor**
that never emits `awaitingRelayRestock`; the shipped Salvage Run's version `escalate`s (additive) and is
superseded when tendMesh takes over relay-planting (05/fog).

## Robustness bar amendment
Widens **clause 1** from "only launch/retire, never a running directive's step/target/status" to also
permit **driving the sanctioned resolution verbs (`retry`/`cancel`) as an automated operator, never
hand-editing directly** — faithful to the spirit (no new enactment path). Applied to
`issues/02-robustness-bar.md` and [[brain-robustness-bar]].
