# Primitive contracts: print / deliver / shuttle

Type: prototype
Status: resolved
Blocked by: 04
Labels: wayfinder:ticket

## Question

What are the contracts of the three composable primitives, and how do they compose?

The new behaviours (mesh, auto-print+deliver, events) are built from a small set of
primitives rather than more bespoke machines. This ticket pins each primitive's contract
by making a rough concrete artifact (stub signatures + a worked composition) to react to.

Resolve, per primitive:
- **`print a device`** — inputs (device type, where, from which materials/hub), preconditions
  (feature gate, material availability), what it emits, failure modes. Note: a salvage vessel
  carries the `print` feature and mined output lands in the location stockpile, so
  print-in-situ is mechanically plausible (see [[salvage-run-design]]).
- **`deliver a device to a location`** — a printed/idle device → a target (relay to a gap,
  drone to a site, service bot / event device). How does it handle stow/launch, travel,
  arrival confirmation, and hand-off of command authority ([[ftl-authority-rule]])?
- **`shuttle cargo from source(s) → a location`** — the Haul Run's job generalised.
  **Key decision: does the unbuilt Haul Run collapse into `shuttle`, or ship as its own
  kind?** Multi-source (several stockpiles → one hub) is where resource hubs (ticket 06)
  meet this primitive.
- **Composition & seam.** Are primitives sub-machines a run/goal invokes, standalone
  directives the brain dispatches directly, or both? How do they report up to the brain
  (ticket 04)? Are they `MissionStepMachine`s themselves, or a lighter tier?

Build the stub artifact under `.scratch/automation-brain/research/` or a `/prototype`
branch and link it here. Consult `/prototype` + `/grilling`. Must cite 02. Depends on the
hub model (06) for `shuttle`'s multi-source shape — coordinate.

## Answer

