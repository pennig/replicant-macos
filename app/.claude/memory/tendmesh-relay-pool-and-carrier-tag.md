---
name: tendmesh-relay-pool-and-carrier-tag
description: "The 2026-08-04 live tendMesh incident and its four fixes — the hub relay POOL (idle relays are free stock), the auto:tendMesh carrier tag, FIFO claiming by queue position, and why a superseded print used to strand a run forever"
metadata:
  node_type: memory
  type: project
---

# The first live tendMesh incident, and the four things it changed

**One morning's live run (2026-08-04), reproduced exactly from the app's own
SQLite ledger.** Three Relay Runs launched at `AINALRAM-BELT-1` within seven
minutes. The two OLDEST stalled `noRelayCoLocated`; the YOUNGEST delivered. Three
`inactive` relays stood at the hub the whole time, beside the two stalled runs.

The evidence, in case a similar shape shows up again:

    directives (kind=relayRun)
      12:23:56  965AC2C3  needsAttention  step=printing  noRelayCoLocated
      12:24:01  C7836770  needsAttention  step=printing  noRelayCoLocated
      12:30:36  F2908E6E  completed       step=settling

    operations (kind=print, entityCode=43C9B54A — the one autofactory)
      12:23:58  superseded     12:23:58  superseded
      12:37:18  completed -> 37C0E8D2    12:50:38  completed -> 9047D6F9

## Four causes, three of them one knot

1. **Idle relays were ignored on purpose.** `RelayRun.printedRelayCode` detected
   a print by its OPERATION RESULT, and the file's own comment named
   `B94C05A8`/`8B55ED07` — two of the very relays standing there — as devices a
   presence check must never mistake for "our clone". Right about the mechanism,
   wrong about the goal.
2. **Any HEAVEN vessel was fair game.** `Brain.freeCarrier` filtered on type +
   location + not-busy + not-reserved. Three idle vessels stood at the hub, so
   the brain launched three runs (one per tick).
3. **FIFO was broken by LOCAL bookkeeping, not by the server.** `CommandClient`
   enforces one open op per device, so each new print at the shared hub
   **superseded** the previous run's op row. The server's `enqueue_print` really
   is a queue and printed them all; only the last dispatcher kept a row it could
   resolve a clone from.
4. **The stall was 1 + 3 compounding.** With its op superseded, a run's
   `printedRelayCode` is nil *forever*, so it walked to the print deadline and
   stalled — next to three relays it was not allowed to look at.

## What it now does

- **`RelayRun.idleRelays(at:in:)` is the pool**: `ftl_relay`, at the location,
  `stowedInDeviceCode == nil`, `statusBase == "inactive"`, not busy. Live-checked:
  a spare reads `inactive`, a planted one reads `relaying`.
- **Ownership is decided by the CLAIM, not by provenance.** A run no longer has
  to prove a relay is its own clone — only that nobody else has taken it. That is
  what makes a superseded print survivable, and it is checked in both `acquire`
  and `printing`.
- **`Brain.carrierTag = "auto:tendmesh"`**, in `isFreeCarrier`. Untagged means the
  brain launches NOTHING; `carrierBlocker` says so by name rather than reporting
  it as busyness (which would send an operator hunting a problem that isn't there).
- **FIFO via `queuePosition` + `claimableRelay`.** `WorldSnapshot` gained `peers`
  (in-force directive rows, same transaction). Each run computes the line of Relay
  Runs waiting at ITS hub, ordered by `createdAt`, and claims `pool[position]`.

## The two non-obvious design points

**Claim by POSITION, not "the first spare".** Relay Runs are independent `Task`s
on independent five-second clocks (`DirectiveEngine.makeExecutor`) — there is no
shared tick and nothing serialises them, so "whoever asks first" is a real race.
Indexing by queue position hands concurrent runs **disjoint** relays, which is
race-free with no lease and no lock, AND avoids a second run waiting for the
first to finish stowing before it can see its own relay.

**`.paused` holds no place in line** — the one status where the queue and
`Brain.owningStatuses` deliberately disagree. A paused run still owns its carrier
(reservation is right to keep it from the brain) but is stopped by operator
choice, possibly indefinitely; counting it would starve every other run at that
hub. `.needsAttention` IS counted — halted but one `retry` from moving, which is
exactly the state the two rescued runs were in.

## The server LOWERCASES every tag

Tagging the vessel is what exposed this: `auto:tendMesh` typed in the device
inspector came back from the fleet as **`auto:tendmesh`**, and the brand-new
exact-match carrier gate then refused the very vessel that had just been opted
in. `auto:haul` and `auto:salvage` had only ever been safe because they happen to
be spelled in lowercase already — nothing was enforcing it.

So a tag is now compared in exactly one place: **`Device.hasTag(_:)`**, which
normalises BOTH sides (`Device.normalizedTag` = trim + lowercase). Every call
site went through it — `Brain.isFreeCarrier`/`carrierBlocker`/`reservedDevices`,
`HaulRun` (×2), `SalvageRun`, `NewHaulRunFeature`, `NewSalvageRunFeature` — and
`TagsEditor` normalises before SENDING, so what the operator sees after the next
sync is what they typed, and "AUTO:Haul" can no longer be added beside an
existing "auto:haul". Constants are spelled in the normalised form, because they
are quoted back at the operator and should match the inspector.

**Never compare `device.tags.contains(...)` directly.**

## Things to know before touching this again

- **`noRelayCoLocated` maps to `BrainDisposition.escalate`**, so the brain does
  NOT auto-retry it. Runs already stalled when this shipped need one manual Retry;
  after that the pool prevents the stall recurring. Left as-is because the reason
  is shared with Survey/Salvage runs, where "operator must stow a relay" is right.
- **Tag gating is live-affecting**: no device in the fleet carried any tag when
  this shipped, so tendMesh launches nothing until a vessel is tagged.
- `deviceFixture` in `BrainTestSupport` now tags carrier-typed fixtures by
  default (they all predate the tag and meant "a vessel the brain may fly").
  `BrainCarrierTagTests` builds its devices directly so the gate is never proved
  by its own default.
- The engine test suite is ~700 tests and takes ~10 minutes — it is SLOW, not
  hung. Do not conclude a hang from an empty event stream in the first minutes.

Related: [[brain-tendmesh-build]], [[brain-executor-seam]], [[haul-run-design]]
(the `auto:haul` tag this one is modelled on), [[device-tags-and-control-range]].
