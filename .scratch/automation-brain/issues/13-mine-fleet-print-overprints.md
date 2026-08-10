# 13 — MineFleetPrint over-printed the fleet: 3 surplus service bots, 4 surplus transport controllers

Type: task
Status: resolved

## Symptom (observed live 2026-08-10, install of the ACHERNUR-BELT-1 mine overnight 2026-08-09/10)

The recipe wants 2 `service_bot` and 1 `ami_transport_controller`
(`MineRecipe.carried`/`selfMoving`). The account now holds, all tagged
`auto:mine`: **5 service bots** (2 working at the belt, 3 idle at
`AINALRAM-BELT-1`) and **5 transport controllers** (1 armed as the ferry, 4
idle at the hub). Creation timeline from `GET devices/tags/auto:mine`:

    23:48–01:00  mining ctrl, 3 drones, survey ctrl, 2 drones   (exact, no surplus)
    01:38–02:41  service bots ×5, ~10–20 min apart              (want 2)
    03:33–05:45  transport controllers ×5, ~32 min apart        (want 1)
    06:07        cargo freighter ×1                             (exact)

Decisive detail: the arm step claimed the **lowest-coded** transport
(`8D53C9B1`, created *last*, 05:45), so during the whole 03:33–05:45 window
nothing had claimed any transport — a free one stood at the hub while four more
printed. Claim-reopens-shortfall is NOT the mechanism.

## Root cause analysis (code read; final confirmation blocked on the directive log)

`MineFleetPrint` (`app/Modules/DirectiveEngine/Sources/MineFleetPrint.swift`)
is deliberately stateless: each `stocking` pass recomputes
`MineRecipe.shortfall` over **local device rows** and prints whatever reads
missing. Three code facts compound into duplicates:

1. **`printDeadline` (30 min) is shorter than a transport's print job
   (~32 min observed).** `printing` waits while the op is open, but the
   deadline is measured from `stepStartedAt` (the dispatch), so when the op
   finally closes the deadline is already expired and the next 5-second tick
   re-enters `stocking` (`MineFleetPrint.swift:120-124`,
   `RelayRun.printDeadline` = 30 min at `RelayRun.swift:93`).
2. **The re-decide races the clone's row sync.** The op closes on print
   completion (SSE), but the clone becomes a local `devices` row only when
   something syncs it. At the moment of op-close the shortfall still reads
   short → duplicate dispatch. The open-op guard (`MineFleetPrint.swift:80`)
   is the *only* duplicate protection and it evaporates exactly then.
3. **A multi-quantity job settles its op on the FIRST clone** (acknowledged at
   `MineFleetPrint.swift:111-113`), so the qty-2 bot job released the guard at
   clone 1 while clone 2 was still printing — same race, second door.

Each cycle burns one full print (~32 min of autofactory time + resources) and
the loop self-terminates only when enough surplus accumulates locally to
satisfy the cap. `RestockRun`/`RelayRun` share the deadline and the
decide-off-local-rows shape; check whether the relay path has the same latent
race (its `idleCap` may just be masking it).

## Verification (done 2026-08-10, live DB)

The `mineFleetPrint` directive row is **gone from the DB** — `directives` holds 7
rows and none is the mine print, so the `printing N × <type>` log lines do not
exist to be read. Reconstructed instead from `operations` (with
`detail.params.quantity`), `eventLogs` (`print.started`/`print.completed`, which
carry server `createdAt` *and* app `receivedAt`) and `devices.firstSeenAt`. Hub =
autofactory `3C39631F` at `AINALRAM-BELT-1`. Times below UTC; they match the
ticket's local timestamps to the second.

Every dispatch on the hub, with op close and when the clone's local row appeared:

| # | dispatch | job | op close | row visible | row lag |
|---|---|---|---|---|---|
| 1 | 04:18:12 `ami_mining_controller` ×1 | 30m00 | 04:48:12 | 04:48:30 | 18 s |
| 2 | 04:48:40 `mining_drone` ×3 | 3×10m | 05:18:42 | 04:58:44 / 05:08:45 / 05:19:06 | ~4–25 s |
| 3 | 05:19:57 `ami_survey_controller` ×1 | 25m00 | 05:44:57 | 05:45:24 | 27 s |
| 4 | 05:50:31 `survey_drone` ×2 | 2×5m | 06:00:31 | 05:57:47 / 06:00:48 | ~17 s |
| 5 | 06:27:34 `service_bot` **×2** | 2×11m07 | 06:49:48 | 07:05:12 / 07:46:11 | **27m / 56m** |
| 6 | 06:58:23 `service_bot` **×2** | 2×11m07 | 07:20:37 | 08:47:06 / 09:17:17 | **98m / 117m** |
| 7 | 07:30:22 `service_bot` **×1** | 11m07 | 07:41:29 | 09:25:27 | **104m** |
| 8 | 08:03:40 `ami_transport_controller` ×1 | 30m00 | 08:33:40 | 10:27:11 | **113m** |
| 9 | 08:36:04 `ami_transport_controller` ×1 | 30m00 | 09:06:04 | 10:30:19 | **84m** |
| 10 | 09:09:34 `ami_transport_controller` ×1 | 30m00 | 09:39:34 | 10:35:34 | **56m** |
| 11 | 09:41:07 `ami_transport_controller` ×1 | 30m04 | 10:11:11 | 10:39:29 | **28m** |
| 12 | 10:15:49 `ami_transport_controller` ×1 | 30m00 | 10:45:49 | 10:46:25 | 36 s |
| 13 | 10:47:31 `cargo_freighter` ×1 | 20m00 | 11:07:31 | 11:07:50 | 19 s |
| 14 | 11:17:43 `surge_carrier` ×1 | 80m05 | 12:37:48 | 12:38:10 | 26 s |