**Thesis.** print / deliver / shuttle are **engines** (03's sense — mechanisms an executor uses),
modelled as **step-libraries spliced into ONE composing `MissionStepMachine`** — not new brain
powers, not their own directives, and not a lighter tier (the engine *has* no lighter tier: every
unit is a step machine emitting one generic `.dispatch`). A composing executor (the `tendMesh` Relay
Run; event fulfilment) is a single **carrier-owned** directive that sequences the libraries — exactly
as `SalvageRun` already inlines a deliver + a mine. The brain never touches an engine; it ranks a
goal, launches the executor, the executor uses the engines. Canonical record:
`app/.claude/memory/brain-primitive-contracts.md`. Runnable artifact (throwaway, kept as a
primary source beside the 07/08/09 research docs):
`.scratch/automation-brain/research/05-primitives-prototype.swift`.

### The engines FIT the existing engine — no mismatch (the load-bearing finding)
The operator's real question was whether the brain/goals/engines design is meshing with the
pre-existing Directives feature. It is — an early prototype *manufactured* a mismatch by importing a
fleet tag and treating the autofactory as a leased device. Drop both:
- **`deliver` is SalvageRun's shape** — a `Directive` whose `deviceCode` is the carrier vessel, whose
  steps `.dispatch` to **other** devices (`MissionAction.dispatch` takes an explicit `deviceCode`;
  SalvageRun already deploys/activates the *relay*, not itself).
- **`print` is one step in that same machine** — `.dispatch(.print, deviceCode: <autofactory>, params:
  deviceType-only)`, then poll `print_complete`.
- **The brain is a second author of directive rows** — it launches the Relay Run for `tendMesh` exactly
  as it launches Survey Run for `survey`. The reserved-unbuilt **`relayRun` `DirectiveKind` is the
  slot.** Additive (map standing preference); nothing rewritten — the operator launcher is just a
  *different* author the brain doesn't use.

### The three contracts
- **`print` (engine).** inputs: a print-capable device (autofactory / print-vessel) **already at a
  stocked location** + `device_type`. preconditions: printer present [else `noPrinterAtSite`
  **escalate**]; stockpile ≥ the six-type blueprint bill [else `printStockShort` **retry/idle** —
  self-supply refills, never escalates]. emits `.dispatch(.print, params: deviceType only)` — **no
  location, no resource bill** ride the call (`CommandClient+Printing.swift:13`); both implied by *where
  the printer is*. product: `print_complete` → `new_device_code`, **auto-deployed idle at the printer's
  location**; enqueued/async → composer **polls**. **Printer NOT leased** — a shared 10-slot queue
  (research 07). Standalone-invokable (event composer, batch) with no delivery.
- **`deliver` (engine).** inputs: a deployed-idle device + a carrier + a target. two transport modes
  gated by **don't-strand [02#7]**: **surge** (attach→travel→detach) delivers anything incl.
  non-stowable, but **ONLY to an already-meshed target** [else `deliveryWouldStrand` **escalate**]; a
  **relay** → unmeshed target by definition → **MUST stow aboard the vessel** (its presence authorises
  deploy+activate in-situ). steps: selectMode(don't-strand) → stow/attach → travel → deploy/detach
  in-situ → **[relay:] activate in-situ (vessel present)** → confirm `relaying` AND authoritative
  **`in_control_range`** (never a recomputed mesh [02#4]; activation-deadline backstop) → detach tag.
  activation is deliver's **tail** for a relay; non-relay ends at deployed/detached. **Live-tested
  (operator):** pre-activating a relay then moving it — even still-activated on a surge_plate — does
  **NOT** mesh; activation must be in-situ, vessel present. SalvageRun's emplace/activate/confirm is the
  proven shape. holds only the carrier.
- **`shuttle` (engine).** cargo, multi-source → a hub. **OPEN (D4), deferred to 06.** The **shipped**
  Haul Run is already a shuttle (tag-driven repoint of a server-side AMI `ferry`, no collect/deposit,
  single-sink). Whether `shuttle` is Haul Run generalised (+ deposit hub + source set) or a distinct
  kind — and the multi-source shape — is owned by ticket 06 (hub model).

### Composition & ownership (04's handed question, answered)
print + deliver compose into **ONE carrier-owned directive** = the Relay Run (`relayRun` kind), the
`tendMesh` grow executor: `enqueue_print` at the autofactory → wait → **stow the fresh relay aboard the
carrier** → travel to the gap → deploy → activate in-situ → confirm meshed. **The carrier (`deviceCode`)
is the ONLY lease**; the relay is held **through** the carrier once stowed (04's `deviceCode` +
transitive-stow rule); the autofactory is never held. So **04's "may need 05 to add a committed-devices
field" → NO** — the printer is a shared queue, not a leased device. **No fleet tag** (a wrong import
from Salvage/Haul, which tag a real drone fleet). **Build edge (not a design problem):** between
`print_complete` and the stow the fresh relay is briefly un-held; the carrier prints *where it already
is* and stows next step (one-tick window), and the brain never creates a job that grabs a stray idle
relay. A **print-vessel** carrier collapses printer == carrier to one `deviceCode` (single-job vs the
autofactory's 10 slots — a build tradeoff, not a contract one).

### Report-up (04 §3)
Engines report up **only** via the composing directive's `status` + `attentionReason` (steps in one row
— no new channel). new reasons → `brainDisposition`: `printStockShort` / `relayActivationFailed` →
**retry**; `noPrinterAtSite` / `deliveryWouldStrand` → **escalate**; the event composer's
`needsFulfilmentChoice` → **decisionRequest**.

### Robustness (02) — clause coverage
**1** selector-not-enactor (engines are executor steps; brain only launches/retires); **2** stateless
(pure per-tick `nextAction`); **3** pure selection, confirm-only veto (`in_control_range` read); **4**
fidelity — reachability read from authoritative `in_control_range` never a recomputed mesh, print
stockpile confirm-read; **5** testable end-to-end through the real dispatch seam under `TestClock`; **6**
safe degradation — `printStockShort` idles/retries, don't-strand + no-printer escalate, never guess;
**7** bounded blast radius — worst case a wasted print/trip or an operator-resolvable stall;
**don't-strand** is the deliver contract obligation (surge refused to unmeshed targets); carrier-only
lease prevents double-commit; **8** why-view over the composing directive's ranked goal + status.

### Downstream / fog
- **tendMesh (grow+prune) + the Relay Run executor** — the goal→directive decomposition + worthiness
  heuristic — remain fog, **blocked on 06**. 05 confirms `relayRun` is its home and locks its engines.
- **D4 (shuttle vs Haul Run) + shuttle's multi-source shape** — fog, **blocked on 06** (not 05).
- **Location-event fulfilment** reuses the step-library pattern + `needsFulfilmentChoice`; design inputs
  (01/04/05/08) now complete — it needs a build plan, not a decision.
- **No new Directive column, no new lease, no fleet tag** for print/deliver.
- Frontier after this: **{06}**.
