---
name: world-snapshot-peers-fifo
description: "Why WorldSnapshot.peers exists and why RelayRun.isNextInLine still arbitrates now that one tick read feeds every executor: peers answers 'who else is competing for it?', and the shared read makes the FIFO answer identical across runs instead of dependent on who asked when"
metadata:
  node_type: memory
  type: project
---

# `WorldSnapshot.peers`, and the FIFO claim it exists for

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

`RelayRun.isNextInLine` settles the claim by asking whether this run is the
oldest waiting run at this hub. That is what makes the claim FIFO rather than
"whoever asks first".

## What the one-read tick changed, and what it did not

`DirectiveEngineCore.runTick` reads one `WorldTick` and hands the *same* read to
every executor it drives. So every run evaluating in a given tick sees the
identical `peers` array, and the FIFO answer each computes is identical across
runs rather than a function of when it happened to ask. The tick loop is the
serialising authority the per-executor five-second clocks never had.

`isNextInLine` is still what performs the arbitration — it is now deterministic
rather than racy. It must not be deleted, and `RelayRun` needs no change: the
tick makes the *inputs* agree, not the decision.

`peers` is read in the SAME transaction as the devices, so a run can never see a
peer's row from one instant against a fleet from another.
