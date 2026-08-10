# CONTEXT — Replicould macOS app

Glossary of the app's ubiquitous language. **Definitions only — no implementation.**
Design records live in `.claude/memory/`; engineering rules in `app/CLAUDE.md`.

## Automation brain (Directives)

- **Directives** — the app's automations feature: a clock-driven (5s tick), per-directive
  engine over a pure world snapshot.
- **The brain** — the standing global orchestrator ("B") that runs the fleet unattended. A
  **pure selector**: each tick it derives goals, ranks them, and allocates devices/budget to
  the top ones. It never *enacts* — every command flows out through an executor. **Stateless
  between ticks.**
- **Goal** — a pure per-tick derivation `(kind, target, rationale)` over world state; never
  persisted. Continuity comes from matching against running executors, not memory. The five
  present kinds:
  - **`survey`** — chart uncharted systems. Root of the enablement chain; always-on.
  - **`tendMesh`** — **grow *and* prune** the FTL relay mesh. Grow = bridge a gap by planting a
    relay at a boring waypoint; prune = reclaim a relay from a durably-useless system. One
    worthiness heuristic, two directions.
  - **`mine`** — belt mining (needs survey devices to find/maintain belt sites + mining devices).
  - **`salvage`** — salvage-site mining (needs only mining devices).
  - **`fulfillEvent`** — fulfil a location event; the one **human-in-the-loop** seam.
  - **`growFleet`** *(reserved, future)* — print & stage a new subfleet to relieve a
    device-starved goal.
- **Engine** — a *means* a goal summons, never a goal itself: **`print`**, **`deliver`**,
  **`shuttle`** (consolidate resources), **`repair`**. A printed/delivered/consolidated/repaired
  thing only ever exists in service of a goal.
- **Executor** — the machinery a goal launches to do multi-step work (a Survey Run, Salvage Run,
  or a print/deliver/shuttle-composing mission). Clears its own safety bar; the brain treats it
  opaquely and only launches/retires it.
- **Hub** — a **derived, recognised** predicate, not a placed or tagged object: a *commandable
  location holding a print-capable device (autofactory) + adequate per-type stock*. Where hauled
  resources pool **and** where printing draws. **One hub** for now (the single autofactory's
  location, meshed by anchor co-location); deliberate placement and multi-hub routing are
  `growFleet`-future. An off-mesh hub is unsupported (escalate).
- **Relay Run** — the `tendMesh` **grow** executor (the reserved `relayRun` directive kind): a
  carrier-owned mission that **prints a relay at the hub → stows it aboard a co-located vessel →
  delivers it to a gap → activates it in situ**. Composes the `print` + `deliver` engines only;
  it **consumes** hub stock and is decoupled from resupply through the hub as a buffer.
- **Resupply** — feeding the hub is the standing job of the `mine`/`salvage` goals, which compose
  the **haul** engine (the shipped Haul Run) to drain their output to the hub. Salvage depletes
  (finite round-robin drain); a **mine** site never does, so it needs a **dedicated, persistent
  Haul Run per site**. There is no separate resupply goal. (`shuttle` is this generalised
  Haul Run — the resupply executor — not a Relay-Run co-engine.)
- **Fleet tag** — an `auto:<automation>` device tag: the operator's **opt-in**, and the only
  way a run resolves its working set. It is also the **lock**: a tagged device whose AMI
  directive is in force reads as engine-owned in the Directives list, so Reconfigure and Clear
  are refused on it — the permanent mine's belt controllers have no mission row to hold them.
  **Removing the tag is the take-back gesture**, and the only one; it hands the device back to
  the operator and makes it invisible to the automation at the same time.
- **Acquisition priority** — the order goals compete for *surplus* devices/budget:
  protect-committed-value → `fulfillEvent` → production (`mine`/`salvage`) → `tendMesh` → `survey`.
- **Sustenance priority (liveness floor)** — the *inverted* protection that keeps the enabling
  chain (`survey`/`tendMesh` + their repair) from deadlock, guaranteed ahead of acquisition.
- **Spend ceiling** — the cap on autonomous resource consumption on growth: a per-type resource
  **reserve floor** enforced at the enactment rail, plus a soft **≤ N idle relays** anti-hoarding
  cap.
