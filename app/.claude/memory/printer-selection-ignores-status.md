The 2026-08-15 live stall: a `mineFleetPrint` row sat in `needsAttention` /
`commandRejected` re-collecting "Device is compacted" and then "Cannot enqueue
while travelling", while three able autofactories stood at the same depot.
The operator had compacted the pinned hub and surged it out of the system.

**Two independent defects, both now fixed.**

**1. Every printer-selection predicate in the app filtered on CAPABILITY
only.** `Device.isPrintHub` is `availableCommands.contains("enqueue_print")`,
and the server keeps advertising `enqueue_print` on a hub that is compacted,
attached to a carrier and 86% of the way to another system — verified live on
the incident device. So capability can never rule one out; only `status` can.
`in_control_range` is NOT the signal either: it read `true` for the whole
flight and flipped to `false` only after arrival, so it catches the aftermath
and never the rejection. Closed by `Device.acceptsPrintJobs` (capability AND
`statusBase` outside `printRefusingStatuses` = compacted / travelling /
cruising / surging / stowed / out_of_range), now used by `RelayRun.hub`,
`Brain.restockHost`, `DirectivesFeature.depotPrinter`, `EventRun`'s inline
picker, and the mine-fleet launcher.

**`Device.isBusy` is the wrong predicate here and must not be substituted.** A
hub reading `printing (ftl_relay)` is busy but perfectly able — `queue_size` is
10 and jobs queue behind the running one. Using `isBusy` would skip it and open
a needless second queue at the same bench.

**2. `MineFleetPrint` / `RestockRun` / `EventCourierPrint` pinned one printer
at launch and never re-resolved.** Their `nextAction` read
`world.device(directive.deviceCode)` and escaped only when the row was GONE, so
a hub still present but unable passed every guard, dispatched, and collected the
server's refusal forever. Retry and Skip are both structurally unable to clear
this: `retry` leaves `step` alone and `skipTarget` resets it to `firstStep`,
which for a targetless run is the same `stocking`, and neither verb touches
`deviceCode`. Closed by `MineFleetPrint.printer(for:in:)`, which all three now
share — the row's own hub while it still accepts jobs AND still stands at the
depot, else the lowest-coded able non-carrier-hull hub at that depot.

**The depot must gate the hub, not the other way round.** A first cut preferred
the pinned hub whenever it was able, which is wrong the moment it unfurls and
goes idle at its NEW location: the run would have printed the whole mine fleet
at the destination. `directive.theatreDepot` is the anchor; the pinned hub's
location is only a fallback for an unstamped row.

`EventRun` was already correct and is the reference shape — it re-derives the
depot per tick and picks any autofactory there with no open operation.

**The launcher was pinning the dead hub in the first place.** The Print Mine
Fleet launcher took the globally lowest-coded print hub ANYWHERE (`isPrintHub`,
non-nil location, `.min(by: deviceCode)`), unscoped by theatre, and left
`theatreDepot` nil — so nothing recorded which bench the run belonged to, and
`Brain.adoptTheatreStamps` could only fill it when exactly one theatre was
operational. It now walks operational theatres like the courier launcher and
stamps the depot.

Residual: re-resolution is per-tick and NOT persisted, so the row keeps showing
its original `deviceCode` in the list while printing elsewhere. Deliberate — a
new `MissionAction` to rewrite `deviceCode` would need an engine resolver, and
`reservedDevices` closing over the column makes rewriting it a wider change than
this repair warrants.
