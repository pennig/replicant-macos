---
name: sse-typed-event-payloads
description: "Design-confirmed 2026-08-03: SSE event payloads migrate to one uniform shape — a standalone …EventPayload value per extracting event, parsed via a Utils reader, consumed by typed folds. Flagship = discovery-seeding: event.discovered carries the FULL quest shape (the stale LocationEventsIngestion comment is wrong), so the route seeds a complete row instead of reading accounts/events."
metadata:
  node_type: memory
  type: project
---

Confirmed design (grilling loop, 2026-08-03), plan at
`docs/superpowers/plans/2026-08-03-sse-typed-event-payloads.md`. Extends the
architecture-review candidate "deepen the event fold". Not yet built.

## The load-bearing finding: `event.discovered` is nearly a full quest

The comment at `LocationEventsIngestion.swift:63-64` — discovery "arrives
without the criteria and progress the screen needs" — is **half stale**. A live
`event.discovered` payload (captured `STELLA-3-EVT-002`, `resource_trade`)
carries: `designation, title, description, event_type, location, tier, rewards`
(xp/civ points/achievement/resources), **and `criteria`** (the required
amounts, e.g. `{carbon: 250, silicates: 100}`). So "without the criteria" is
wrong — criteria is right there.

What discovery genuinely lacks is live **`progress`** in the shape
`LocationEventDetail` decodes (`detail.progress.options[].resources[].{current,
required, met}` + `progress.met` + `replicant_present`). The payload has
`criteria` (the `required` side only, as a `{resource: amount}` map), not
`progress`. But at the moment of discovery, progress is trivially zero — nothing
contributed yet — so a zero-progress `progress` block is **synthesizable from
`criteria`** and is *correct* until a contribution lands.

**Consequence:** `event.discovered` can **seed a complete, correctly-rendered
quest row with no `accounts/events` read**. Progress can only be *deferred*, not
avoided — it accrues after discovery and arrives only via a re-read. That
re-read is already triggered by `CommandClient+Cargo.swift:49`
`refreshOpenLocationEvents(at:)` (post-`deposit_resources`, gated on an OPEN
event at the drop-off — a seeded row satisfies it) and by relevant
`travel.arrived`. Residual staleness = a community objective progressed by
*others* with no local event, accepted as deferred-to-next-refresh.

Seeding must be **replay-safe**: a replayed discovery (catch-up/gap-repair) for
an already-progressed quest must never downgrade `progress` back to zero — fill/
create only, like `merging`/`completing`. Fall back to the read ONLY when the
payload is unparseable (never silently lose a quest). `scan.completed` keeps its
`.locationEvents` nudge (a scan-revealed quest still needs the read).

## The convention (locked)

- **Edge = SSE event stream only.** REST decoders (`LocationEvent.merging`,
  `LocationEventDetail`, census/locations/mesh DTOs) are OUT of scope — a
  separate concern, free to adopt the reader later.
- **One uniform shape.** Every extracting event → exactly one standalone
  `…EventPayload` value with `parse(from: [String: JSONValue]) -> Self?`,
  co-located with its ingestion owner. Persistence/model folds consume the typed
  value, never a raw dict. Generalizes [[salvage-resource-amounts]]'s
  `SalvageEventPayload`; `BobnetMessage`'s inline parse migrates to this shape.
- **Shared `Utils` reader** — keyed accessors on `[String: JSONValue]`
  (`nonEmptyString`/`double`/`object`/`doubleMap`/…) encode the empty-string→nil
  trap once; no route pokes `JSONValue` by key directly after the sweep.
- **`Reconciler.swift:337` `detail.result` stays a verbatim blob** (opaque
  store, not extraction) — documented, not migrated.
- **No catalog artifact** — a typed payload existing *is* the "we fold" signal;
  drift is caught by fixtures, not a registry. The lesson from the stale comment
  is "verify against a captured payload", which fixtures bake in.
- **No migration** — `LocationEvent.seeding` writes existing columns + `detail`.

Full site inventory + task breakdown in the plan. See [[event-stream-migration]],
[[event-log-feature]], [[experience-and-completion-events]],
[[ami-drones-are-event-silent]] (why most other families still confirm-read).
