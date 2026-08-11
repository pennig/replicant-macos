---
name: logistics-haul-yields
description: "LogisticsFeature (Logistics sidebar) SHIPPED 2026-08-10: the haulYields ledger + charts. Yields are RECONSTRUCTED from ami.transport.digest deltas, never reported (1,318 collections over 15 days vs 22 individual transport.collected events). Attribution is directives.deviceCode only. The categorical palette clears only ADJACENT pairs, so no all-pairs form may ever be added to this screen."
metadata:
  node_type: memory
  type: project
---

Spec: `docs/superpowers/specs/2026-08-10-logistics-design.md`. `HaulYield` (GameModels) +
`LogisticsIngestion` (GameServices) + `LogisticsFeature`/`LogisticsView` (charts + ledger).

**Yields are reconstructed, never reported.** An AMI-controlled transport is event-silent
([[ami-drones-are-event-silent]]): a pickup is inferred from a rise in the controller digest's
`cargo_carried`, and the composition comes from one triggered `.high` device read. Measured
2026-08-10: 1,318 collections over 15 days, only 22 individual `transport.collected` events. No
opt-out exists; `/v1/events` keeps no useful history, so a period with the app closed is a
permanent hole — `HaulYield.followsGap` marks exactly that.

**Attribution goes through `directives.deviceCode` only** — never `controllerCode` (stamped once
at launch, so older pinned rows carry nil) or `fleetTag` (worn by no device, it's belt-scoped).

**The `.high` device read is budget-gated**, a deliberate exception to the "no refresh on the
router's dispatch path" invariant at `ReplicantApp.swift:81-85` ([[haul-run-design]] established
the same controller). `LogisticsIngestion.recordPickup` checks `gameClient.budget(.reads)` before
issuing the read (mirroring `PollCoordinator`'s own floor) and writes `breakdownState = .unavailable`
— preserving the total, never blocking ingestion on `RateLimitGovernor.acquire`'s sleep.

**The categorical palette clears the colorblind gate on ADJACENT pairs only** and fails under
all-pairs in both modes — so no all-pairs categorical form (scatter, bubble, choropleth, six-colour
small multiples) may ever be added to this screen, and direct labels on the stacked column are
structural, not decoration. Slot order is `ResourceCost.displayOrder`; the naive remapping puts two
greens adjacent and drops the normal-vision floor to 15.6 against a hard-fail line of 15. **Guarded
only by a manual `dataviz` validator run — nothing in CI checks this** — re-run it by hand on any
future palette edit.

Two latent traps: `haulYields.perType` has SQL `DEFAULT '{}'`, which `ResourceCost` cannot decode
(six non-optional Ints, no defaults) — unreachable today since every write supplies it, but the
migration is shipped and append-only. And a delivery arriving after a gap closes a stale open row
with a fabricated `deliveredAt`/`destinationDesignation`, which nothing renders yet.