Dispatch-to-dispatch gaps across all 14: 30m28, 31m17, 30m34, 37m03, 30m49,
31m59, 33m18, 32m24, 33m30, 31m33, 34m42, 31m42, 30m12 — **30 minutes plus
0.5–4.7 min of engine latency, every time.** The one 37m outlier is explained by
an unrelated `ftl_relay` print holding the open-op guard until 06:25:58.
`printing` **never** exited via `remaining(...).isEmpty`; it exited on
`printDeadline` on all 14 steps, including the ones that produced no surplus.

### Corrections to the root-cause analysis above

1. **The deadline is not shorter than the job — it is exactly equal.** A
   transport job is `30m00s` (08:03:40 → 08:33:40). The "~32 min" the ticket
   measured is the *dispatch period* = job time + post-deadline re-dispatch
   latency. `stepStartedAt` is stamped at/just before the op's `startedAt`, so at
   op close the `<= printDeadline` guard has already flipped: the deadline buys
   **zero** holdback. The conclusion survives; the arithmetic does not.
2. **The mechanism is broader than a slow job.** The service bots' per-command
   job was `22m14s`, comfortably *inside* the deadline, and they over-printed
   anyway — `printing` waited out the full 30 min from dispatch and re-decided
   ~8 min after the op had closed. **The deadline, measured from dispatch, is the
   sole release trigger for every step of this mission.**
3. **Mechanism 2 is confirmed and far larger than supposed — not "a tick" but
   28–117 minutes — and the ticket omits its enabling condition: an SSE delivery
   backlog of 0 → 2h08m.** Per-hour max `receivedAt − createdAt`: 04:00 → 2221 s,
   05:00 → 157 s, 06:00 → 1355 s, 07:00 → 3905 s, 08:00 → 6376 s, 09:00 → 7092 s,
   10:00 → **7659 s**, 11:00 → 57 s (drained). The clone's device row is created
   off the SSE `print.completed` frame, but the **op closed on the poll path**
   (`source = poll`, `lastConfirmedAt ≈ completesAt + 10 s`) — polling the
   autofactory reveals the queue emptied but never carries the clone's device
   code. So the open-op guard lifted on schedule while the row channel ran two
   hours behind. The first transport row appeared at 10:27:11, *after the last of
   the five dispatches*; `MineRecipe.shortfall` read short on all five passes.
   Fingerprint: the dispatched quantity tracks locally-visible rows exactly —
   cmd B saw zero bot rows → dispatched qty 2; cmd C saw one → dispatched qty 1.
   This explains the incident's whole shape: dispatches 1–4 at ~0 lag produced
   exact counts, over-printing begins at the first clone to land inside the lag
   window and stops the moment the backlog drains at ~10:46.
4. **Mechanism 3 is contradicted for the case that mattered.** The qty-2
   `service_bot` op (`732B4EBD`) has `completesAt = 06:49:48` — the *second*
   clone, not the first — and stayed open across both. The second bot dispatch
   fired 8m35s after that close, released by the deadline, not by early op
   settlement. (The claim *is* true on the event path: the qty-3 drone job made
   three separate op rows. It caused no harm there, because row lag was ~4 s.)
5. **"Each dispatch within a tick of the prior op's close" is false** — the real
   spread is 1m33s to 9m45s, and always keyed to the *deadline*, not the close.
6. **No dispatch ever fired while an op was open.** The
   `world.openOperation(for: hub.deviceCode)` guard held 14/14 times.

Counts reconcile: 3 bot dispatches (2+2+1) = 5 bots = 3 surplus; 5 transport
dispatches = 5 controllers = 4 surplus.

### Sibling race

- **`RestockRun` — same race, and *less* guarded.** `RestockRun.printing`
  (`RestockRun.swift:160-173`) returns `.advanceStep(nextStep: .stocking)`
  **unconditionally** once no op is open; the deadline check at :169 only emits a
  log line and falls through. So it re-decides on the very next tick after op
  close, with no holdback at all. `idleCap` is **not** what masks it and is not
  even binding — `desiredIdle = min(idleCap, targets.count)` and the live row's
  `targets` holds one entry, so demand is 1 and the cap of 10 never engages. What
  actually blunts it is relay **fungibility** (`idleRelays` counts any idle relay
  at the hub, where the mine recipe needs a per-type slot) plus that demand of 1.
  It did not fire during this incident's lag window, but "did not fire here" is
  not "cannot fire".
