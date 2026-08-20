---
name: world-snapshot-peers-fifo
description: "Why WorldSnapshot.peers exists and how the relay claim stays safe now that one tick read feeds every executor: peers answers 'who else is competing for it?', RelayRun.queuePosition + claimableRelay claim POSITIONALLY (disjoint relays, not a yes/no turn), and the shared read makes every run compute that position from identical inputs"
metadata:
  node_type: memory
  type: project
---

# `WorldSnapshot.peers`, and the positional relay claim it exists for

Every other field on `WorldSnapshot` answers **"what is the world like?"**.
`peers` answers **"who else is competing for it?"** — the other in-force
directives, *including* the one being evaluated.

Most steps need neither. The directive row **is** the lease ledger and
`Brain.reservedDevices` does the allocating, so a mission never arbitrates for a
leased device.

## The exception: claiming shared stock no lease covers

Idle relays standing at a print hub belong to nobody. They are unstowed, no
directive names them, and the brain cannot pre-assign them: it allocates at
**launch**, while a run claims one much later, once a print completes. See
[[tendmesh-relay-pool-and-carrier-tag]] for the live incident that made the pool
a pool.

## The mechanism is POSITIONAL, not a turn

Two functions in `RelayRun.swift`, and neither asks "am I next?":

- **`RelayRun.queuePosition(_:at:in:)`** — where this run stands in the line of
  Relay Runs waiting for stock at a hub, `0` = head. Built from `world.peers`,
  filtered to relayRun / `.running` or `.needsAttention` / carrier at that
  location / no relay already aboard, ordered by `createdAt` with `id` as
  tie-break. A run absent from the list is position `0`. `.paused` holds no place
  in line, deliberately — a paused run at the head would starve the hub.
- **`RelayRun.claimableRelay(_:at:in:)`** — indexes the sorted idle-relay pool by
  that position: `position < pool.count ? pool[position] : nil`.

So concurrent runs claim **disjoint relays**. The second run in line does not
wait its turn; it takes the second relay. Nil means "no stock for me" and the
caller prints instead. There is no `isNextInLine` — that name has never existed
in this codebase.

## What the one-read tick changed, and what it did not

`DirectiveEngineCore.runTick` reads one `WorldTick` and hands the *same* read to
every executor it drives. So every run evaluating in a given tick sees the
identical `peers` array and the identical relay pool, and therefore computes the
same ordering — its position is a function of the shared read, not of when it
happened to ask. The tick loop is the serialising authority the per-executor
five-second clocks never had.

`queuePosition`/`claimableRelay` are still what perform the arbitration; they are
now deterministic rather than racy. Neither may be deleted, and `RelayRun` needs
no change: the tick makes the *inputs* agree, not the decision.

`peers` is read in the SAME transaction as the devices, so a run can never see a
peer's row from one instant against a fleet from another.
