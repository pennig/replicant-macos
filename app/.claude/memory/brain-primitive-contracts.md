---
name: brain-primitive-contracts
description: "The print / deliver / shuttle primitive contracts for the automation brain (wayfinder ticket 05). They are ENGINES (03's sense), not goals and not their own directives: step-libraries spliced into ONE composing MissionStepMachine. Key finding — they FIT the existing Directives engine with no mismatch: deliver is SalvageRun's shape (a carrier-owned directive dispatching to other devices), print is one step in it (enqueue_print(device_type) at a shared autofactory queue, NEVER leased), and they compose into one carrier-owned Relay Run directive (the reserved relayRun kind) that the brain launches for the tendMesh goal. Ownership (04's handed question): the carrier deviceCode is the ONLY lease + the relay held via transitive stow -> 04's 'add a committed-devices field?' = NO. No fleet tag. Transport gated by don't-strand (surge only to meshed targets; a relay MUST stow-aboard). Live-tested: pre-activating a relay then moving it does NOT mesh. shuttle (D4, collapse into shipped Haul Run vs distinct) deferred to ticket 06."
metadata:
  type: project
---

The contracts of the three composable primitives the new automation-brain behaviours are built
from. Resolved in `.scratch/automation-brain/issues/05-primitive-contracts.md` (full detail there;
map `.scratch/automation-brain/map.md`). Runnable concrete artifact (throwaway, kept beside the
07/08/09 research docs): `.scratch/automation-brain/research/05-primitives-prototype.swift`.
Sits on [[brain-executor-seam]] + [[brain-goal-decision-policy]]
+ [[brain-robustness-bar]] + [[salvage-run-design]] + [[directives-feature]].

## The one load-bearing finding: the engines FIT the engine
There is **no architectural mismatch** between the brain design and the pre-existing Directives
feature — an earlier prototype *manufactured* one by importing a fleet tag and by treating the
autofactory as a device you must lease. Drop both and:
- **`deliver` is SalvageRun's shape.** A `Directive` whose `deviceCode` is the carrier vessel, whose
  steps `.dispatch` commands to **other** devices (`MissionAction.dispatch` takes an explicit
  `deviceCode` — SalvageRun already deploys/activates the *relay*, not itself).
- **`print` is one step in that same machine** — `.dispatch(.print, deviceCode: <autofactory>,
  params: deviceType-only)`, then poll for `print_complete`.
- **The brain is a second author of directive rows** — it launches the Relay Run for the `tendMesh`
  goal exactly as it launches Survey Run for `survey`. The reserved-but-unbuilt **`relayRun`
  `DirectiveKind` is the slot.** Additive (map standing preference); nothing is rewritten. The
  operator-launcher surface is simply a *different* author the brain doesn't use.

In 03's vocabulary: **print / deliver / shuttle are ENGINES**, not goals — the brain never touches
one; it ranks a goal, launches an executor, the executor uses the engines internally.

## The three contracts
- **`print`** — inputs: a print-capable device (autofactory / print-vessel) **already at a stocked
  location** + `device_type`. Preconditions: printer present [else `noPrinterAtSite` **escalate**];
  location stockpile ≥ the blueprint's six-type bill [else `printStockShort` **retry/idle** — self-
  supply refills it, so it never escalates]. Emits `.dispatch(.print, params: deviceType only)` — **no
  location, no resource bill ride the call** (`CommandClient+Printing.swift:13`); both are implied by
  *where the printer is*. Product: `print_complete` → `new_device_code`, **auto-deployed idle at the
  printer's location**; enqueued/async, so the composer **polls**. **The printer is a shared 10-slot
  queue, NEVER leased** — drop a job on it and walk away. Standalone-invokable (an event composer, a
  batch print) with no delivery.
- **`deliver`** — inputs: a deployed-idle device + a carrier + a target. Two transport modes gated by
  **don't-strand [robustness clause 7]**: **surge** (attach→travel→detach) delivers anything incl.
  non-stowable, but **ONLY to an already-meshed target** [else `deliveryWouldStrand` **escalate**]; a
  **relay** goes to an unmeshed target by definition, so it **MUST ride stowed aboard the vessel**,
  whose presence authorises deploy+activate in-situ. Steps: selectMode(don't-strand) → stow/attach →
  travel → deploy/detach in-situ → **[relay:] activate in-situ (vessel present)** → confirm `relaying`
  AND authoritative **`in_control_range`** (never a recomputed mesh view [clause 4]; backstopped by an
  activation deadline) → detach the run's tag. **Activation is deliver's tail for a relay**; a non-relay
  delivery ends at deployed/detached. **Live-tested constraint (operator):** pre-activating a relay and
  then moving it — even still-activated on a surge_plate — does **NOT** mesh; activation must be in-situ
  at the final location with a vessel present. SalvageRun's emplace/activate/confirm is the proven shape.
  Holds only the carrier.
- **`shuttle`** — cargo, multi-source → a hub. **OPEN (D4), deferred to ticket 06.** The **shipped**
  Haul Run ([[haul-run-design]]) is already a shuttle: a tag-driven repoint of a server-side AMI
  `ferry`, issuing no collect/deposit, single-sink (drain reachable piles → home). Whether `shuttle` is
  Haul Run generalised (add a deposit hub + a source set) or a distinct kind — and the multi-source
  shape itself — is owned by 06 (the hub model).

## Composition & ownership (04's handed question, answered)
print + deliver compose into **ONE carrier-owned directive** = the Relay Run (`relayRun` kind), the
`tendMesh` grow executor: `enqueue_print` at the autofactory → wait → **stow the fresh relay aboard the
carrier** → travel to the gap → deploy → activate in-situ → confirm meshed. **The carrier (`deviceCode`)
is the ONLY lease**; the printed relay is held **through** the carrier once stowed (04's existing
`deviceCode` + transitive-stow rule); the autofactory is never held. Therefore **04's "a multi-device
print/deliver executor may need 05 to add a committed-devices field" → NO new field, no new lease, no
fleet tag** — because the printer is a shared queue, not a leased device. **Build edge (not a design
problem):** between `print_complete` and the stow the fresh relay is briefly un-held; the carrier prints
*where it already is* and stows on the next step (one-tick window), and the brain never creates a job
that grabs a stray idle relay. A **print-vessel** carrier collapses printer == carrier to one
`deviceCode` (single-job throughput vs the autofactory's 10 slots — a build tradeoff, not a contract one).

## Report-up (04 §3) + new attention reasons
Engines report up **only** through the composing directive's `status` + `attentionReason` (they are
steps in one row — no new channel). New reasons and their `brainDisposition`: `printStockShort` /
`relayActivationFailed` → **retry**; `noPrinterAtSite` / `deliveryWouldStrand` → **escalate**; the event
composer's `needsFulfilmentChoice` → **decisionRequest** (the HITL seam).

## Downstream / fog
- **tendMesh (grow+prune) + the Relay Run executor** — the goal→directive decomposition and the
  worthiness heuristic — remain fog, **blocked on ticket 06** (hub model). 05 confirms `relayRun` is its
  home and locks the engines it will use.
- **D4 (shuttle vs Haul Run) + shuttle's multi-source shape** — fog, **blocked on 06**.
- **Location-event fulfilment** reuses the same step-library pattern + the `needsFulfilmentChoice`
  decision-request; its design inputs (01/04/05/08) are now complete — it needs a build plan, not a
  decision.