- **`RelayRun` — no, and it is the model for the fix.** `RelayRun.printing`
  (`RelayRun.swift:403-429`) is one-shot and handles the row lag explicitly:
  `.refreshDevices(deviceCodes: [code], thenStall: .noRelayCoLocated)` when the
  printed clone code is known but `world.device(code) == nil`, and otherwise
  stalls on the deadline rather than re-dispatching. Its doc comment already
  names this exact hazard: *"what this waits for is not the operation closing but
  the CLONE arriving — two facts landing in separate transactions."*

## Fix direction (pick at triage)

- Count what was already ordered: bound re-dispatch of the SAME type off the
  directive's own log (the `MissionLogBudget.dispatchRounds` shape from the
  mine build) or off open print ops + clones younger than the last dispatch.
- Make the deadline honest: per-type deadline above the measured job time, or
  measure from op-close rather than dispatch.
- Fresh evidence before re-print: require a device sweep newer than the
  op-close before the same type may be re-dispatched (the engine's existing
  confirm-steps-need-fresh-evidence rule).

## Answer (2026-08-10) — fresh clone evidence, `RelayRun`'s pattern

Operator picked "fresh evidence before re-print". The other two were rejected on
the verification: making the deadline honest doesn't work (the bots' 22m14s job
sat inside the 30-minute deadline and over-printed anyway), and counting prior
dispatches off the log caps damage without fixing deciding-off-stale-rows.

**The invariant:** `MineFleetPrint` never re-dispatches a print on device-row
evidence that predates the previous op's close.

`MineFleetPrint.fleetEvidenceIsStale(_:at:in:)` takes as its witness the newest
`updatedAt` among device rows whose `location == hub.location` — exactly the row
set `remaining(at:)` judges — and compares it against `directive.stepStartedAt`.
Nil (no rows at all) fails closed. The gate sits in `stocking` at the last
moment before dispatch, buying
`.refreshDevicesInSystem(designation: location, thenStall: .unreachableDevice)`.
`printing` is unchanged: the holdback belongs at the dispatch site, which makes
it immune to step routing.

**Why the witness is `stepStartedAt` and not the op close.** An op-close
watermark is defeated by the incident's own mechanism — the op closed *because*
the hub was polled, so `hub.updatedAt ≈ close + 10 s` and any close-based
watermark is satisfied by a read that never revealed the clone. `printing` hands
back only when no op is open, so the step stamp postdates the closing poll and
that poll cannot clear the gate. Every other entry into `stocking` (retry,
skipTarget, an unresolved `.refreshFootprint`) also re-stamps, so the gate is
monotone-safe.

**Why `.refreshDevicesInSystem`.** `.refreshDevices` needs the clone's code,
which the poll-path close never carries. `.refreshFleet(tag:)` is one tag per
action and the recipe spans two (`auto:mine` + `auto:carrier`). The
in-system sweep matches the question exactly — the recipe asks how many free
type-T stand at the hub, and `MineRecipe.isUnassigned` already requires
`location == hub && stowedInDeviceCode == nil`. Confirmed live that it accepts a
**site** designation: `GET devices?location=AINALRAM-BELT-1` returns 22 devices
in one page, no cursor.

`thenStall` must be non-nil — `.wait` doesn't re-stamp `stepStartedAt`, so a nil
fallback would buy one read every 5 s forever. `.unreachableDevice` collapses
through the engine's one-round `paid` bound in a single evaluation. Note
`mineFleetPrint` is **not** in `Brain.brainManagedKinds`, so this stall is
operator-resolved, never auto-retried.

### Residuals accepted

1. **A ≤5 s race.** A `.low` poll of any hub-standing device landing between the
   step stamp and the next evaluation would clear the gate spuriously. The
   incident's own poll cannot (it precedes step entry) and PollCoordinator reads
   are TTL-limited, so this is narrow but not zero.
2. **A long `.wait` in `stocking`** (short stock) does not re-stamp
   `stepStartedAt`, so the sweep bought on entry can be hours old when the print
   finally goes out. Not the incident's mechanism — no op close intervenes — but
   a weaker guarantee than the abstract invariant.
3. **`RestockRun` is deliberately out of scope** and filed as ticket 14.

## Cleanup (separate decision, operator's call)

The 7 surplus devices are capital parked at the hub: 3 idle service bots
(`F032BD82`, `DBFC51DA`, `B36487B2`) and 4 idle transport controllers
(`E98A300F`, `B2B69644`, `A4C2AE66`, `C21272AF`). They also pre-satisfy the
next mine install's shortfall, so they are not pure waste — decide whether to
keep them as stock for the next belt or recycle.

**Decided 2026-08-10: keep as stock.** They pre-satisfy the next mine install
and the call is reversible. No live mutations made.
