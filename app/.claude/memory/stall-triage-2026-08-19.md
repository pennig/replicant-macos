The 2026-08-19 live triage: "frequent stalls in Event Run and Relay Run, and
one Event Run retries won't resolve." Four independent defects, all diagnosed
against the live SQLite rows and all fixed. None is a Stage 0–2 regression —
`git log -S` puts every one of them before `655748a`.

**1. `EventRun` re-decided the event on an EMPTY catalogue.** `printing`,
`loading`, `confirmingLoad` and `staging` all called `EventPlan.resolve(…,
bills: [:])`. `resolve` documents that an empty catalogue cannot judge
printability and therefore leaves EVERY option standing — so a multi-option
event could only reach `.decided` through an operator pick, and all four steps
fell through to `.stall(.unreachableDevice)`.

`EventRanking.rank` launches under `view.blueprintBills`, so a run authorised
because exactly one option was printable stranded on its FIRST `printing` tick.
Live: eventRun `13632ED6` on `SKUT-3-EVT-003` (two options), created 08:56:18,
`printing` 08:56:28, stalled 08:56:34, then five retries each re-stalling within
four seconds. `.unreachableDevice` maps to `BrainDisposition.retry`, so the
brain kept re-asking a question only Matt could answer.

Closed by `EventRun.optionInForce`, which resolves on
`world.blueprintBills`/`blueprintComponents` and names the failure:
`.eventOptionNotChosen` (new, and the FIRST reason to map to
`.decisionRequest`) for a live choice, `.eventOptionBlueprintMissing` for a
blocked tree. `missingTree` was never affected — it does its own expansion from
`option.devices` with the real catalogue, which is why `bills: [:]` survived
this long.

**The catalogue was stale because `blueprint.unlocked` had no route.** 2038
events, `isHandled = 0`, no matched routes; `Blueprint` only refreshed on
`DeadlineScheduler`'s hourly sweep. `structural_fabricator` unlocked at
08:52:11.192, nine milliseconds before `SKUT-3` was discovered and four minutes
before the launch — so the brain priced option 2 unprintable and decided, and
the poll later made both options printable. `DeadlineScheduler`'s claim that a
skipped round "costs efficiency and never correctness" is false: the catalogue
decides which options exist. Closed by `BlueprintsIngestion` (new domain
`.blueprints`, route invalidates it).

**2. An `ftl_relay` names its carrier under a DIFFERENT payload key.**
`GameSync.stowChange` read `stowed_in_device_code`; every `device.stowed` for an
`ftl_relay` carries `stowed_in`. 221 of 2038 stow events, and the relay is the
only type on the short key — which is exactly why Relay Run was the mission
that stalled. `stowChange` returned nil, `applyDeviceEvent` then cleared the
relay's location (a stow payload carries none) WITHOUT setting
`stowedInDeviceCode`, and stamped `updatedAt = now`.

That half-written row defeats every arm of `RelayRun.relay(for:carrier:in:)` —
the stow resolver has no code to match, the idle-pool resolver has no location —
so `confirmingStow` stalled `.noRelayCoLocated` about seven seconds after
dispatching the stow, on a relay that was aboard. Reading both keys, longest
first, is the whole fix: the cleared location is then the CORRECT state for a
stowed device rather than half of a poisoned one. Do NOT also stop clearing
location on a nil — `9161CE8B` proves NULL location is the healthy stowed state.

**3. A co-tenant's print completion closed and mis-stamped the open op.**
`Reconciler.completeOpenOperation` matched on `entityCode` alone. A bench is one
serial queue (`operation_one_open_per_device`) but the server queues ten, so
whichever print finished first closed whatever op was open there and wrote its
own `new_device_code` in. **23 of 235 resolved print ops carry a
`result.device_type` contradicting their `params.device_type`** — op `F803ED52`
asked for `ftl_relay` and holds `defence_grid`.

