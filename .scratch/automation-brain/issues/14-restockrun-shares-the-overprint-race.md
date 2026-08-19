# 14 — RestockRun shares MineFleetPrint's over-print race, and is less guarded

Type: task
Status: resolved

Blocked by: nothing. Ticket 13's fix has landed in `MineFleetPrint`; this ticket
is to port it.

## The race

`RestockRun` decides how many relays to print by counting **local device rows**
(`RelayRun.idleRelays(at:in:)`, `RelayRun.swift:194-204`) and re-decides the
moment the print op closes. A printed clone's device row and its print op's
close land in **separate transactions**: the op closes on the poll path
(polling the autofactory shows the queue emptied) while the row is created off
the SSE `print.completed` frame, which is the only channel carrying the clone's
device code. Ticket 13 measured the gap live at **28–117 minutes** on
2026-08-10, against an SSE delivery backlog that peaked at 2h08m.

So the sequence is: op closes → the only duplicate guard lifts → the pool still
reads short because the clone has no row yet → print another one. Repeat until
the backlog drains.

## Why it is *less* guarded than `MineFleetPrint` was

`RestockRun.printing` (`RestockRun.swift:160-173`):

    private func printing(...) -> MissionAction {
        guard let location = hub.location else { return .stall(.unreachableDevice) }
        if RelayRun.idleRelays(at: location, in: world).count >= Self.desiredIdle(for: directive) {
            return .advanceStep(nextStep: Step.stocking)
        }
        if world.openOperation(for: hub.deviceCode) != nil { return .wait }
        if world.now.timeIntervalSince(directive.stepStartedAt) > Self.printDeadline {
            logger.notice("… print produced no relay within the deadline — re-deciding")
        }
        return .advanceStep(nextStep: Step.stocking)
    }

The deadline check at `:169` **only emits a log line and falls through** — the
`.advanceStep(nextStep: .stocking)` at `:172` is unconditional. So the moment no
op is open, the very next 5-second tick re-enters `stocking` and may dispatch.
`MineFleetPrint` at least held for its 30-minute deadline first (which ticket 13
showed bought zero holdback, but it was something); `RestockRun` holds for
nothing at all.

`stocking` (`RestockRun.swift:89-136`) then re-counts `idleRelays` and prints
when `idle < desiredIdle`. Nothing in either step requires device evidence
newer than the op's close.

## Why `idleCap` does NOT mask it

`idleCap = 10` (`RestockRun.swift:54`) never engages, and would not help if it
did:

- `desiredIdle(for:) = min(idleCap, directive.targets.count)`
  (`RestockRun.swift:147-149`). The live row's `targets` holds **one** entry, so
  demand is **1** and the cap of 10 is never the binding term.
- The cap is a CAPITAL ceiling anyway (a relay is 370 units, so ten is 3,700
  parked), not a throughput throttle — see `relay-return-and-restock`.

What actually blunts the race today is:

1. **Relay fungibility.** `idleRelays` counts *any* idle `ftl_relay` at the hub,
   where `MineRecipe.shortfall` needs a per-type slot filled. A clone whose row
   has not landed is still invisible, but every other idle relay at the hub
   counts toward the same demand, so the pool is far likelier to already satisfy
   it.
2. **A demand of 1.** One unmet slot means at most one extra print per lag
   window, not the 4-surplus run of `ami_transport_controller` prints ticket 13
   recorded.

It did not fire during the 2026-08-09/10 incident's lag window. "Did not fire
here" is not "cannot fire": raise `targets` past one (the brain's `tendRestock`
keeps that list current) and the same 28–117 minute blind spot multiplies.

## The fix

Port whatever landed for ticket 13 in `MineFleetPrint`:

- A `fleetEvidenceIsStale(_:at:in:)`-shaped gate sitting at the last moment
  before the dispatch in `stocking`, after every branch that declines to print
  (so a vetoed or already-satisfied pass buys no read).
- The witness is the newest `updatedAt` among device rows at the hub location
  measured against `directive.stepStartedAt`. It works because `printing` hands
  back to `stocking` only once no op is open, so the step stamp strictly
  postdates the op's close — including the hub poll that closed it.
- The evidence is bought with `.refreshDevicesInSystem(designation: location,
  thenStall: .unreachableDevice)` — one `GET devices?location=<hub site>`
  request covering every device standing at the hub, and a printed clone is
  PRESENT at the hub, so a location sweep sees it. `thenStall` must be non-nil:
  a nil fallback waits, `.wait` does not re-stamp `stepStartedAt`, and the gate
  would then buy one read every 5-second tick forever.

Note `RestockRun`'s existing `.refreshFootprint(nextStep: .stocking, thenStall:
nil)` at `:120` — a device gate added after it chains one hop through the
engine's `paid` bound, which is fine (at most one refresh round per kind), but
the ordering should match `MineFleetPrint`: census first, reserve veto, then the
device sweep.

## Comments

Filed 2026-08-10 while implementing ticket 13, which the operator deliberately
scoped to `MineFleetPrint` alone.

Directives-architecture ticket 07 (2026-08-16,
`.scratch/directives-architecture/issues/07-snapshot-owner-aware-ops-and-freshness.md`)
touched `RestockRun.printing` next to this ticket's own quoted snippet, but
fixed a DIFFERENT defect: the open-op guard read any device's op as this run's
own, so a co-tenant's print at the shared bench blocked the deadline from ever
firing. That guard is now owner-scoped and the deadline check moved above it.

**This ticket's race is still open.** `printing`'s unconditional
`.advanceStep(nextStep: .stocking)` the moment no *own* op is open — before the
printed clone's device row has landed — is unchanged; ticket 07 did not port a
`fleetEvidenceIsStale`-shaped gate into `RestockRun.stocking`. Left at
`needs-triage` rather than marked resolved, since the fix this ticket asks for
was not implemented. `WorldSnapshot.isFresh(_:since:)`, added by ticket 07, is
available for whoever picks this up — the watermark work here is now a
one-line call rather than a hand-rolled compare.

Resolved at `30b783b` (directives-architecture ticket 39, Stage 3 Task 7):
`RestockRun.stocking` now calls `PrintJob.fleetEvidenceIsStale` as the last
gate before the dispatch, returning `.refreshDevicesInSystem(designation:
depot, thenStall: .unreachableDevice)` when every device row at the depot
predates `stepStartedAt`. Covered by
`RestockRunCapAndSweepTests.staleEvidenceBuysASweep` (the gate fires) and
`.metDemandBuysNoSweep` (a vetoed pass buys no read).

Of this ticket's two asks, the gate landed as specified. The ordering ask —
"census first, reserve veto, then the device sweep" — also matches: the sweep
sits after `PrintRail`'s `footprintCensusIsStale`/`printStockIsShort` checks
and immediately before the dispatch, the same position `MineFleetPrint.stocking`
uses.
