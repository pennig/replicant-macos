# 13 — MineFleetPrint over-printed the fleet: 3 surplus service bots, 4 surplus transport controllers

Type: task
Status: needs-triage

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

## Verification still owed

The app DB was TCC-blocked during diagnosis. When readable
(`~/Library/Containers/name.pennig.replicould/.../SQLiteData.db`), pull the
`mineFleetPrint` row's `directiveLogEntries` — each dispatch logs
`printing N × <type>` — and confirm the dispatch count and timing match the
mechanism above (expect ~5 transport dispatches ~32 min apart, each within a
tick of the prior op's close).

## Fix direction (pick at triage)

- Count what was already ordered: bound re-dispatch of the SAME type off the
  directive's own log (the `MissionLogBudget.dispatchRounds` shape from the
  mine build) or off open print ops + clones younger than the last dispatch.
- Make the deadline honest: per-type deadline above the measured job time, or
  measure from op-close rather than dispatch.
- Fresh evidence before re-print: require a device sweep newer than the
  op-close before the same type may be re-dispatched (the engine's existing
  confirm-steps-need-fresh-evidence rule).

## Cleanup (separate decision, operator's call)

The 7 surplus devices are capital parked at the hub: 3 idle service bots
(`F032BD82`, `DBFC51DA`, `B36487B2`) and 4 idle transport controllers
(`E98A300F`, `B2B69644`, `A4C2AE66`, `C21272AF`). They also pre-satisfy the
next mine install's shortfall, so they are not pure waste — decide whether to
keep them as stock for the next belt or recycle.