`printedRelay` type-checks and correctly refused the foreign device, but
`printInFlight` had gone false, so `RelayRun.printing` waited out
`PrintJob.deadline` and stalled `.noRelayCoLocated`. That relay was still queued
and arrived 1h49m later — `PrintJob.deadline`'s premise ("it exists for the
print that never happens, not for a slow one") does not hold on a shared bench;
`F803ED52`'s own `completesAt` was already 40 minutes out. Closed by a third
guard beside the existing two: a result naming a type the open op did not ask
for is another job. The poll path passes no result and stays the backstop.

**4. One freighter, one trip, and a payload that does not fit.** With the option
picked, `loading` ordered `collect_resources` for the option's whole requirement
in one command and the server refused it: "requesting 800.0, capacity 500". Two
defects under that. The bill was the option's REQUIREMENT rather than what the
ledger still needs, so a part-delivered event over-collects and never converges
(`EventPlan.outstandingResources` now bills the remainder). And the convoy
carried exactly one 500-unit freighter, which no retry widens.

`SKUT-3-EVT-003` exceeds one hold on BOTH options — 800 units on
`tether_fabrication`, 1800 on `material_delivery` — so this was not a bad pick.
Matt chose a wider convoy over more trips: the lease is now
`Directive.freighterCodes`, `EventRun.loadPlan` divides the bill across the
holds by TOTAL capacity (not free space, or a mid-load recompute re-cuts the
shares), and every leg — load, depart, stage, return, deposit — covers all of
them. The depart leg did not: it ordered the lead hull and left. See
[[loop-legs-must-dispatch-in-step]]. The brain leases one hull per hold-full and idles naming the shortfall
rather than launching a convoy that cannot finish.

`leasedFreighters` is the single accessor over `freighterCodes` and the
`freighterCode` mirror. Read the column directly and a row written through the
other field leases a hull that nothing reserves.

**Still open.** A run launched BEFORE the lease became a list holds one
freighter for its whole life — nothing widens a convoy mid-flight, so such a row
stalls `.eventLoadExceedsHold` and wants cancelling rather than retrying.

## Defect 3 was fixed in the copy production does not call (closed 2026-08-19 pm)

The device-type guard went into `Reconciler.completeOpenOperation`. That is not
the close production takes. `GameSync.deviceRoute` sends every event carrying a
parseable `createdAt` through **`applyDeviceEvent`**, which holds its own copy of
the close — `allowedKinds` and event-time, never the device type;
`applyOperationEvent` is only the malformed-`createdAt` fallback. So the guard
shipped, the app was rebuilt over it, and the ledger kept mis-stamping: relay run
`A6876263`'s op `926CC591` asked `ftl_relay` and was closed on a `mining_drone`
completion at 17:34. The three guards are now one `completionMayClose` both paths
ask, because two copies is how the first fix missed.

**A guard added to one of two closes is not a guard.** Ask which path the router
actually takes before believing a fix is live.

## …and the misattribution was never the whole stall

Fixing it leaves the run waiting with an open op — and `printing` checks the
deadline ABOVE `printInFlight`, so the flat 30 minutes still fires. Autofactory
`43C9B54A` runs a strictly serial queue (each job's `startedAt` is the previous
job's `completesAt`) at ~10 minutes a job, kept 3–5 deep by the mine automation.
All four of the day's `printing` stalls fired at exactly `stepStartedAt + 1800s`
with the bench still working: `A6876263` dispatched 17:29:27, stalled 17:59:31,
and its relay `8EC8A25D` came off the bench at 18:07:29.

`PrintJob.deadline`'s premise — "for the print that never happens, not for a slow
one" — is sound; it simply cannot see a queue. `RelayRun.printStillQueued` now
extends it while an open print op's own `completesAt` is still ahead, which the
poll rolls forward job by job, and which our own completion ends by matching the
type. `PrintJob.queuedCeiling` (4h) bounds it, because a bench that never idles
would otherwise hold the carrier for ever; the number is a liveness backstop
chosen against a deepest-observed queue of 1h49m, and is the one value here worth
re-tuning from evidence.

`EventCourierPrint`, `MineFleetPrint` and `RestockRun` share the flat-deadline
shape on the same bench and were deliberately left alone — no `printing`-deadline
stall of theirs appears in the log. See [[printer-selection-ignores-status]] for
the rest of the shared-bench story.
