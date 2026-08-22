---
name: print-bench-is-a-type-not-a-capability
description: "Why `Device.acceptsPrintJobs` gates on `printBenchTypes` and not on `enqueue_print` alone: a component printer advertises the command, is consumed by the print that needs it, and the stale local row then draws a 403 'Not your device'"
metadata:
  node_type: memory
  type: project
---

# A print bench is a TYPE, not a capability

`Device.isPrintHub` is capability (`availableCommands.contains("enqueue_print")`)
and its doc says so deliberately. **`acceptsPrintJobs` is not**, and the
difference is load-bearing:

```swift
var acceptsPrintJobs: Bool {
    isPrintHub && Self.printBenchTypes.contains(deviceType) && !refusesPrintJobs
}
static let printBenchTypes: Set<String> = ["autofactory"]
```

## The live evidence (2026-08-22)

At `AINALRAM-BELT-1`, by type, of everything advertising `enqueue_print`:

| type | count | any with `queueSize > 0` |
|---|---|---|
| autofactory | 6 | **6** |
| structural_fabricator | 5 | 0 |
| heaven_vessel | 4 | 0 |
| racing_vessel | 1 | 0 |

Only an autofactory has a real print queue. A `structural_fabricator` is a
**component**: it is printed as part of a larger blueprint and then consumed by
the print that needs it. The server stops treating it as ours at that moment;
nothing tells the app, so the local `devices` row survives, still carrying
`enqueue_print`, still standing at the depot.

`PrintScheduler.choose` ranks by `(queueDepth, deviceCode)`. A component printer
has `queueSize: 0` → capacity 1 → depth 0, so it is the SHALLOWEST bench and
wins the tie, and `36311DA9`/`1B6C833D` sort ahead of every autofactory by code.
So the scheduler picked one preferentially, and the dispatch came back
**403 "Not your device"** — a relayRun at `acquire` and an eventRun at
`printing`, both stalling `commandRejected`, roughly every 10–15 minutes.

`queueSize > 0` would discriminate here too. The TYPE is the rule because it
says what the device IS; the empty queue is a consequence.

## Blast radius, and why the fix belongs on `acceptsPrintJobs`

Three production call sites share the identical filter
`acceptsPrintJobs && location == depot && !isCarrierHull` —
`PrintScheduler.benches`, `Brain.restockHost`, and `DirectivesFeature`
(the UI's bench list). None of them wants a vessel, so narrowing the shared
predicate fixes all three and cannot disagree with itself.

**`isPrintHub` was deliberately left alone.** It also feeds
`WorldView.hubLocation` (theatre recognition) and `refreshDepotInventories`;
tightening it would move theatre identity, which
[[tendmesh-relay-pool-and-carrier-tag]] already fixed with a stock clause rather
than a type gate.

## One shipped test asserted the opposite

`EventRunPrintSchedulerTests.printVesselIsABench` — *"a print vessel that is not
an autofactory is a bench"*, over a fictional `fabricator_barge` — encoded the
capability-only rule. It was rewritten as a pair: a component printer takes no
dispatch, and the autofactory beside it does, so the gate is proved to narrow
the bench set rather than empty it. If that test reappears in its old form,
this note is the reason it must not.

Related: [[one-op-many-print-jobs]], [[printer-selection-ignores-status]],
[[blueprint-components]].
