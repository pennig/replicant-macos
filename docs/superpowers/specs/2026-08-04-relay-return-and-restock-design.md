# Relay Run return leg + demand-driven restock

**Date:** 2026-08-04
**Status:** approved, ready to plan

## Problem

Two manual steps stand between the brain and an unattended mesh:

1. **The carrier never comes home.** `Brain.launch` writes `returnToOrigin: false`
   ("a Relay Run chains onward rather than coming home"), which only holds with
   more than one carrier. With today's fleet the run plants a relay and the
   carrier idles at the target until a human flies it back — recorded in
   `brain-tendmesh-build` as a known limitation, and the reason the live fleet
   sat stalled at RUGULUS-1-L4.
2. **Printing is serial with delivery.** Nothing prints ahead of demand, so the
   pool (shipped in `01d996f`) only ever drains. Once the standing spares are
   used, every run waits out a print before it can leave.

Printing is the bottleneck and will stay so as carriers are added, so the
printer should run continuously while there is unmet demand.

## Design

### 1. Return leg

`RelayRun` gains a `returning` step, entered after the relay is confirmed
relaying, gated on `directive.returnToOrigin`. `Brain.launch` now sets it `true`.

**The destination is the hub LOCATION, re-derived from the world at return
time** — deliberately not `directive.originDesignation`. That field is
`SiteAssay.system(of: hub)`, a lossy projection (`Brain.swift`'s own comment
says so): it is `AINALRAM`, while the hub is `AINALRAM-BELT-1`. A bare system
designation travels to the system's entry point, an L4
(`travel-system-proxy-codes`, `lagrange-points-and-entry-point`), so returning
to it would land the carrier in the right system but NOT co-located with the
autofactory — and `Brain.freeCarrier` requires an exact location match. The
manual step would move rather than disappear.

Re-deriving also means the carrier follows the hub if the hub ever moves.

Hub recognition therefore needs to be callable from the executor as well as the
brain. It currently exists twice (`WorldView.hubLocation` for the brain,
`RelayRun.hub(near:)` for the executor, which is location-scoped). Factor the
rule into ONE seam both use — the same move that fixed tag casing.

A carrier already at the hub skips the leg (`.done`), exactly as
`SurveyRun.returnHome` guards on `Self.system(of: vessel) != origin`.

### 2. Restock

A new `restockRun` directive kind:

- **Owned by the hub device** (`deviceCode` = the autofactory). A print needs no
  carrier, and the hub's print queue is shared and never leased
  (`brain-primitive-contracts`), so owning it costs the fleet nothing.
- **Persistent.** One row, visible and cancellable, that idles rather than
  completing — the precedent is the per-site Haul Run in
  `brain-resource-hub-model`.

Its loop:

```
desired = min(idleCap, unmetDemand)
if idleRelaysAtHub >= desired        -> wait
if a print is already in flight      -> wait
if the reserve rail vetoes           -> wait (surfaced, not stalled)
else                                 -> enqueue_print -> await clone -> repeat
```

**`idleCap = 10`**, a named constant: a practical ceiling on relays parked in
inventory rather than held as reserve. Not a setting.

**`unmetDemand`** is the grow candidates the brain still wants meshed, minus
those already being served by an in-force Relay Run — `Brain.inFlightTargets`
already computes the second half. So the printer churns while targets remain and
stops when demand is met.

**Prints stay serial**, one in flight at a time. This is not a throttle: one
autofactory prints one relay at a time regardless, and enqueuing several would
re-create the op-supersession trap that stranded two runs on 2026-08-04
(`CommandClient` supersedes any other open op on a device, so only the last
dispatcher keeps a resolvable row).

**Guards are the existing ones.** The reserve floor
(`RelayRun.printStockIsShort` / `BrainCeiling`) vetoes any print that would
breach it, and hub recognition (fixed in `d4d46ea`) means there is no hub, and
so no restock, at a location with no stockpile.

The brain launches exactly one restock run when a hub exists and none is in
force. Idempotent, and it does not compete with grow for the one-launch-per-tick
budget: after creation the run self-regulates.

### 3. Testing

- Return leg: entered only when `returnToOrigin`; targets the hub LOCATION not
  the origin system; skipped when already home; the carrier ends free at the hub.
- Restock: prints while below target; stops at `desired`; stops at the cap;
  stops when demand is met; never prints with one in flight; respects the
  reserve veto; idles rather than stalling when it cannot print.
- Hub seam: one rule, both callers agree.

## Not doing

Concurrent prints; per-carrier tuning; any change to the reserve floor, grow
ranking, or the pool-claim rule; making the cap configurable.

## Consequences

- `returnToOrigin: false` and the "chains onward" comment in `Brain.launch` are
  retired. The e2e that ENCODES the stranding behaviour
  (`brain-tendmesh-build`: "changing it is not a regression") must be updated
  deliberately, not worked around.
- A new `DirectiveKind` case forces every exhaustive switch open — no schema
  migration, since kind is a string value in an existing column.
